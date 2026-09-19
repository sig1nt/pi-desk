import Foundation
import Testing
@testable import PiDesk

@MainActor
struct RPCTests {
    private func fixture() throws -> URL {
        let url = try #require(Bundle.module.url(forResource: "fake-pi", withExtension: "js", subdirectory: "Fixtures"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func peer() throws -> RPCConnection {
        let rpc = RPCConnection()
        try rpc.start(ProcessInvocation(executable: "/usr/bin/env", arguments: ["node", try fixture().path]))
        return rpc
    }
    private func controller() throws -> SessionController {
        let client = Client(name: "Fixture", executable: try fixture().path)
        return SessionController(client: client, record: SessionRecord(workingDirectory: "/tmp"))
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(predicate(), "Timed out waiting for RPC event")
    }

    @Test func correlatedOutOfOrderResponsesAndTimeouts() async throws {
        let rpc = try peer()
        defer { rpc.stop() }
        async let slow = rpc.request("echo", fields: ["value": "slow", "delay": 80])
        async let fast = rpc.request("echo", fields: ["value": "fast", "delay": 1])
        #expect(try await fast["value"] as? String == "fast")
        #expect(try await slow["value"] as? String == "slow")
        do { _ = try await rpc.request("fail"); Issue.record("Expected RPC failure") }
        catch { #expect(error.localizedDescription == "Expected failure") }
        do { _ = try await rpc.request("hang", timeout: 0.03); Issue.record("Expected timeout") }
        catch { #expect(error.localizedDescription.contains("timed out")) }
        #expect(try await rpc.request("echo", fields: ["value": "after timeout"])["value"] as? String == "after timeout")
        rpc.stop(); await rpc.waitForExit()
    }

    @Test func exitRejectsPendingRequestsWithDiagnostics() async throws {
        let rpc = try peer()
        defer { rpc.stop() }
        do { _ = try await rpc.request("exit"); Issue.record("Expected disconnect") }
        catch {
            #expect(error.localizedDescription.contains("exit 7"))
            #expect(error.localizedDescription.contains("Fixture exited intentionally"))
        }
        #expect(!rpc.isRunning)
    }

    @Test func malformedOutputFailsConnection() async throws {
        let rpc = try peer()
        var diagnostic: String?
        rpc.onDisconnect = { diagnostic = $0 }
        do { _ = try await rpc.request("malformed"); Issue.record("Expected invalid output failure") } catch {}
        #expect(diagnostic?.contains("Invalid Pi RPC output") == true)
        await rpc.waitForExit()
    }

    @Test func streamingFinalMessagesToolsAndModelControls() async throws {
        let session = try controller()
        await session.connect()
        #expect(session.status == .connected)
        #expect(session.models.count == 2)
        #expect(session.record.sessionPath == "/tmp/fake-session.jsonl")
        await session.setModel("test/two")
        await session.setThinking("high")
        #expect(session.modelID == "test/two")
        #expect(session.thinking == "high")
        session.record.draft = "hello"
        await session.send()
        try await eventually { session.messages.count == 3 }
        #expect(session.isBusy, "agent_end must not settle a run that can retry")
        try await eventually { !session.isBusy }
        try #require(session.messages.count == 3, "Tool result events must not duplicate the tool row")
        #expect(session.messages[0].body == "hello")
        #expect(session.messages[1].body == "Authoritative final text")
        #expect(session.messages[1].thinking == "Some reasoning")
        #expect(session.messages[2].arguments.contains("pwd"))
        #expect(session.messages[2].body == "tool output")
        #expect(session.record.draft.isEmpty)
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func assemblesDeltaOnlyEventsByContentIndex() async throws {
        let session = try controller()
        await session.connect()
        session.record.draft = "stream-only"
        await session.send()
        try await eventually { session.messages.last?.body == "Hello 🌍\u{2028}\n\nWorld!" }
        #expect(session.messages.last?.thinking == "Reason")
        #expect(session.isBusy)
        await session.stop()
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func reconnectAndCompaction() async throws {
        let session = try controller()
        await session.connect()
        session.disconnect()
        await session.connect()
        #expect(session.status == .connected)
        await session.rename("Renamed")
        #expect(session.record.title == "Renamed")
        await session.compact()
        #expect(session.error == nil)
        #expect(!session.isBusy)
        #expect(!session.isChangingSettings)
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func shellQuotesExecutableAndWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiDesk ' $(false) " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake ' pi")
        try FileManager.default.copyItem(at: fixture(), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = Client(name: "Quoted", workingDirectory: directory.path, executable: executable.path)
        let rpc = RPCConnection()
        try rpc.start(ProcessInvocation.rpc(client: client, session: SessionRecord(workingDirectory: directory.path)))
        #expect(try await rpc.request("get_state")["isStreaming"] as? Bool == false)
        rpc.stop(); await rpc.waitForExit()
    }

    @Test func rejectedPromptsRestoreDraftAndStopRestoresQueue() async throws {
        let session = try controller()
        await session.connect()
        session.record.draft = "reject"
        await session.send()
        #expect(session.error == "Rejected prompt")
        #expect(session.record.draft == "reject")
        #expect(session.messages.isEmpty)
        session.record.draft = "hold"
        await session.send()
        try await eventually { session.isBusy }
        session.record.draft = "steer this"
        await session.send()
        try await eventually { session.queued == ["steer this"] }
        await session.stop()
        #expect(session.record.draft == "steer this")
        #expect(!session.isBusy)
        #expect(session.queued.isEmpty)
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func extensionConfirmationRequiresUserResponse() async throws {
        let session = try controller()
        await session.connect()
        session.record.draft = "dialog"
        await session.send()
        try await eventually { !session.dialogs.isEmpty }
        #expect(session.isBusy)
        let dialog = try #require(session.dialogs.first)
        session.respond(to: dialog, confirmed: false)
        try await eventually { !session.isBusy }
        #expect(session.messages.last?.body == "Denied")
        #expect(session.dialogs.isEmpty)
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func independentConversationsDoNotMixMessages() async throws {
        let first = try controller(), second = try controller()
        await first.connect(); await second.connect()
        first.record.draft = "first"
        second.record.draft = "second"
        await first.send(); await second.send()
        try await eventually { !first.isBusy && !second.isBusy }
        #expect(first.messages.first?.body == "first")
        #expect(second.messages.first?.body == "second")
        if let rpc = first.disconnect() { await rpc.waitForExit() }
        if let rpc = second.disconnect() { await rpc.waitForExit() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIDESK_TEST_REAL_PI"] == "1"))
    func realPiHandshakeWithoutModelCalls() async throws {
        let rpc = RPCConnection()
        try rpc.start(ProcessInvocation(executable: "/usr/bin/env", arguments: ["pi", "--mode", "rpc", "--offline", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files"]))
        defer { rpc.stop() }
        let state = try await rpc.request("get_state")
        #expect(state["isStreaming"] as? Bool == false)
        let models = try await rpc.request("get_available_models")
        #expect(models["models"] is [JSONObject])
        #expect(try await rpc.request("get_messages")["messages"] is [JSONObject])
        #expect(try await rpc.request("get_available_thinking_levels")["levels"] is [String])
        rpc.stop(); await rpc.waitForExit()
    }
}
