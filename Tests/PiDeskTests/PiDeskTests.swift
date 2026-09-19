import Foundation
import AppKit
import Testing
@testable import PiDesk

struct PiDeskTests {
    @Test func strictJSONLFramingAcrossEveryByte() throws {
        var decoder = JSONLDecoder()
        let text = "Hello 🌍\u{2028}still one record\u{2029}!"
        var data = try JSONSerialization.data(withJSONObject: ["type": "event", "text": text], options: [.withoutEscapingSlashes])
        data.append(contentsOf: [13, 10])
        var records: [JSONObject] = []
        for byte in data { records += try decoder.append(Data([byte])) }
        #expect(records.count == 1)
        #expect(records[0]["text"] as? String == text)
        #expect(try decoder.append(Data("\n{\"type\":\"next\"}\n".utf8)).count == 1)
    }

    @Test func invalidJSONIsReported() {
        var decoder = JSONLDecoder()
        #expect(throws: (any Error).self) { try decoder.append(Data("shell startup noise\n".utf8)) }
    }

    @Test func sshValidationAndQuoting() throws {
        var client = Client(name: "Remote", host: "dev@build-host", isLocal: false, port: 2222)
        try client.validate()
        let record = SessionRecord(workingDirectory: "~/project's $(touch /tmp/should-not-exist)", sessionPath: "/tmp/a b.jsonl")
        let invocation = try ProcessInvocation.rpc(client: client, session: record)
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(invocation.arguments.contains("BatchMode=yes"))
        #expect(invocation.arguments.contains("dev@build-host"))
        #expect(ProcessInvocation.quote("a'b") == "'a'\\''b'")
        #expect(ProcessInvocation.path("~/a b") == "\"$HOME\"/'a b'")
        var fork = record
        fork.forkFromPath = "/old/session.jsonl"
        let forkInvocation = try ProcessInvocation.rpc(client: client, session: fork)
        #expect(forkInvocation.arguments.joined(separator: " ").contains("--fork"))
        #expect(forkInvocation.arguments.joined(separator: " ").contains("/old/session.jsonl"))
        for host in ["-oProxyCommand=evil", "host;echo bad", "a\nb", "ssh://host", "host -p 22"] {
            client.host = host
            #expect(throws: (any Error).self) { try client.validate() }
        }
        client.host = "user@[::1]"; try client.validate()
        client.port = 0
        #expect(throws: (any Error).self) { try client.validate() }
    }

    @Test func messageParsingAndCodeFences() {
        let message = ChatMessage.parse(["role": "assistant", "content": [
            ["type": "thinking", "thinking": "Reasoning"], ["type": "text", "text": "Hello"],
            ["type": "toolCall", "name": "bash", "arguments": ["command": "pwd"]]
        ], "stopReason": "error", "errorMessage": "Quota exceeded"])!
        #expect(message.thinking == "Reasoning")
        #expect(message.body.contains("Quota exceeded"))
        #expect(message.isError)
        #expect(message.arguments.contains("pwd"))
        var tool = ChatMessage(role: "toolResult", toolName: "bash", arguments: "{\n  \"command\" : \"swift test\"\n}")
        #expect(tool.toolDisplayName == "swift test")
        tool.arguments = "pwd"
        #expect(tool.toolDisplayName == "pwd")
        tool.toolName = "read"
        #expect(tool.toolDisplayName == "read")
        let restored = parseConversationMessages([
            ["role": "assistant", "content": [["type": "toolCall", "id": "call-1", "name": "bash", "arguments": ["command": "swift build"]]]],
            ["role": "toolResult", "toolCallId": "call-1", "toolName": "bash", "content": [["type": "text", "text": "Done"]]]
        ])
        #expect(restored.count == 1)
        #expect(restored[0].toolDisplayName == "swift build")
        let blocks = MarkdownBlock.parse("# Title\n```swift\nlet x = 1\n\n// hi\n```\nDone")
        #expect(blocks.count == 3)
        #expect(blocks[1].text == "let x = 1\n\n// hi")
        #expect(blocks[1].isCode)
        #expect(MarkdownBlock.parse("```\npartial")[0].isCode)
    }

    @Test @MainActor func commandVInterceptsImagesButNotText() throws {
        let pasteboard = NSPasteboard.general
        defer { pasteboard.clearContents() }
        let monitor = ComposerImagePasteMonitor()
        monitor.isActive = true
        var pasted = false
        monitor.pasteImage = { pasted = true }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9))
        pasteboard.clearContents()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(pasteboard.setData(png, forType: .png))
        #expect(monitor.handle(event) == nil)
        #expect(pasted)
        pasted = false
        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)
        #expect(monitor.handle(event) != nil)
        #expect(!pasted)
    }

    @Test @MainActor func workspacePersistenceAndIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let store = DeskStore(workspaceURL: url)
        let first = store.selectedController!
        first.record.draft = "Unsent draft"
        first.record.title = "My work"
        store.connectOnLaunch = false
        store.save()
        let restored = DeskStore(workspaceURL: url)
        #expect(restored.selectedController?.record.draft == "Unsent draft")
        #expect(restored.selectedController?.record.title == "My work")
        #expect(!restored.connectOnLaunch)
        let remote = Client(name: "Remote", host: "server", isLocal: false)
        let second = restored.controller(for: SessionRecord(workingDirectory: "/project"), client: remote)
        #expect(second.record.draft.isEmpty)
        #expect(first.record.draft == "Unsent draft")
    }

    @Test @MainActor func changingClientDirectoryMovesAndForksExistingConversations() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DeskStore(workspaceURL: url)
        let originalSessionID = try #require(store.selectedSessionID)
        let controller = try #require(store.selectedController)
        controller.record.sessionPath = "/tmp/original-session.jsonl"
        var client = try #require(store.selectedClient)
        client.workingDirectory = "/tmp/new-project"
        try store.saveClient(client)
        let moved = try #require(store.selectedClient?.sessions.first(where: { $0.id == originalSessionID }))
        #expect(moved.workingDirectory == "/tmp/new-project")
        #expect(moved.sessionPath == nil)
        #expect(moved.forkFromPath == "/tmp/original-session.jsonl")
        #expect(store.selectedSessionID == originalSessionID)
        #expect(store.selectedController?.record.workingDirectory == "/tmp/new-project")
    }

    @Test @MainActor func corruptWorkspaceIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        let store = DeskStore(workspaceURL: url)
        #expect(store.error != nil)
        store.save()
        #expect(try String(contentsOf: url) == "broken")
    }
}
