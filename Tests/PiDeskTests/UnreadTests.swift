import Foundation
import Testing
@testable import PiDesk

@MainActor
struct UnreadTests {
    @Test func unreadPersistsAndOnlyActiveSelectionMarksItViewed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = SessionRecord(title: "First", workingDirectory: "/tmp")
        let second = SessionRecord(title: "Second", workingDirectory: "/tmp")
        let client = Client(name: "Local", sessions: [first, second])
        let workspace = Workspace(clients: [client], selectedClientID: client.id, selectedSessionID: first.id, connectOnLaunch: false)
        try JSONEncoder().encode(workspace).write(to: url)
        let store = DeskStore(workspaceURL: url)
        let a = store.controller(for: first, client: client)
        let b = store.controller(for: second, client: client)
        var notified: [UUID] = [], viewed: [UUID] = []
        store.onUnviewedTurnFinished = { _, session in notified.append(session.id) }
        store.onConversationViewed = { viewed.append($0) }

        // Selected, but the app isn't active: this is still unread.
        a.onTurnFinished?()
        #expect(a.record.unreadSince != nil)
        #expect(notified == [first.id])
        store.save()
        let restored = DeskStore(workspaceURL: url)
        #expect(restored.selectedController?.record.unreadSince != nil)
        restored.setConversationWindowActive(true)
        #expect(restored.selectedController?.record.unreadSince == nil)
        restored.save()
        #expect(DeskStore(workspaceURL: url).selectedController?.record.unreadSince == nil)

        store.setConversationWindowActive(true)
        #expect(a.record.unreadSince == nil)
        #expect(viewed == [first.id])
        a.onTurnFinished?()
        #expect(a.record.unreadSince == nil)
        #expect(notified.count == 1, "Don't alert for the conversation being viewed")
        b.onTurnFinished?()
        #expect(b.record.unreadSince != nil)
        #expect(notified == [first.id, second.id])
        // Record updates (drafts, session state, title) must retain the unread dot.
        b.record.draft = "next question"
        #expect(store.clients[0].sessions[1].unreadSince != nil)
        store.setConversationWindowActive(false)
        store.selectedSessionID = second.id
        #expect(b.record.unreadSince != nil)
        store.setConversationWindowActive(true)
        #expect(b.record.unreadSince == nil)
        #expect(viewed == [first.id, second.id])
        #expect(store.clients[0].sessions[1].unreadSince == nil)
        // A new background completion makes the same conversation unread again.
        store.selectedSessionID = first.id
        b.onTurnFinished?()
        #expect(b.record.unreadSince != nil)
        #expect(notified == [first.id, second.id, second.id])
        store.closeConversation(b.record, client: client)
        #expect(viewed.last == second.id)
        #expect(!store.openConversation(sessionID: second.id))
        #expect(store.selectedSessionID == first.id)
        store.save()
    }

    @Test func legacyWorkspaceAndUninstantiatedControllers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = Data("""
        {"id":"\(UUID())","title":"Old conversation","workingDirectory":"/tmp","updatedAt":0,"draft":""}
        """.utf8)
        let old = try JSONDecoder().decode(SessionRecord.self, from: legacy)
        #expect(old.unreadSince == nil)
        var unread = SessionRecord(workingDirectory: "/tmp")
        unread.unreadSince = Date()
        let client = Client(name: "Local", sessions: [old, unread])
        let workspace = Workspace(clients: [client], selectedClientID: client.id, selectedSessionID: old.id, connectOnLaunch: false)
        try JSONEncoder().encode(workspace).write(to: url)
        let store = DeskStore(workspaceURL: url)
        store.setConversationWindowActive(true)
        store.selectedSessionID = unread.id
        #expect(store.clients[0].sessions[1].unreadSince == nil)
        #expect(store.selectedController?.record.unreadSince == nil)
        store.save()
    }
}
