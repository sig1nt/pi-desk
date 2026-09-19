import SwiftUI
import AppKit

struct ClientSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var client: Client
    let isEditing: Bool
    let onSave: (Client) throws -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? "Edit Pi client" : "Connect a Pi client").font(.title2.bold())
            Text("Run Pi locally or through an SSH connection.").foregroundStyle(.secondary)
            Form {
                TextField("Display name", text: $client.name)
                Picker("Connection", selection: $client.isLocal) { Text("Local").tag(true); Text("SSH").tag(false) }
                if !client.isLocal {
                    TextField("SSH host or user@host", text: $client.host)
                    TextField("Port", value: $client.port, formatter: NumberFormatter.port)
                }
                HStack {
                    TextField("Working directory", text: $client.workingDirectory)
                    if client.isLocal {
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { client.workingDirectory = url.path }
                        }
                    }
                }
                TextField("Pi executable", text: $client.executable)
            }
            Text(client.isLocal ? "Uses Pi's existing local authentication and settings. The executable can be pi or a full path (not a shell command)." : "Uses ~/.ssh/config and SSH keys/agent. First connect once in Terminal to verify the host key. Pi and Node must be installed and authenticated on the remote host.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Pi can read, write, and run commands in the working directory. Project trust follows Pi's settings; PiDesk does not automatically approve projects.")
                .font(.caption).foregroundStyle(.secondary)
            if isEditing { Text("Saving restarts connected conversations. Changing the directory moves them to it; saved conversations are forked so their active history is preserved.").font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Connect") {
                    client.name = client.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    client.host = client.host.trimmingCharacters(in: .whitespacesAndNewlines)
                    do { try onSave(client); dismiss() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 510)
    }
}

extension NumberFormatter {
    static var port: NumberFormatter { let formatter = NumberFormatter(); formatter.numberStyle = .none; formatter.allowsFloats = false; return formatter }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: DeskStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2.bold())
            Toggle("Connect the selected conversation on launch", isOn: $store.connectOnLaunch)
            Text("Use each client's ••• menu to set its host, working directory, and Pi executable.").foregroundStyle(.secondary)
            Divider()
            Text("Authentication").font(.headline)
            Text("PiDesk uses Pi's own credentials on each host. Run pi and use /login in a terminal to authenticate. No API keys or SSH passwords are stored by PiDesk.").font(.callout).foregroundStyle(.secondary)
            Text("Sessions are saved by Pi on the host where they run. PiDesk saves client profiles, session references, and drafts in ~/Library/Application Support/PiDesk/workspace.json.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { store.save(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 480)
        .onChange(of: store.connectOnLaunch) { _ in store.scheduleSave() }
    }
}

struct SessionBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: Client
    let open: (SavedSession) -> Void
    @State private var sessions: [SavedSession] = []
    @State private var selected: String?
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    private var filtered: [SavedSession] { sessions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open saved session").font(.title2.bold())
            Text("\(client.name) · Pi session history").foregroundStyle(.secondary)
            TextField("Search conversations or directories", text: $query)
            if loading { ProgressView("Loading sessions…").frame(maxWidth: .infinity, minHeight: 260) }
            else if let error {
                ScrollView { Text(error).foregroundStyle(.red).textSelection(.enabled) }.frame(height: 260)
            } else if filtered.isEmpty {
                Text("No saved sessions found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 260)
            } else {
                List(filtered, selection: $selected) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).lineLimit(1)
                        Text(session.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(session.modified.formatted()).font(.caption2).foregroundStyle(.tertiary)
                    }.tag(session.path).padding(.vertical, 3)
                }.frame(height: 300)
            }
            Text("Close the session in other Pi clients before opening it here. PiDesk resumes its active branch; it does not attach to a running terminal process.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { Task { await load() } }.disabled(loading)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let session = filtered.first(where: { $0.path == selected }) { open(session); dismiss() }
                }.disabled(filtered.first(where: { $0.path == selected }) == nil).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 590)
        .task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        do { sessions = try await SessionInventory.list(client: client) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let save: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename conversation").font(.title2.bold())
            TextField("Name", text: $name)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 420)
    }
}

struct SessionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: SessionController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Session info").font(.title2.bold())
            Text(controller.record.title).font(.headline)
            Text("Client: \(controller.client.name) (\(controller.client.address))")
            Text("Directory: \(controller.record.workingDirectory)")
            Text("Session: \(controller.record.sessionPath ?? "Not yet created")")
            Text(controller.statistics.isEmpty ? "Connect to load usage statistics." : controller.statistics).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.textSelection(.enabled).padding(26).frame(width: 550)
    }
}

struct ExtensionDialogView: View {
    let dialog: ExtensionDialog
    let respond: (String?, Bool?) -> Void
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dialog.title).font(.headline)
            if !dialog.message.isEmpty { Text(dialog.message).font(.callout).textSelection(.enabled) }
            if dialog.method == "select" {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(dialog.options.enumerated()), id: \.offset) { _, option in Button(option) { respond(option, nil) } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
            } else if dialog.method == "editor" {
                TextEditor(text: $value).font(.body.monospaced()).frame(height: 120)
            } else if dialog.method == "input" {
                TextField(dialog.placeholder, text: $value).onSubmit { respond(value, nil) }
            }
            HStack {
                Button("Cancel") { respond(nil, nil) }
                Spacer()
                if dialog.method == "confirm" {
                    Button("No") { respond(nil, false) }
                    Button("Yes") { respond(nil, true) }.buttonStyle(.borderedProminent)
                } else if dialog.method != "select" {
                    Button("Submit") { respond(value, nil) }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(14).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { value = dialog.prefill }
    }
}
