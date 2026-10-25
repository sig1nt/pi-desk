import Foundation
import Combine

@MainActor
final class DeskStore: ObservableObject {
    @Published private(set) var clients: [Client] = []
    @Published var selectedClientID: UUID? { didSet { markSelectedConversationViewed() } }
    @Published var selectedSessionID: UUID? { didSet { markSelectedConversationViewed() } }
    private var isConversationWindowActive = false
    var onUnviewedTurnFinished: ((Client, SessionRecord) -> Void)?
    var onConversationViewed: ((UUID) -> Void)?
    @Published var connectOnLaunch = true
    @Published var error: String?
    private var controllers: [UUID: SessionController] = [:]
    private var observations: [UUID: AnyCancellable] = [:]
    private var saveWork: DispatchWorkItem?
    private let workspaceURL: URL
    private var canPersist = true
    private var recoveringWorkspace = false
    private var started = false
    private var retiringConnections: [RPCConnection] = []
    @Published private(set) var recoveryRequired = false

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
                recoveryRequired = true
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
        controller.onTurnFinished = { [weak self] in self?.turnFinished(sessionID: record.id) }
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

    func setConversationWindowActive(_ active: Bool) {
        isConversationWindowActive = active
        markSelectedConversationViewed()
    }

    private func turnFinished(sessionID: UUID) {
        guard let client = clients.first(where: { $0.sessions.contains(where: { $0.id == sessionID }) }),
              let controller = controllers[sessionID] else { return }
        if isConversationWindowActive && selectedClientID == client.id && selectedSessionID == sessionID {
            markSelectedConversationViewed()
            return
        }
        controller.record.unreadSince = Date()
        onUnviewedTurnFinished?(client, controller.record)
    }

    private func markSelectedConversationViewed() {
        guard isConversationWindowActive,
              let c = clients.firstIndex(where: { $0.id == selectedClientID }),
              let s = clients[c].sessions.firstIndex(where: { $0.id == selectedSessionID }),
              clients[c].sessions[s].unreadSince != nil else { return }
        let id = clients[c].sessions[s].id
        if let controller = controllers[id] { controller.record.unreadSince = nil }
        else { clients[c].sessions[s].unreadSince = nil }
        onConversationViewed?(id)
        scheduleSave()
    }

    /// Notification targets may refer to conversations that have since been closed.
    @discardableResult
    func openConversation(sessionID: UUID) -> Bool {
        guard let client = clients.first(where: { $0.sessions.contains(where: { $0.id == sessionID }) }),
              let record = client.sessions.first(where: { $0.id == sessionID }) else { return false }
        select(client: client, session: record)
        return true
    }

    func start() {
        guard !started else { return }
        started = true
        if connectOnLaunch, !recoveryRequired, let controller = selectedController { Task { await controller.connect() } }
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

    func forkSelectedConversation() async {
        guard let client = selectedClient, let source = selectedController, source.canFork else { return }
        do {
            guard let fork = try await source.forkConversation(),
                  let index = clients.firstIndex(where: { $0.id == client.id }),
                  clients[index].sessions.contains(where: { $0.id == source.id }) else { return }
            clients[index].sessions.insert(fork, at: 0)
            select(client: clients[index], session: fork)
            save()
        } catch {
            self.error = "Could not fork conversation: \(error.localizedDescription)"
        }
    }

    func closeSelectedConversation() {
        guard let client = selectedClient,
              let session = client.sessions.first(where: { $0.id == selectedSessionID }) else { return }
        closeConversation(session, client: client)
    }

    func saveClient(_ client: Client) throws {
        try client.validate()
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            let previous = clients[index]
            let sameHost = previous.isLocal == client.isLocal &&
                (client.isLocal || (previous.host == client.host && previous.port == client.port))
            let reconnectIDs = Set(previous.sessions.compactMap { record -> UUID? in
                guard let status = controllers[record.id]?.status,
                      status == .connected || status == .connecting else { return nil }
                return record.id
            })
            var updated = client
            updated.sessions = previous.sessions.map { existing in
                var record = existing
                guard record.workingDirectory != client.workingDirectory else { return record }
                record.workingDirectory = client.workingDirectory
                // A resumed session takes its cwd from its immutable session header, not
                // the process's initial `cd`. Forking preserves its active branch while
                // creating a new Pi session rooted in the newly configured directory.
                record.forkFromPath = sameHost ? record.sessionPath : nil
                record.sessionPath = nil
                return record
            }
            clients[index] = updated
            for record in updated.sessions { controllers[record.id]?.reconfigure(updated, record: record) }
            selectedClientID = updated.id
            if updated.sessions.contains(where: { $0.id == selectedSessionID }) == false {
                selectedSessionID = updated.sessions.first?.id
            }
            save()
            for id in reconnectIDs {
                if let controller = controllers[id] { Task { await controller.connect() } }
            }
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
        onConversationViewed?(id)
        if let rpc = controllers.removeValue(forKey: id)?.disconnect() {
            retiringConnections.append(rpc)
            Task {
                await rpc.waitForExit()
                retiringConnections.removeAll { $0 === rpc }
            }
        }
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
        guard canPersist, !recoveringWorkspace else { return }
        do {
            let workspace = Workspace(clients: clients, selectedClientID: selectedClientID, selectedSessionID: selectedSessionID, connectOnLaunch: connectOnLaunch)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(workspace).write(to: workspaceURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspaceURL.path)
        } catch { self.error = "Could not save workspace: \(error.localizedDescription)" }
    }

    /// Validate an import before touching the original. Always preserve the original as a backup.
    func recoverWorkspace(from source: URL?) async throws {
        guard !recoveringWorkspace else { return }
        recoveringWorkspace = true
        saveWork?.cancel()
        defer { recoveringWorkspace = false; saveWork?.cancel() }
        let replacement: Workspace
        if let source {
            replacement = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: source))
            guard replacement.version == 1 else { throw DeskError.message("Unsupported workspace version.") }
            var ids = Set<UUID>()
            for client in replacement.clients {
                try client.validate()
                guard ids.insert(client.id).inserted else { throw DeskError.message("Duplicate client ID in workspace.") }
                for session in client.sessions {
                    guard ids.insert(session.id).inserted else { throw DeskError.message("Duplicate session ID in workspace.") }
                }
            }
        } else {
            var local = Client(name: "This Mac")
            local.sessions = [SessionRecord(workingDirectory: local.workingDirectory)]
            replacement = Workspace(clients: [local], selectedClientID: local.id, selectedSessionID: local.sessions.first?.id, connectOnLaunch: false)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(replacement)
        let manager = FileManager.default
        try manager.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: workspaceURL.path) {
            let backup = workspaceURL.appendingPathExtension("backup-" + UUID().uuidString)
            try manager.copyItem(at: workspaceURL, to: backup)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        // Disconnect before swapping profiles, but don't save the broken/current workspace.
        let connections = controllers.values.compactMap { $0.disconnect() } + retiringConnections
        for connection in connections { await connection.waitForExit() }
        try data.write(to: workspaceURL, options: .atomic)
        // Once replaced, always adopt the imported in-memory state, even if chmod fails.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspaceURL.path)
        for client in clients { for session in client.sessions { onConversationViewed?(session.id) } }
        controllers = [:]; observations = [:]; retiringConnections = []
        clients = replacement.clients
        selectedClientID = replacement.selectedClientID
        if selectedClient == nil { selectedClientID = clients.first?.id }
        selectedSessionID = replacement.selectedSessionID
        if selectedClient?.sessions.contains(where: { $0.id == selectedSessionID }) != true { selectedSessionID = selectedClient?.sessions.first?.id }
        connectOnLaunch = replacement.connectOnLaunch
        canPersist = true; recoveryRequired = false; error = nil
        // Import/recovery never auto-connects or submits restored drafts.
    }

    var workspacePath: String { workspaceURL.path }

    func shutdown() async {
        save()
        let connections = controllers.values.compactMap { $0.disconnect() } + retiringConnections
        for connection in connections { await connection.waitForExit() }
    }
}

struct SavedSession: Identifiable, Codable {
    var id: String { path }
    let path: String
    let cwd: String
    let title: String
    let modifiedMS: Double
    var signature: String? = nil
    var modified: Date { Date(timeIntervalSince1970: modifiedMS / 1000) }
}

/// Read-only discovery of mentionable paths in the connected client's project directory.
@MainActor
enum ProjectFileInventory {
    static func list(client: Client, workingDirectory: String) async throws -> [ProjectPath] {
        try Task.checkCancellation()
        try client.validate()
        guard let url = PiResources.bundle.url(forResource: "list-project-files", withExtension: "js") else {
            throw DeskError.message("Project file discovery helper is missing.")
        }
        let script = try String(contentsOf: url, encoding: .utf8)
        let command = "cd " + ProcessInvocation.path(workingDirectory) + " && exec node -e " + ProcessInvocation.quote(script)
        let rpc = RPCConnection()
        try rpc.start(ProcessInvocation.shell(client: client, command: command))
        do {
            let paths = try await withTaskCancellationHandler {
                let result = try await rpc.request("list", timeout: 120)
                try Task.checkCancellation()
                return (result["entries"] as? [JSONObject] ?? []).compactMap(ProjectPath.init)
            } onCancel: {
                Task { @MainActor in rpc.stop() }
            }
            rpc.stop(); await rpc.waitForExit()
            return paths
        } catch {
            rpc.stop(); await rpc.waitForExit()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

/// Read-only discovery. Conversation content is loaded by Pi, not reconstructed from its tree here.
@MainActor
enum SessionInventory {
    private static var cache: [String: [SavedSession]] = [:]

    static func list(client: Client, progress: @escaping (String) -> Void = { _ in }) async throws -> [SavedSession] {
        try Task.checkCancellation()
        try client.validate()
        guard let url = PiResources.bundle.url(forResource: "list-sessions", withExtension: "js") else { throw DeskError.message("Session discovery helper is missing.") }
        let script = try String(contentsOf: url, encoding: .utf8)
        let invocation = ProcessInvocation.shell(client: client, command: "exec node -e " + ProcessInvocation.quote(script))
        let rpc = RPCConnection()
        let key = "\(client.isLocal):\(client.host):\(client.port):\(client.sessionDirectory ?? "")"
        rpc.onEvent = { event in
            guard event["type"] as? String == "inventory_progress" else { return }
            progress("\(event["scanned"] as? Int ?? 0) scanned · \(event["found"] as? Int ?? 0) found · \(event["reused"] as? Int ?? 0) cached · \(event["skipped"] as? Int ?? 0) skipped")
        }
        try rpc.start(invocation)
        do {
            let sessions = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let cached = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache[key] ?? []))
                var fields: JSONObject = ["cached": cached]
                if let directory = client.sessionDirectory { fields["directory"] = directory }
                let result = try await rpc.request("list", fields: fields, timeout: 300)
                try Task.checkCancellation()
                let data = try JSONSerialization.data(withJSONObject: result["sessions"] ?? [])
                return try JSONDecoder().decode([SavedSession].self, from: data).sorted { $0.modified > $1.modified }
            } onCancel: {
                Task { @MainActor in rpc.stop() }
            }
            rpc.stop(); await rpc.waitForExit()
            // Bound the in-memory metadata cache; no session contents are cached here.
            if cache.count >= 8 { cache.removeAll() }
            cache[key] = sessions
            return sessions
        } catch {
            rpc.stop(); await rpc.waitForExit()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
