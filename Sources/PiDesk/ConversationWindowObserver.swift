import SwiftUI
import AppKit
import Combine

/// Selection alone isn't a view: a background, hidden, or minimized window must
/// keep its selected conversation unread until the user returns to it.
struct ConversationWindowObserver: NSViewRepresentable {
    let onActiveChange: (Bool) -> Void

    func makeNSView(context: Context) -> ConversationWindowView {
        ConversationWindowView(onActiveChange: onActiveChange)
    }

    func updateNSView(_ nsView: ConversationWindowView, context: Context) {}

    static func dismantleNSView(_ nsView: ConversationWindowView, coordinator: ()) {
        nsView.onActiveChange(false)
    }
}

final class ConversationWindowView: NSView {
    let onActiveChange: (Bool) -> Void
    private var observations: [AnyCancellable] = []

    init(onActiveChange: @escaping (Bool) -> Void) {
        self.onActiveChange = onActiveChange
        super.init(frame: .zero)
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification
        ]
        observations = names.map { name in
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in self?.updateActivity() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Don't publish observable state during SwiftUI's view update.
        DispatchQueue.main.async { [weak self] in self?.updateActivity() }
    }

    private func updateActivity() {
        onActiveChange(NSApp.isActive && window?.isKeyWindow == true &&
                       window?.isVisible == true && window?.isMiniaturized == false &&
                       window?.occlusionState.contains(.visible) == true)
    }
}
