import AppKit
import UserNotifications

/// Desktop notifications are optional: unread tracking also works in unbundled
/// `swift run` builds and when macOS notification permission is denied.
@MainActor
final class TurnNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpenConversation: ((UUID) -> Void)?
    var isUnread: ((UUID) -> Bool)?
    private var center: UNUserNotificationCenter?
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var requestIDs: [UUID: Set<String>] = [:]

    func start() {
        // current() can raise an Objective-C exception without an application bundle.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        center = UNUserNotificationCenter.current()
        center?.delegate = self
    }

    func post(client: Client, session: SessionRecord) {
        guard let center else { return }
        deliveries[session.id]?.cancel()
        let requestID = "turn.\(session.id).\(UUID())"
        requestIDs[session.id, default: []].insert(requestID)
        deliveries[session.id] = Task {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                guard allowed, !Task.isCancelled, isUnread?(session.id) == true else { return }
                let content = UNMutableNotificationContent()
                content.title = "Turn finished"
                content.subtitle = client.name
                // Don't put message contents or tool output on the lock screen.
                content.body = session.title
                content.sound = .default
                content.threadIdentifier = session.id.uuidString
                content.userInfo = ["sessionID": session.id.uuidString]
                try await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: nil))
                // Viewing/closing while add() is in flight must not leave a stale alert.
                if Task.isCancelled || isUnread?(session.id) != true {
                    center.removePendingNotificationRequests(withIdentifiers: [requestID])
                    center.removeDeliveredNotifications(withIdentifiers: [requestID])
                }
            } catch {
                // Notification failure must never interrupt a conversation or unread tracking.
                NSLog("PiDesk notification: %@", error.localizedDescription)
            }
        }
    }

    func clear(sessionID: UUID) {
        deliveries.removeValue(forKey: sessionID)?.cancel()
        guard let center else { return }
        let ids = Array(requestIDs.removeValue(forKey: sessionID) ?? [])
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        // Include notifications delivered by a previous launch, but don't remove
        // a new turn's notification that arrives while this query is in flight.
        Task {
            let delivered = await center.deliveredNotifications()
            let old = delivered.filter {
                $0.request.content.userInfo["sessionID"] as? String == sessionID.uuidString &&
                    requestIDs[sessionID]?.contains($0.request.identifier) != true
            }.map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: old)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let raw = notification.request.content.userInfo["sessionID"] as? String,
              let id = UUID(uuidString: raw) else { return [] }
        return await MainActor.run { isUnread?(id) == true ? [.banner, .sound, .list] : [] }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { onOpenConversation?(id) }
    }
}
