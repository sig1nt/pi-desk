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

    @Test func forkPreservesOriginalAndHonorsCancellation() async throws {
        let session = try controller()
        defer { session.disconnect() }
        #expect(!session.canFork)
        await session.connect()
        #expect(!session.canFork)
        session.record.draft = "hello"
        await session.send()
        #expect(!session.canFork)
        try await eventually { !session.isBusy && !session.messages.isEmpty }
        let originalPath = session.record.sessionPath
        let originalID = session.id
        session.record.draft = "Keep this draft"
        await session.rename("cancel-clone")
        #expect(try await session.forkConversation() == nil)
        #expect(session.status == .connected)
        #expect(session.canFork)
        #expect(session.record.sessionPath == originalPath)
        await session.rename("My conversation")
        let fork = try #require(try await session.forkConversation())
        #expect(fork.id != originalID)
        #expect(fork.sessionPath?.hasPrefix("/tmp/fake-clone-") == true)
        #expect(fork.title == "My conversation")
        #expect(fork.draft.isEmpty)
        #expect(session.record.sessionPath == originalPath)
        #expect(session.record.draft == "Keep this draft")
        #expect(session.status == .disconnected)
        #expect(!session.isForking)
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
        var completions = 0
        session.onTurnFinished = { completions += 1 }
        await session.connect()
        #expect(session.status == .connected)
        #expect(session.models.count == 2)
        #expect(session.messages.isEmpty, "Initial system instructions must not create a chat bubble")
        #expect(session.record.sessionPath?.hasPrefix("/tmp/fake-session-") == true)
        await session.setModel("test/two")
        await session.setThinking("high")
        #expect(session.modelID == "test/two")
        #expect(session.thinking == "high")
        session.record.draft = "hello"
        #expect(session.attachImage(data: Data([0x89, 0x50, 0x4e, 0x47]), mimeType: "image/png", name: "test.png"))
        await session.send()
        try await eventually { session.messages.count == 3 }
        #expect(session.isBusy, "agent_end must not settle a run that can retry")
        #expect(completions == 0)
        try await eventually { !session.isBusy }
        #expect(completions == 1)
        try #require(session.messages.count == 3, "Tool result events must not duplicate the tool row")
        #expect(session.messages[0].body == "hello")
        #expect(session.messages[0].images.count == 1)
        #expect(session.pendingImages.isEmpty)
        #expect(session.messages[1].body == "Authoritative final text")
        #expect(session.messages[1].thinking == "Some reasoning")
        #expect(session.messages[2].arguments.contains("pwd"))
        #expect(session.messages[2].body == "tool output")
        #expect(session.messages[2].durationMS == 1234)
        #expect(session.messages[2].toolStatus == "Done · 1.2s")
        #expect(session.record.draft.isEmpty)
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func completionIgnoresAbortsCompactionDisconnectsAndDuplicateSettlement() async throws {
        let session = try controller()
        var completions = 0
        session.onTurnFinished = { completions += 1 }
        await session.connect()
        #expect(completions == 0, "Loading history isn't a finished turn")
        for text in ["reject", "/handled"] {
            session.record.draft = text
            await session.send()
            #expect(completions == 0)
        }
        await session.compact()
        #expect(completions == 0)
        session.record.draft = "hold"
        await session.send()
        await session.stop()
        #expect(completions == 0)
        session.record.draft = "duplicate-settlement"
        await session.send()
        try await eventually { !session.isBusy }
        #expect(completions == 1)
        session.record.draft = "hold"
        await session.send()
        if let rpc = session.disconnect() { await rpc.waitForExit() }
        #expect(completions == 1)
        await session.connect()
        #expect(completions == 1)
        session.record.draft = "another turn"
        await session.send()
        try await eventually { !session.isBusy }
        #expect(completions == 2)
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
        #expect(session.messages.last?.isRunning == false, "Pi 1.1's aborted settlement must end partial-message activity")
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func connectedCapabilitiesDriveComposerCompletions() async throws {
        let session = try controller()
        await session.connect()
        session.record.draft = "/cu"
        let command = try #require(session.composerSuggestions.first)
        #expect(command.title == "/custom")
        #expect(command.detail == "Fixture command")
        session.applyComposerSuggestion(command)
        #expect(session.record.draft == "/custom ")
        if let rpc = session.disconnect() { await rpc.waitForExit() }
    }

    @Test func projectPathsDriveMentionCompletions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PiDesk mentions " + UUID().uuidString)
        let docs = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("Guide".utf8).write(to: docs.appendingPathComponent("guide.md"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = try await ProjectFileInventory.list(client: Client(name: "Local"), workingDirectory: directory.path)
        #expect(paths.contains(ProjectPath(path: "docs", isDirectory: true)))
        #expect(paths.contains(ProjectPath(path: "docs/guide.md", isDirectory: false)))

        let suggestions = ComposerCompletion.suggestions(text: "Read @docs", commands: [], paths: paths)
        let file = try #require(suggestions.first(where: { $0.value == "docs/guide.md" }))
        #expect(ComposerCompletion.applying(file, to: "Read @docs") == "Read @docs/guide.md ")
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
        #expect(session.attachImage(data: Data([1, 2, 3]), mimeType: "image/png", name: "restore.png"))
        await session.send()
        #expect(session.error == "Rejected prompt")
        #expect(session.record.draft == "reject")
        #expect(session.pendingImages.count == 1)
        #expect(session.messages.isEmpty)
        if let image = session.pendingImages.first { session.removePendingImage(image.id) }
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

    @Test func backgroundCompletionNotifiesAndNotificationTargetOpensCorrectConversation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = SessionRecord(workingDirectory: "/tmp")
        let second = SessionRecord(workingDirectory: "/tmp")
        let local = Client(name: "First client", executable: try fixture().path, sessions: [first])
        let other = Client(name: "Other client", executable: try fixture().path, sessions: [second])
        let workspace = Workspace(clients: [local, other], selectedClientID: local.id, selectedSessionID: first.id, connectOnLaunch: false)
        try JSONEncoder().encode(workspace).write(to: url)
        let store = DeskStore(workspaceURL: url)
        store.setConversationWindowActive(true)
        var notifications: [(UUID, UUID)] = []
        store.onUnviewedTurnFinished = { client, record in notifications.append((client.id, record.id)) }
        let session = store.controller(for: second, client: other)
        await session.connect()
        session.record.draft = "background work"
        await session.send()
        try await eventually { !session.isBusy }
        #expect(notifications.count == 1)
        #expect(notifications.first?.0 == other.id)
        #expect(notifications.first?.1 == second.id)
        #expect(store.clients[1].sessions[0].unreadSince != nil)
        store.setConversationWindowActive(false)
        #expect(store.openConversation(sessionID: second.id))
        #expect(store.selectedClientID == other.id)
        #expect(store.selectedSessionID == second.id)
        #expect(session.record.unreadSince != nil, "Notification navigation waits for the window to become active")
        store.setConversationWindowActive(true)
        #expect(session.record.unreadSince == nil)
        await Task.yield() // Allow the selection's connect task to finish before shutdown.
        await store.shutdown()
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
