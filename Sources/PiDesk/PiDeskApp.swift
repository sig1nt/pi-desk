import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: DeskStore?
    func applicationWillFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.windows.first?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await store?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct PiDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DeskStore(workspaceURL: ProcessInfo.processInfo.environment["PIDESK_WORKSPACE"].map { URL(fileURLWithPath: $0) })
    var body: some Scene {
        Window("PiDesk", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1050, minHeight: 680)
                .onAppear { appDelegate.store = store }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New conversation") { store.newConversation() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .showSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

extension Notification.Name { static let showSettings = Notification.Name("showSettings") }

struct ContentView: View {
    @ObservedObject var store: DeskStore
    @State private var editingClient: Client?
    @State private var browsingClient: Client?
    @State private var removingClient: Client?
    @State private var showingSettings = false
    @State private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                Sidebar(store: store, add: { editingClient = Client(name: "", isLocal: false) }, edit: { editingClient = $0 }, browse: { browsingClient = $0 }, remove: { removingClient = $0 }, settings: { showingSettings = true })
                    .frame(width: 265)
                Divider()
            }
            if let controller = store.selectedController {
                Conversation(controller: controller, new: { store.newConversation() }, browse: { browsingClient = store.selectedClient })
                    .id(controller.id)
            } else {
                VStack {
                    EmptyConversationView()
                    Button("New conversation") { store.newConversation() }.disabled(store.selectedClient == nil)
                    if store.clients.isEmpty { Button("Add client") { editingClient = Client(name: "This Mac") } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isSidebarVisible.toggle() }
                } label: { Label(isSidebarVisible ? "Hide clients" : "Show clients", systemImage: "sidebar.left") }
                .help(isSidebarVisible ? "Hide clients" : "Show clients")
            }
        }
        .onAppear { store.start() }
        .sheet(item: $editingClient) { client in
            ClientSheet(client: client, isEditing: store.clients.contains(where: { $0.id == client.id })) { try store.saveClient($0) }
        }
        .sheet(item: $browsingClient) { client in SessionBrowserSheet(client: client) { store.openSession($0, client: client) } }
        .sheet(isPresented: $showingSettings) { SettingsSheet(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in showingSettings = true }
        .alert("Remove client?", isPresented: Binding(get: { removingClient != nil }, set: { if !$0 { removingClient = nil } })) {
            Button("Cancel", role: .cancel) { removingClient = nil }
            Button("Remove", role: .destructive) { if let client = removingClient { store.removeClient(client) }; removingClient = nil }
        } message: { Text("This disconnects its conversations and removes the client from PiDesk. Pi's session files are not deleted.") }
        .alert("PiDesk", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
            if store.recoveryRequired { Button("Recover workspace…") { store.error = nil; showingSettings = true } }
        } message: { Text(store.error ?? "") }
    }
}

struct Sidebar: View {
    @ObservedObject var store: DeskStore
    let add: () -> Void
    let edit: (Client) -> Void
    let browse: (Client) -> Void
    let remove: (Client) -> Void
    let settings: () -> Void
    @State private var closingSession: SessionRecord?
    @State private var closingClient: Client?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "circle.hexagongrid.fill").font(.title2).foregroundStyle(.blue)
                Text("PiDesk").font(.system(size: 17, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 38).padding(.bottom, 20)
            HStack {
                Text("CLIENTS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: add) { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add client")
            }.padding(.horizontal, 18).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.clients) { client in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Button { store.select(client: client) } label: {
                                    HStack(spacing: 8) {
                                        Circle().fill(statusColor(store.status(for: client), local: client.isLocal)).frame(width: 8, height: 8)
                                        Text(client.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    }
                                }.buttonStyle(.plain).help(store.status(for: client).rawValue)
                                Spacer()
                                Menu {
                                    Button("New conversation") { store.newConversation(clientID: client.id) }
                                    Button("Open saved session…") { browse(client) }
                                    Divider()
                                    Button("Edit client…") { edit(client) }
                                    Button("Disconnect") { store.disconnectClient(client) }
                                    Button("Remove client…", role: .destructive) { remove(client) }
                                } label: { Image(systemName: "ellipsis").font(.caption).foregroundStyle(.tertiary) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Client actions")
                            }
                            Text(client.address).font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                            ForEach(client.sessions) { session in
                                Button { store.select(client: client, session: session) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: store.isBusy(session) ? "ellipsis.bubble" : "bubble.left").font(.caption).foregroundStyle(.secondary)
                                        Text(session.title).lineLimit(1)
                                        Spacer()
                                        Text(session.time).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 7).padding(.horizontal, 10)
                                    .background(store.selectedClientID == client.id && store.selectedSessionID == session.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).padding(.leading, 9)
                                .contextMenu {
                                    Button("Open conversation") { store.select(client: client, session: session) }
                                    Button("Close conversation…") { closingSession = session; closingClient = client }
                                }
                                .help(session.workingDirectory)
                            }
                        }.padding(.horizontal, 14)
                    }
                }
            }
            Spacer()
            Divider()
            Button(action: settings) {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                    Text("Settings").font(.callout)
                    Spacer()
                    Text("⌘,").font(.caption).foregroundStyle(.tertiary)
                }.padding(16).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.background(Color(nsColor: .underPageBackgroundColor))
        .alert("Close conversation?", isPresented: Binding(get: { closingSession != nil }, set: { if !$0 { closingSession = nil } })) {
            Button("Cancel", role: .cancel) { closingSession = nil }
            Button("Close") {
                if let session = closingSession, let client = closingClient { store.closeConversation(session, client: client) }
                closingSession = nil
            }
        } message: { Text("Any running work will stop. The Pi session stays on its host and can be reopened from Open saved session.") }
    }
}

func statusColor(_ status: SessionController.Status, local: Bool = true) -> Color {
    switch status {
    case .connected: return local ? .green : .blue
    case .connecting: return .orange
    case .failed: return .red
    case .disconnected: return .gray
    }
}

struct Conversation: View {
    @ObservedObject var controller: SessionController
    let new: () -> Void
    let browse: () -> Void
    @State private var renaming = false
    @State private var showingInfo = false
    @State private var followBottom = true
    @State private var transcriptHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.record.title).font(.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor(controller.status, local: controller.client.isLocal)).frame(width: 7, height: 7)
                        Text("\(controller.client.name) · \(controller.statusText)").font(.caption).foregroundStyle(.secondary)
                    }.help(controller.record.workingDirectory)
                }
                Spacer()
                if controller.status == .disconnected || controller.status == .failed {
                    Button(controller.status == .failed ? "Reconnect" : "Connect") { Task { await controller.connect() } }.controlSize(.small)
                }
                Menu {
                    Button("New conversation", action: new)
                    Button("Open saved session…", action: browse)
                    Button("Rename…") { renaming = true }.disabled(!controller.canConfigure)
                    Button("Session info…") { showingInfo = true }
                    Divider()
                    Button("Compact context") { Task { await controller.compact() } }.disabled(!controller.canConfigure)
                    Button("Copy last response") { copy(controller.messages.last(where: { $0.role == "assistant" })?.body ?? "") }
                    Button("Export transcript…") { exportTranscript(fullHistory: false) }.disabled(controller.messages.isEmpty)
                    Button("Export full Pi history…") { exportTranscript(fullHistory: true) }.disabled(controller.status != .connected)
                    Divider()
                    Button("Disconnect") { controller.disconnect() }.disabled(controller.status == .disconnected)
                } label: { Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Conversation actions")
            }.padding(.horizontal, 28).padding(.vertical, 17)
            Divider()
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if controller.messages.isEmpty { EmptyConversationView() }
                            ForEach(controller.messages) { MessageBubble(message: $0) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .center).padding(.top, 34).padding(.horizontal, 26)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptFrameKey.self, value: geometry.frame(in: .named("transcript")))
                            })
                    }
                    .coordinateSpace(name: "transcript")
                    .onPreferenceChange(TranscriptFrameKey.self) { frame in
                        let resized = abs(frame.height - transcriptHeight) > 0.5 || abs(viewport.size.height - viewportHeight) > 0.5
                        transcriptHeight = frame.height; viewportHeight = viewport.size.height
                        if resized {
                            // Layout growth (including thinking/tools/images) must not look like the user scrolling up.
                            if followBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                        } else { followBottom = frame.maxY <= viewport.size.height + 60 }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followBottom {
                            Button { followBottom = true; proxy.scrollTo("bottom", anchor: .bottom) } label: {
                                Image(systemName: "arrow.down.to.line").padding(8)
                            }.help("Jump to latest message").padding(12)
                        }
                    }
                }
                .onChange(of: controller.isSubmitting) { submitting in if submitting { followBottom = true; proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if let error = controller.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    ScrollView { Text(error).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 72)
                    Button { controller.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss error")
                }.padding(.horizontal, 28).padding(.top, 8)
            }
            VStack(spacing: 10) {
                if let dialog = controller.dialogs.first {
                    ExtensionDialogView(dialog: dialog) { value, confirmed in controller.respond(to: dialog, value: value, confirmed: confirmed) }.id(dialog.id)
                }
                ForEach(controller.widgets.keys.sorted(), id: \.self) { key in
                    Text(controller.widgets[key] ?? "").font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !controller.queued.isEmpty {
                    Text("\(controller.queued.count) queued · Stop restores queued messages to the editor").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let text = controller.record.deliveryUnknown {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Delivery unknown — this message may already be running", systemImage: "exclamationmark.triangle").font(.caption.bold())
                        Text(text).font(.caption).lineLimit(3).textSelection(.enabled)
                        Text("Check the conversation after reconnecting before deciding to resend. Sending is paused until you choose.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Keep sent / discard") { controller.resolveUnknownDelivery(restoreDraft: false) }
                            Button("Restore for manual resend") { controller.resolveUnknownDelivery(restoreDraft: true) }
                        }.controlSize(.small)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Composer(controller: controller)
            }.padding(24)
        }.frame(maxWidth: .infinity)
        .onExitCommand { if controller.isBusy { Task { await controller.stop() } } }
        .sheet(isPresented: $renaming) { RenameSheet(name: controller.record.title) { name in Task { await controller.rename(name) } } }
        .sheet(isPresented: $showingInfo) { SessionInfoSheet(controller: controller) }
    }

    private func exportTranscript(fullHistory: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fullHistory ? "pi-history.json" : "conversation.md"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task {
                do {
                    let data: Data
                    if fullHistory { data = try await controller.exportHistory() }
                    else { data = Data(try await controller.exportMarkdown().utf8) }
                    try data.write(to: url, options: .atomic)
                } catch { controller.error = error.localizedDescription }
            }
        }
    }
}

private struct TranscriptFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

struct EmptyConversationView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("Ready when you are").font(.headline)
            Text("Send a message to start this conversation.").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 90)
    }
}

struct Composer: View {
    @ObservedObject var controller: SessionController
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(controller.isBusy ? "Steer Pi…" : "Message Pi…", text: $controller.record.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).frame(minHeight: 32)
                    .onSubmit { Task { await controller.send() } }
                if controller.isBusy || controller.isSubmitting {
                    Button { Task { await controller.stop() } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32)
                    }.buttonStyle(.plain).help("Stop and restore queued messages (Escape)")
                }
                Button { Task { await controller.send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 32, height: 32).background(controller.canSend ? Color.accentColor : Color.gray.opacity(0.4), in: Circle())
                }.buttonStyle(.plain).disabled(!controller.canSend).keyboardShortcut(.return, modifiers: .command)
                    .help(controller.isBusy ? "Queue a steering message" : "Send message (⌘Return)")
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary))
            HStack(spacing: 12) {
                Text(controller.extensionStatus.values.sorted().joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Picker("Model", selection: Binding(get: { controller.modelID }, set: { id in Task { await controller.setModel(id) } })) {
                    if !controller.models.contains(where: { $0.id == controller.modelID }) {
                        Text(controller.modelID.isEmpty ? "No model" : controller.modelID).tag(controller.modelID)
                    }
                    ForEach(controller.models) { Text("\($0.name) · \($0.provider)").tag($0.id) }
                }.labelsHidden().help("Model").frame(maxWidth: 280).fixedSize(horizontal: false, vertical: true)
                Picker("Thinking", selection: Binding(get: { controller.thinking }, set: { level in Task { await controller.setThinking(level) } })) {
                    ForEach(controller.thinkingLevels, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden().help("Thinking level").fixedSize()
            }
            .disabled(!controller.canConfigure)
            .pickerStyle(.menu).buttonStyle(.borderless).menuIndicator(.hidden).controlSize(.small)
        }
    }
}
