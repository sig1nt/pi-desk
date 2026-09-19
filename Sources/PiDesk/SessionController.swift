import Foundation
import Combine

@MainActor
final class SessionController: ObservableObject, Identifiable {
    enum Status: String { case disconnected = "Disconnected", connecting = "Connecting…", connected = "Connected", failed = "Connection failed" }
    let id: UUID
    @Published private(set) var client: Client
    @Published var record: SessionRecord { didSet { onRecordChange?(record) } }
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var models: [PiModel] = []
    @Published private(set) var modelID = ""
    @Published private(set) var thinking = "off"
    @Published private(set) var thinkingLevels = ["off"]
    @Published private(set) var isBusy = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isChangingSettings = false
    @Published private(set) var activity = ""
    @Published private(set) var queued: [String] = []
    @Published private(set) var statistics = ""
    @Published private(set) var dialogs: [ExtensionDialog] = []
    @Published private(set) var extensionStatus: [String: String] = [:]
    @Published private(set) var widgets: [String: String] = [:]
    @Published var error: String?
    var onRecordChange: ((SessionRecord) -> Void)?
    private var connection: RPCConnection?
    private var retiringConnection: RPCConnection?
    private var activityRevision = 0
    private var connectAttempt = UUID()
    private var activeMessages: [String: String] = [:]
    private struct Block { var kind: String; var text = ""; var name = "" }
    private var blocks: [Int: Block] = [:]
    private var commandNames: Set<String> = []

    init(client: Client, record: SessionRecord) { self.client = client; self.record = record; id = record.id }
    var canSend: Bool { status == .connected && !isSubmitting && !isChangingSettings && !record.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canConfigure: Bool { status == .connected && !isBusy && !isSubmitting && !isChangingSettings }
    var statusText: String { isBusy ? (activity.isEmpty ? "Working…" : activity) : status.rawValue }

    func connect() async {
        guard status != .connecting, status != .connected else { return }
        error = nil
        status = .connecting
        let attempt = UUID()
        connectAttempt = attempt
        if let retiring = retiringConnection {
            await retiring.waitForExit()
            guard status == .connecting, connectAttempt == attempt else { return }
            retiringConnection = nil
        }
        let rpc = RPCConnection()
        connection = rpc
        rpc.onEvent = { [weak self, weak rpc] event in
            guard let self, self.connection === rpc else { return }
            self.handle(event)
        }
        rpc.onDisconnect = { [weak self, weak rpc] message in
            guard let self, self.connection === rpc else { return }
            self.status = message == nil ? .disconnected : .failed
            self.error = message
            self.retiringConnection = rpc
            self.resetActivity()
        }
        do {
            try rpc.start(ProcessInvocation.rpc(client: client, session: record))
            try await refreshState(rpc)
            let available = try await rpc.request("get_available_models")
            guard connection === rpc else { return }
            models = (available["models"] as? [JSONObject] ?? []).compactMap(PiModel.init)
            try await refreshThinking(rpc)
            let history = try await rpc.request("get_messages")
            guard connection === rpc else { return }
            messages = (history["messages"] as? [JSONObject] ?? []).compactMap(ChatMessage.parse)
            if let commands = try? await rpc.request("get_commands") {
                commandNames = Set((commands["commands"] as? [JSONObject] ?? []).compactMap { $0["name"] as? String })
            }
            guard connection === rpc, rpc.isRunning else { return }
            status = .connected
            await refreshStats(rpc)
        } catch {
            guard connection === rpc else { return }
            rpc.stop()
            retiringConnection = rpc
            status = .failed
            self.error = error.localizedDescription
            resetActivity()
        }
    }

    @discardableResult
    func disconnect() -> RPCConnection? {
        connectAttempt = UUID()
        let rpc = connection
        connection = nil
        rpc?.onEvent = nil; rpc?.onDisconnect = nil
        rpc?.stop()
        if let rpc { retiringConnection = rpc }
        status = .disconnected
        resetActivity()
        return rpc ?? retiringConnection
    }

    func reconfigure(_ client: Client, record: SessionRecord) {
        disconnect()
        self.client = client
        self.record = record
    }

    private func resetActivity() {
        isBusy = false; isSubmitting = false; isChangingSettings = false
        activity = ""; dialogs = []; queued = []; activeMessages = [:]; blocks = [:]
        for index in messages.indices { messages[index].isRunning = false }
    }

    private func refreshState(_ rpc: RPCConnection) async throws {
        let revision = activityRevision
        let state = try await rpc.request("get_state", timeout: 45)
        guard connection === rpc else { return }
        if let model = state["model"] as? JSONObject, let parsed = PiModel(model) { modelID = parsed.id }
        else { modelID = "" }
        thinking = state["thinkingLevel"] as? String ?? "off"
        if revision == activityRevision {
            isBusy = state["isStreaming"] as? Bool == true || state["isCompacting"] as? Bool == true
        }
        if let file = state["sessionFile"] as? String {
            record.sessionPath = file
            record.forkFromPath = nil
        }
        if let name = state["sessionName"] as? String, !name.isEmpty { record.title = name }
    }

    private func refreshThinking(_ rpc: RPCConnection) async throws {
        let result = try await rpc.request("get_available_thinking_levels")
        guard connection === rpc else { return }
        thinkingLevels = result["levels"] as? [String] ?? ["off"]
    }

    private func refreshStats(_ rpc: RPCConnection) async {
        guard let result = try? await rpc.request("get_session_stats"), connection === rpc else { return }
        let tokens = (result["tokens"] as? JSONObject)?["total"] as? Int ?? 0
        let cost = result["cost"] as? Double ?? 0
        statistics = "\(tokens.formatted()) tokens · " + String(format: "$%.4f", cost)
        if let usage = result["contextUsage"] as? JSONObject, let percent = usage["percent"] as? Double {
            statistics += String(format: " · %.0f%% context", percent)
        }
    }

    func send() async {
        guard canSend, let rpc = connection else { return }
        let text = record.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Built-in TUI commands are not RPC prompts. Avoid accidentally sending them to the model.
        if text.hasPrefix("/"), let first = text.split(whereSeparator: { $0.isWhitespace }).first {
            let command = String(first.dropFirst())
            if command == "compact" { record.draft = ""; await compact(); return }
            if command == "name" {
                let name = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { await rename(name); if error == nil { record.draft = "" } }
                return
            }
            let builtins: Set<String> = ["new", "resume", "settings", "model", "thinking", "login", "logout", "tree", "fork", "clone", "export", "import", "quit", "session", "hotkeys", "copy", "reload", "trust", "share", "scoped-models"]
            if builtins.contains(command), !commandNames.contains(command) {
                error = "/\(command) is a terminal UI command. Use PiDesk's menus and selectors instead. For authentication, run pi /login in a terminal on this client."
                return
            }
        }
        error = nil
        isSubmitting = true
        record.draft = ""
        defer { if connection === rpc { isSubmitting = false } }
        do {
            _ = try await rpc.request("prompt", fields: ["message": text, "streamingBehavior": "steer"], timeout: 600)
            guard connection === rpc else { return }
            record.updatedAt = Date()
            try await refreshState(rpc)
        } catch {
            guard connection === rpc else { return }
            self.error = error.localizedDescription
            record.draft = text + (record.draft.isEmpty ? "" : "\n\n" + record.draft)
        }
    }

    func stop() async {
        guard let rpc = connection else { return }
        do {
            // Abort alone can continue queued messages, so clear and restore them first.
            let queue = try await rpc.request("clear_queue")
            guard connection === rpc else { return }
            let restored = (queue["steering"] as? [String] ?? []) + (queue["followUp"] as? [String] ?? [])
            if !restored.isEmpty { record.draft += (record.draft.isEmpty ? "" : "\n\n") + restored.joined(separator: "\n\n") }
            _ = try await rpc.request("abort", timeout: 60)
            try await refreshState(rpc)
        } catch { if connection === rpc { self.error = error.localizedDescription } }
    }

    func setModel(_ id: String) async {
        guard canConfigure, let rpc = connection, let model = models.first(where: { $0.id == id }) else { return }
        await configure(rpc) {
            _ = try await rpc.request("set_model", fields: ["provider": model.provider, "modelId": model.modelID])
            try await self.refreshState(rpc)
            try await self.refreshThinking(rpc)
        }
    }

    func setThinking(_ level: String) async {
        guard canConfigure, let rpc = connection, thinkingLevels.contains(level) else { return }
        await configure(rpc) {
            _ = try await rpc.request("set_thinking_level", fields: ["level": level])
            try await self.refreshState(rpc)
        }
    }

    private func configure(_ rpc: RPCConnection, operation: () async throws -> Void) async {
        isChangingSettings = true; error = nil
        defer { if connection === rpc { isChangingSettings = false } }
        do { try await operation() }
        catch { if connection === rpc { self.error = error.localizedDescription } }
    }

    func rename(_ name: String) async {
        guard canConfigure, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = nil
        if let rpc = connection, status == .connected {
            do { _ = try await rpc.request("set_session_name", fields: ["name": name]) }
            catch { if connection === rpc { self.error = error.localizedDescription }; return }
            guard connection === rpc else { return }
        }
        record.title = name
    }

    func compact() async {
        guard canConfigure, let rpc = connection else { return }
        await configure(rpc) {
            _ = try await rpc.request("compact", timeout: 600)
            let result = try await rpc.request("get_messages")
            guard self.connection === rpc else { return }
            self.messages = (result["messages"] as? [JSONObject] ?? []).compactMap(ChatMessage.parse)
            try await self.refreshState(rpc)
            await self.refreshStats(rpc)
        }
    }

    func respond(to dialog: ExtensionDialog, value: String? = nil, confirmed: Bool? = nil) {
        guard dialogs.contains(where: { $0.id == dialog.id }), let rpc = connection else { return }
        var response: JSONObject = ["type": "extension_ui_response", "id": dialog.id]
        if let value { response["value"] = value }
        else if let confirmed { response["confirmed"] = confirmed }
        else { response["cancelled"] = true }
        do { try rpc.send(response) } catch { self.error = error.localizedDescription }
        dialogs.removeAll { $0.id == dialog.id }
    }

    private func upsert(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            var replacement = message
            if replacement.arguments.isEmpty { replacement.arguments = messages[index].arguments }
            messages[index] = replacement
        } else { messages.append(message) }
    }

    private func handle(_ event: JSONObject) {
        if ["agent_start", "agent_settled", "compaction_start", "compaction_end", "auto_retry_start"].contains(event["type"] as? String ?? "") {
            activityRevision += 1
        }
        switch event["type"] as? String {
        case "agent_start": isBusy = true; activity = "Working…"
        case "agent_settled":
            isBusy = false; activity = ""
            record.updatedAt = Date()
            if let rpc = connection { Task { try? await refreshState(rpc); await refreshStats(rpc) } }
        case "message_start", "message_end":
            guard let raw = event["message"] as? JSONObject, var message = ChatMessage.parse(raw) else { return }
            let starting = event["type"] as? String == "message_start"
            if message.role != "toolResult" {
                if starting { activeMessages[message.role] = message.id }
                else if let id = activeMessages.removeValue(forKey: message.role) { message.id = id }
            }
            message.isRunning = starting && message.role == "assistant"
            if starting && message.role == "assistant" { blocks = [:] }
            if starting && message.isUser && record.title == "New conversation" {
                record.title = String(message.body.prefix(64)).replacingOccurrences(of: "\n", with: " ")
            }
            upsert(message)
        case "message_update": updateStream(event)
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            guard let callID = event["toolCallId"] as? String else { return }
            let id = "tool-" + callID
            var message = messages.first { $0.id == id } ?? ChatMessage(id: id, role: "toolResult")
            message.toolName = event["toolName"] as? String ?? message.toolName
            if let args = event["args"] { message.arguments = prettyJSON(args) }
            let result = event["result"] as? JSONObject ?? event["partialResult"] as? JSONObject
            if let result { message.body = textContent(result["content"]) }
            message.isRunning = event["type"] as? String != "tool_execution_end"
            message.isError = event["isError"] as? Bool == true
            activity = message.isRunning ? "Running \(message.toolName ?? "tool")…" : "Working…"
            upsert(message)
        case "queue_update": queued = (event["steering"] as? [String] ?? []) + (event["followUp"] as? [String] ?? [])
        case "compaction_start": isBusy = true; activity = "Compacting context…"
        case "compaction_end":
            if let message = event["errorMessage"] as? String { error = message }
            if let rpc = connection { Task { try? await refreshState(rpc) } }
        case "auto_retry_start", "summarization_retry_scheduled":
            isBusy = true; activity = "Retrying (\(event["attempt"] as? Int ?? 1))…"
        case "auto_retry_end": if let failure = event["finalError"] as? String { error = failure }
        case "extension_error": error = event["error"] as? String ?? "Extension failed."
        case "extension_ui_request": handleExtension(event)
        default: break
        }
    }

    private func updateStream(_ event: JSONObject) {
        guard let id = activeMessages["assistant"], let index = messages.firstIndex(where: { $0.id == id }),
              let delta = event["assistantMessageEvent"] as? JSONObject,
              let type = delta["type"] as? String else { return }
        let contentIndex = delta["contentIndex"] as? Int ?? 0
        let kind = type.hasPrefix("thinking") ? "thinking" : type.hasPrefix("toolcall") ? "tool" : "text"
        var block = blocks[contentIndex] ?? Block(kind: kind)
        if type.hasSuffix("_delta") { block.text += delta["delta"] as? String ?? "" }
        if type.hasSuffix("_end"), let content = delta["content"] as? String { block.text = content }
        if let name = delta["toolName"] as? String { block.name = name }
        if let call = delta["toolCall"] as? JSONObject { block.name = call["name"] as? String ?? "tool"; block.text = prettyJSON(call["arguments"]) }
        blocks[contentIndex] = block
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        messages[index].body = ordered.filter { $0.kind == "text" }.map(\.text).joined(separator: "\n\n")
        messages[index].thinking = ordered.filter { $0.kind == "thinking" }.map(\.text).joined(separator: "\n\n")
        messages[index].arguments = ordered.filter { $0.kind == "tool" }.map { $0.name + "\n" + $0.text }.joined(separator: "\n\n")
    }

    private func handleExtension(_ event: JSONObject) {
        guard let method = event["method"] as? String, let id = event["id"] as? String else { return }
        switch method {
        case "select", "confirm", "input", "editor":
            dialogs.append(ExtensionDialog(id: id, method: method, title: event["title"] as? String ?? "Pi needs your input", message: event["message"] as? String ?? "", options: event["options"] as? [String] ?? [], prefill: event["prefill"] as? String ?? "", placeholder: event["placeholder"] as? String ?? ""))
            if let timeout = event["timeout"] as? Double {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout / 1000) { [weak self] in self?.dialogs.removeAll { $0.id == id } }
            }
        case "set_editor_text": record.draft = event["text"] as? String ?? ""
        case "notify":
            messages.append(ChatMessage(role: "notification", body: event["message"] as? String ?? "", isError: event["notifyType"] as? String == "error"))
        case "setStatus": if let key = event["statusKey"] as? String { extensionStatus[key] = event["statusText"] as? String }
        case "setWidget": if let key = event["widgetKey"] as? String { widgets[key] = (event["widgetLines"] as? [String])?.joined(separator: "\n") }
        default: break
        }
    }
}
