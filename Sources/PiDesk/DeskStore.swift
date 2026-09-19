import Foundation
import Combine

@MainActor
final class DeskStore: ObservableObject {
    @Published private(set) var clients: [Client] = []
    @Published var selectedClientID: UUID?
    @Published var selectedSessionID: UUID?
    @Published var connectOnLaunch = true
    @Published var error: String?
    private var controllers: [UUID: SessionController] = [:]
    private var observations: [UUID: AnyCancellable] = [:]
    private var saveWork: DispatchWorkItem?
    private let workspaceURL: URL
    private var canPersist = true
    private var started = false

    init(workspaceURL: URL? = nil) {
        self.workspaceURL = workspaceURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PiDesk/workspace.json")
        if FileManager.default.fileExists(atPath: self.workspaceURL.path) {
            do {
                let workspace = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: self.workspaceURL))
                guard workspace.version == 1 else { throw DeskError.message("Unsupported workspace version.") }
                clients = workspace.clients
                selectedClientID = workspace.selectedClientID
                selectedSessionID = workspace.selectedSessionID
                connectOnLaunch = workspace.connectOnLaunch
            } catch {
                // Never overwrite an unreadable workspace with empty defaults.
                canPersist = false
                self.error = "Could not load \(self.workspaceURL.path). The file will not be overwritten.\n\(error.localizedDescription)"
            }
        }
        if clients.isEmpty {
            var local = Client(name: "This Mac")
            local.sessions = [SessionRecord(workingDirectory: local.workingDirectory)]
            clients = [local]
        }
        if !clients.contains(where: { $0.id == selectedClientID }) { selectedClientID = clients.first?.id }
        if selectedClient?.sessions.contains(where: { $0.id == selectedSessionID }) != true { selectedSessionID = selectedClient?.sessions.first?.id }
    }

    var selectedClient: Client? { clients.first { $0.id == selectedClientID } }
    var selectedController: SessionController? {
        guard let client = selectedClient, let record = client.sessions.first(where: { $0.id == selectedSessionID }) else { return nil }
        return controller(for: record, client: client)
    }

    func controller(for record: SessionRecord, client: Client) -> SessionController {
        if let existing = controllers[record.id] { return existing }
        let controller = SessionController(client: client, record: record)
        controller.onRecordChange = { [weak self] record in
            guard let self, let c = self.clients.firstIndex(where: { $0.id == client.id }),
                  let s = self.clients[c].sessions.firstIndex(where: { $0.id == record.id }) else { return }
            self.clients[c].sessions[s] = record
            self.scheduleSave()
        }
        observations[record.id] = controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        controllers[record.id] = controller
        return controller
    }

    func status(for client: Client) -> SessionController.Status {
        let statuses = client.sessions.compactMap { controllers[$0.id]?.status }
        if statuses.contains(.connected) { return .connected }
        if statuses.contains(.connecting) { return .connecting }
        if statuses.contains(.failed) { return .failed }
        return .disconnected
    }

    func isBusy(_ session: SessionRecord) -> Bool { controllers[session.id]?.isBusy == true }

    func start() {
        guard !started else { return }
        started = true
        if connectOnLaunch, let controller = selectedController { Task { await controller.connect() } }
    }

    func select(client: Client, session: SessionRecord? = nil) {
        selectedClientID = client.id
        selectedSessionID = session?.id ?? client.sessions.first?.id
        scheduleSave()
        if let controller = selectedController { Task { await controller.connect() } }
    }

    func newConversation(clientID: UUID? = nil) {
        guard let index = clients.firstIndex(where: { $0.id == (clientID ?? selectedClientID) }) else { return }
        let session = SessionRecord(workingDirectory: clients[index].workingDirectory)
        clients[index].sessions.insert(session, at: 0)
        select(client: clients[index], session: session)
    }

    func saveClient(_ client: Client) throws {
        try client.validate()
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            // Existing conversations keep their own working directories.
            var updated = client
            updated.sessions = clients[index].sessions
            for record in updated.sessions { controllers[record.id]?.reconfigure(updated) }
            clients[index] = updated
            selectedClientID = updated.id
            selectedSessionID = updated.sessions.first?.id
            save()
        } else {
            var new = client
            new.sessions = [SessionRecord(workingDirectory: new.workingDirectory)]
            clients.append(new)
            select(client: new)
        }
    }

    func removeClient(_ client: Client) {
        for session in client.sessions { discardController(session.id) }
        clients.removeAll { $0.id == client.id }
        if selectedClientID == client.id { selectedClientID = clients.first?.id; selectedSessionID = clients.first?.sessions.first?.id }
        save()
    }

    func closeConversation(_ record: SessionRecord, client: Client) {
        discardController(record.id)
        guard let index = clients.firstIndex(where: { $0.id == client.id }) else { return }
        clients[index].sessions.removeAll { $0.id == record.id }
        if selectedSessionID == record.id { selectedSessionID = clients[index].sessions.first?.id }
        save()
    }

    private func discardController(_ id: UUID) {
        controllers.removeValue(forKey: id)?.disconnect()
        observations.removeValue(forKey: id)
    }

    func disconnectClient(_ client: Client) { for record in client.sessions { controllers[record.id]?.disconnect() } }

    func openSession(_ file: SavedSession, client: Client) {
        guard let index = clients.firstIndex(where: { $0.id == client.id }) else { return }
        // One writer per session, including when two local profiles point at the same file.
        for other in clients where (other.isLocal && client.isLocal) || (!other.isLocal && !client.isLocal && other.host == client.host && other.port == client.port) {
            if let existing = other.sessions.first(where: { $0.sessionPath == file.path }) { select(client: other, session: existing); return }
        }
        let record = SessionRecord(title: file.title, workingDirectory: file.cwd, sessionPath: file.path, updatedAt: file.modified)
        clients[index].sessions.insert(record, at: 0)
        select(client: clients[index], session: record)
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func save() {
        saveWork?.cancel()
        guard canPersist else { return }
        do {
            let workspace = Workspace(clients: clients, selectedClientID: selectedClientID, selectedSessionID: selectedSessionID, connectOnLaunch: connectOnLaunch)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(workspace).write(to: workspaceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspaceURL.path)
        } catch { self.error = "Could not save workspace: \(error.localizedDescription)" }
    }

    func shutdown() async {
        save()
        let connections = controllers.values.compactMap { $0.disconnect() }
        for connection in connections { await connection.waitForExit() }
    }
}

struct SavedSession: Identifiable, Decodable {
    var id: String { path }
    let path: String
    let cwd: String
    let title: String
    let modifiedMS: Double
    var modified: Date { Date(timeIntervalSince1970: modifiedMS / 1000) }
}

/// Read-only discovery. Conversation content is loaded by Pi, not reconstructed from its tree here.
enum SessionInventory {
    static func list(client: Client) async throws -> [SavedSession] {
        try client.validate()
        guard let url = Bundle.module.url(forResource: "list-sessions", withExtension: "js") else { throw DeskError.message("Session discovery helper is missing.") }
        let script = try String(contentsOf: url, encoding: .utf8)
        let invocation = ProcessInvocation.shell(client: client, command: "exec node -e " + ProcessInvocation.quote(script))
        return try await Task.detached(priority: .userInitiated) {
            let data = try run(invocation)
            return try JSONDecoder().decode([SavedSession].self, from: data).sorted { $0.modified > $1.modified }
        }.value
    }

    private static func run(_ invocation: ProcessInvocation) throws -> Data {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.standardOutput = stdout; process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain stderr concurrently so a noisy shell cannot fill its pipe and deadlock.
        let errors = OutputCapture()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errors.data = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let killWork = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 28, execute: killWork)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); group.wait()
        timeout.cancel(); killWork.cancel()
        guard process.terminationStatus == 0 else {
            throw DeskError.message("Could not list Pi sessions. Check SSH and Node on this client.\n" + String(decoding: errors.data.suffix(8000), as: UTF8.self))
        }
        return data
    }

    private final class OutputCapture: @unchecked Sendable { var data = Data() }
}
