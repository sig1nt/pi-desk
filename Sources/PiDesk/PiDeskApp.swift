import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

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
}

@main
struct PiDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PiDesk") {
            ContentView()
                .frame(minWidth: 1050, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New conversation") { NotificationCenter.default.post(name: .newConversation, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let newConversation = Notification.Name("newConversation")
}

struct Client: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var host: String
    var isLocal: Bool
    var sessions: [Session]
}

struct Session: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var preview: String
    var time: String
    var unread: Bool = false
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let body: String
    let isUser: Bool
    let time: String
}

struct ContentView: View {
    @State private var clients: [Client] = [
        Client(name: "This Mac", host: "Local", isLocal: true, sessions: [
            Session(title: "Build a SwiftUI app", preview: "Let's add a settings screen...", time: "2m"),
            Session(title: "Refactor networking", preview: "The RPC client now reconnects...", time: "Yesterday")
        ]),
        Client(name: "Studio Mac mini", host: "192.168.1.42", isLocal: false, sessions: [
            Session(title: "Review pull request", preview: "I found two small issues...", time: "9:41 AM"),
            Session(title: "Deploy checklist", preview: "All checks are green.", time: "Mon")
        ]),
        Client(name: "Build Server", host: "build.example.com", isLocal: false, sessions: [
            Session(title: "CI diagnostics", preview: "The failing test is in...", time: "Sun")
        ])
    ]
    @State private var selectedClientID: UUID?
    @State private var selectedSessionID: UUID?
    @State private var model = "Claude Sonnet 4"
    @State private var thinking = "medium"
    @State private var draft = ""
    @State private var messages: [ChatMessage] = [
        ChatMessage(body: "Show me the RPC connection status", isUser: true, time: "10:42 AM"),
        ChatMessage(body: "### Connection status\n\nThe Pi client is **connected** and ready.\n\n- Host: `localhost`\n- Transport: `stdio`\n- Status: **Healthy**\n\nSee the [Pi documentation](https://github.com/badlogic/pi-mono) for RPC details.", isUser: false, time: "10:42 AM")
    ]
    @State private var showingAddClient = false
    @State private var isSidebarVisible = true

    private var selectedClient: Client? { clients.first { $0.id == selectedClientID } }
    private var selectedSession: Session? { selectedClient?.sessions.first { $0.id == selectedSessionID } }

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                Sidebar(clients: $clients, selectedClientID: $selectedClientID, selectedSessionID: $selectedSessionID, showingAddClient: $showingAddClient)
                    .frame(width: 265)
                Divider()
            }
            Conversation(
                messages: $messages,
                draft: $draft,
                client: selectedClient,
                session: selectedSession,
                model: $model,
                thinking: $thinking
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isSidebarVisible.toggle() }
                } label: {
                    Label(isSidebarVisible ? "Hide clients" : "Show clients", systemImage: "sidebar.left")
                }
                .help(isSidebarVisible ? "Hide clients" : "Show clients")
            }
        }
        .onAppear {
            selectedClientID = clients[0].id
            selectedSessionID = clients[0].sessions[0].id
        }
        .sheet(isPresented: $showingAddClient) { AddClientSheet { name, host in
            let client = Client(name: name, host: host, isLocal: false, sessions: [Session(title: "New conversation", preview: "Start chatting with Pi", time: "Now")])
            clients.append(client); selectedClientID = client.id; selectedSessionID = client.sessions[0].id
        }.frame(width: 420, height: 275) }
        .onReceive(NotificationCenter.default.publisher(for: .newConversation)) { _ in
            if let id = selectedClientID, let index = clients.firstIndex(where: {$0.id == id}) {
                let session = Session(title: "New conversation", preview: "Start chatting with Pi", time: "Now")
                clients[index].sessions.insert(session, at: 0); selectedSessionID = session.id; messages = []
            }
        }
    }
}

struct Sidebar: View {
    @Binding var clients: [Client]
    @Binding var selectedClientID: UUID?
    @Binding var selectedSessionID: UUID?
    @Binding var showingAddClient: Bool

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
                Button { showingAddClient = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add client")
            }.padding(.horizontal, 18).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($clients) { $client in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Circle().fill(client.isLocal ? Color.green : Color.blue).frame(width: 8, height: 8)
                                Text(client.name).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Image(systemName: "ellipsis").font(.caption).foregroundStyle(.tertiary)
                            }
                            Text(client.host).font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                            ForEach(client.sessions) { session in
                                Button {
                                    selectedClientID = client.id; selectedSessionID = session.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "bubble.left").font(.caption).foregroundStyle(.secondary)
                                        Text(session.title).lineLimit(1)
                                        Spacer()
                                        Text(session.time).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 7).padding(.horizontal, 10)
                                    .background(selectedClientID == client.id && selectedSessionID == session.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }.buttonStyle(.plain).padding(.leading, 9)
                            }
                        }.padding(.horizontal, 14)
                    }
                }
            }
            Spacer()
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
                Text("Settings").font(.callout)
                Spacer()
                Text("⌘,").font(.caption).foregroundStyle(.tertiary)
            }.padding(16)
        }.background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct Conversation: View {
    @Binding var messages: [ChatMessage]
    @Binding var draft: String
    let client: Client?
    let session: Session?
    @Binding var model: String
    @Binding var thinking: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session?.title ?? "Conversation").font(.headline)
                    HStack(spacing: 5) { Circle().fill(.green).frame(width: 7, height: 7); Text(client?.name ?? "No client selected").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(action: {}) { Image(systemName: "ellipsis.circle") }.buttonStyle(.plain).font(.title3).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.vertical, 17)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if messages.isEmpty { EmptyConversationView() }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                    }
                }.frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .center).padding(.top, 34).padding(.horizontal, 26)
            }
            Composer(draft: $draft, model: $model, thinking: $thinking) {
                guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                messages.append(ChatMessage(body: draft, isUser: true, time: "Now")); draft = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { messages.append(ChatMessage(body: "I'm on it — connected through the Pi RPC client.", isUser: false, time: "Now")) }
            }.padding(24)
        }.frame(maxWidth: .infinity)
    }
}

struct EmptyConversationView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("Ready when you are").font(.headline)
            Text("Send a message to start this conversation.").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 90)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser { Spacer(minLength: 40) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
                Group {
                    if message.isUser {
                        Text(message.body).font(.body).lineSpacing(3)
                    } else {
                        MarkdownMessageView(markdown: message.body)
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
                .background(message.isUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(message.isUser ? .white : .primary)
                Text(message.time).font(.caption2).foregroundStyle(.tertiary)
            }
        }.frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

struct MarkdownMessageView: View {
    let markdown: String

    private var lines: [String] {
        markdown.components(separatedBy: .newlines)
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") {
                    Text(attributed(String(line.dropFirst(4))))
                        .font(.headline)
                        .padding(.bottom, 2)
                } else if line.hasPrefix("## ") {
                    Text(attributed(String(line.dropFirst(3))))
                        .font(.title3.bold())
                        .padding(.bottom, 2)
                } else if line.hasPrefix("# ") {
                    Text(attributed(String(line.dropFirst(2))))
                        .font(.title2.bold())
                        .padding(.bottom, 2)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(attributed(String(line.dropFirst(2))))
                            .textSelection(.enabled)
                    }
                } else if line.isEmpty {
                    Spacer().frame(height: 2)
                } else {
                    Text(attributed(line))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct Composer: View {
    @Binding var draft: String
    @Binding var model: String
    @Binding var thinking: String
    let send: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Pi…", text: $draft, axis: .vertical).textFieldStyle(.plain).lineLimit(1...5).frame(minHeight: 32).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 32, height: 32).background(Color.accentColor, in: Circle()) }.buttonStyle(.plain)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary))

            HStack(spacing: 12) {
                Spacer()
                Picker("Model", selection: $model) {
                    Text("Claude Sonnet 4").tag("Claude Sonnet 4")
                    Text("GPT-4.1").tag("GPT-4.1")
                    Text("o3").tag("o3")
                }
                .labelsHidden()
                .help("Model")
                .fixedSize()

                Picker("Thinking", selection: $thinking) {
                    Text("Off").tag("off")
                    Text("Minimal").tag("minimal")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Extra High").tag("xhigh")
                    Text("Maximum").tag("max")
                }
                .labelsHidden()
                .help("Thinking level")
                .fixedSize()
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .controlSize(.small)
        }
    }
}

struct AddClientSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    let onAdd: (String, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) { Text("Connect a Pi client").font(.title2.bold()); Text("Add a local or remote Pi instance over RPC.").foregroundStyle(.secondary); TextField("Display name", text: $name); TextField("Host or SSH address", text: $host); Spacer(); HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Connect") { onAdd(name.isEmpty ? "New client" : name, host.isEmpty ? "localhost" : host); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) } }.padding(26)
    }
}
