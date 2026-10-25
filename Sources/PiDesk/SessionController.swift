import Foundation
import Combine
import AppKit

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
    @Published private(set) var isForking = false
    @Published private(set) var activity = ""
    @Published private(set) var queued: [String] = []
    @Published private(set) var statistics = ""
    @Published private(set) var dialogs: [ExtensionDialog] = []
    @Published private(set) var extensionStatus: [String: String] = [:]
    @Published private(set) var widgets: [String: String] = [:]
    @Published private(set) var pendingImages: [PendingImage] = []
    @Published private(set) var commands: [PiCommand] = []
    @Published private(set) var projectPaths: [ProjectPath] = []
    @Published var error: String?
    var onRecordChange: ((SessionRecord) -> Void)?
    var onTurnFinished: (() -> Void)?
    private var hasActiveTurn = false
    private var connection: RPCConnection?
    private var retiringConnection: RPCConnection?
    private var activityRevision = 0
    private var connectAttempt = UUID()
    private var activeMessages: [String: String] = [:]
    private struct Block { var kind: String; var text = ""; var name = "" }
    private var blocks: [Int: Block] = [:]
    private var commandNames: Set<String> = []
    private var fileDiscoveryTask: Task<Void, Never>?
    private struct Submission { let text: String; let images: [PendingImage] }
    private var pendingSubmission: Submission?
    private var unknownDeliveryImageIDs: Set<UUID> = []

    init(client: Client, record: SessionRecord) { self.client = client; self.record = record; id = record.id }
    var canSend: Bool { status == .connected && record.deliveryUnknown == nil && !isSubmitting && !isChangingSettings && (!record.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty) }
    var canFork: Bool { canConfigure && !isForking && record.deliveryUnknown == nil && record.sessionPath != nil && !messages.isEmpty }
    var canConfigure: Bool { status == .connected && !isBusy && !isSubmitting && !isChangingSettings }
    var statusText: String { isBusy ? (activity.isEmpty ? "Working…" : activity) : status.rawValue }
    var composerSuggestions: [ComposerSuggestion] {
        guard status == .connected else { return [] }
        return ComposerCompletion.suggestions(text: record.draft, commands: commands, paths: projectPaths)
    }

    func applyComposerSuggestion(_ suggestion: ComposerSuggestion) {
        record.draft = ComposerCompletion.applying(suggestion, to: record.draft)
    }

    func connect() async {
        guard status != .connecting, status != .connected else { return }
        error = nil
        fileDiscoveryTask?.cancel(); fileDiscoveryTask = nil
        clearExtensionState()
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
            let availableModels = (available["models"] as? [JSONObject] ?? []).compactMap(PiModel.init)
            models = await discoverScopedModels(availableCount: availableModels.count)
            guard connection === rpc else { return }
            try await refreshThinking(rpc)
            let history = try await rpc.request("get_messages")
            guard connection === rpc else { return }
            messages = parseConversationMessages(history["messages"] as? [JSONObject] ?? [])
            if let response = try? await rpc.request("get_commands") {
                let available = (response["commands"] as? [JSONObject] ?? []).compactMap(PiCommand.init)
                commands = Self.composerCommands(available)
                commandNames = Set(available.map(\.name))
            } else {
                commands = Self.composerCommands([])
            }
            guard connection === rpc, rpc.isRunning else { return }
            status = .connected
            discoverProjectFiles(for: attempt)
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
        fileDiscoveryTask?.cancel(); fileDiscoveryTask = nil
        if let submission = pendingSubmission {
            record.deliveryUnknown = submission.text
            restoreImages(submission.images, deliveryUnknown: true)
        }
        pendingSubmission = nil
        let rpc = connection
        connection = nil
        rpc?.onEvent = nil; rpc?.onDisconnect = nil
        rpc?.stop()
        if let rpc { retiringConnection = rpc }
        status = .disconnected
        resetActivity()
        return rpc ?? retiringConnection
    }

    /// `clone` preserves the current leaf; `fork` instead rewinds to a user message.
    func forkConversation() async throws -> SessionRecord? {
        guard canFork, let rpc = connection else { return nil }
        let original = record
        isForking = true
        isChangingSettings = true
        defer {
            isForking = false
            if connection === rpc { isChangingSettings = false }
        }
        do {
            let result = try await rpc.request("clone", timeout: 600)
            guard connection === rpc else { return nil }
            guard result["cancelled"] as? Bool != true else { return nil }
            let state = try await rpc.request("get_state")
            guard connection === rpc else { return nil }
            guard let path = state["sessionFile"] as? String, !path.isEmpty, path != original.sessionPath else {
                throw DeskError.message("Pi did not return a new session path after cloning.")
            }
            let fork = SessionRecord(title: state["sessionName"] as? String ?? original.title,
                                     workingDirectory: original.workingDirectory, sessionPath: path)
            // Clone switches the running process to the new file. Retire it and
            // release both host-side locks before opening the new conversation.
            disconnect()
            await rpc.waitForExit()
            return fork
        } catch {
            // A failed/unknown response may still have switched Pi's session.
            // Never allow subsequent prompts to silently modify the wrong file.
            if connection === rpc { disconnect() }
            await rpc.waitForExit()
            throw error
        }
    }

    func reconfigure(_ client: Client, record: SessionRecord) {
        disconnect()
        self.client = client
        self.record = record
    }

    private func resetActivity() {
        hasActiveTurn = false
        isBusy = false; isSubmitting = false; isChangingSettings = false
        activity = ""; queued = []; activeMessages = [:]; blocks = [:]
        clearExtensionState()
        for index in messages.indices { messages[index].isRunning = false }
    }

    private func clearExtensionState() {
        dialogs = []; widgets = [:]; extensionStatus = [:]; commandNames = []; commands = []; projectPaths = []
    }

    private static func composerCommands(_ available: [PiCommand]) -> [PiCommand] {
        var result = available
        let local = [
            PiCommand(name: "compact", description: "Compact conversation context", source: "PiDesk", argumentHint: "[instructions]"),
            PiCommand(name: "name", description: "Set the conversation name", source: "PiDesk", argumentHint: "<name>")
        ]
        for command in local where !result.contains(where: { $0.name == command.name }) { result.append(command) }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func discoverProjectFiles(for attempt: UUID) {
        let client = client, workingDirectory = record.workingDirectory
        fileDiscoveryTask?.cancel()
        fileDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let paths = try await ProjectFileInventory.list(client: client, workingDirectory: workingDirectory)
                guard self.connectAttempt == attempt, self.status == .connected else { return }
                self.projectPaths = paths
            } catch is CancellationError {
                return
            } catch {
                // Mention discovery is optional; a failure must not take down a healthy Pi session.
            }
        }
    }

    func resolveUnknownDelivery(restoreDraft: Bool) {
        guard let text = record.deliveryUnknown else { return }
        if restoreDraft, !text.isEmpty {
            record.draft = text + (record.draft.isEmpty ? "" : "\n\n" + record.draft)
        } else if !restoreDraft {
            pendingImages.removeAll { unknownDeliveryImageIDs.contains($0.id) }
        }
        unknownDeliveryImageIDs = []
        record.deliveryUnknown = nil
    }

    func pasteImagesFromClipboard() {
        error = nil
        let objects = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        guard !objects.isEmpty else {
            error = "The clipboard does not contain an image."
            return
        }
        var added = 0
        for image in objects {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            if attachImage(data: png, mimeType: "image/png", name: "Pasted image \(pendingImages.count + 1)") { added += 1 }
        }
        if added == 0, error == nil { error = "The clipboard image could not be decoded." }
    }

    @discardableResult
    func attachImage(data: Data, mimeType: String, name: String) -> Bool {
        guard pendingImages.count < 8 else {
            error = "You can attach up to 8 images to one message."
            return false
        }
        guard data.count <= 20 * 1024 * 1024,
              pendingImages.reduce(0, { $0 + $1.data.count }) + data.count <= 40 * 1024 * 1024 else {
            error = "Pasted images are limited to 20 MB each and 40 MB total."
            return false
        }
        pendingImages.append(PendingImage(data: data, mimeType: mimeType, name: name))
        return true
    }

    func removePendingImage(_ id: UUID) { pendingImages.removeAll { $0.id == id } }

    private func restoreImages(_ images: [PendingImage], deliveryUnknown: Bool = false) {
        let existing = Set(pendingImages.map(\.id))
        let restored = images.filter { !existing.contains($0.id) }
        pendingImages = restored + pendingImages
        if deliveryUnknown { unknownDeliveryImageIDs.formUnion(images.map(\.id)) }
    }

    /// Complete append-only Pi history, including abandoned branches and raw content blocks.
    func exportHistory() async throws -> Data {
        guard let rpc = connection, status == .connected else { throw DeskError.message("Connect before exporting full Pi history.") }
        let result = try await rpc.request("get_entries", timeout: 60)
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    func exportMarkdown() async throws -> String {
        let transcript: [ChatMessage]
        if let rpc = connection, status == .connected {
            let result = try await rpc.request("get_messages", timeout: 60)
            transcript = parseConversationMessages(result["messages"] as? [JSONObject] ?? [])
        } else { transcript = messages }
        return "# " + record.title + "\n\nActive conversation only. Use Export full Pi history for all branches and raw entries.\n\n" + transcript.map { message in
            var sections = ["## " + (message.isUser ? "You" : message.toolName ?? "Pi"), message.toolName == nil ? message.body : Self.fenced(message.body)]
            if !message.thinking.isEmpty { sections.append("### Thinking\n\n" + message.thinking) }
            if !message.arguments.isEmpty { sections.append("### Tool arguments\n\n" + Self.fenced(message.arguments)) }
            for image in message.images {
                sections.append("![Image](data:\(image.mimeType);base64,\(image.data.base64EncodedString()))")
            }
            return sections.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    private static func fenced(_ text: String) -> String {
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        return fence + "\n" + text + "\n" + fence
    }

    private func refreshState(_ rpc: RPCConnection) async throws {
        let revision = activityRevision
        let state = try await rpc.request("get_state", timeout: 45)
        guard connection === rpc, !isForking else { return }
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

    /// RPC exposes scoped cycling but not the scoped list. Probe an ephemeral,
    /// no-session Pi process so enumeration follows Pi's exact pattern resolution
    /// without appending model-change entries to the user's conversation.
    private func discoverScopedModels(availableCount: Int) async -> [PiModel] {
        guard availableCount > 0 else { return [] }
        let probe = RPCConnection()
        do {
            try probe.start(ProcessInvocation.scopedModelProbe(client: client, workingDirectory: record.workingDirectory))
            let state = try await probe.request("get_state", timeout: 45)
            guard let rawInitial = state["model"] as? JSONObject, let initial = PiModel(rawInitial) else {
                probe.stop(); await probe.waitForExit(); return []
            }
            if availableCount == 1 {
                probe.stop(); await probe.waitForExit(); return [initial]
            }
            var scoped = [initial]
            for _ in 0...availableCount {
                let result = try await probe.request("cycle_model", timeout: 45)
                guard let rawModel = result["model"] as? JSONObject, let next = PiModel(rawModel) else {
                    // With multiple available models, no cycle result means a one-model scope.
                    probe.stop(); await probe.waitForExit(); return [initial]
                }
                guard result["isScoped"] as? Bool == true else {
                    probe.stop(); await probe.waitForExit(); return []
                }
                if next.id == initial.id { break }
                if !scoped.contains(where: { $0.id == next.id }) { scoped.append(next) }
            }
            probe.stop(); await probe.waitForExit()
            return scoped
        } catch {
            probe.stop(); await probe.waitForExit()
            return []
        }
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
            if command == "compact" {
                let instructions = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
                record.draft = ""; await compact(customInstructions: instructions.isEmpty ? nil : instructions); return
            }
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
        let submission = Submission(text: text, images: pendingImages)
        record.draft = ""
        pendingImages = []
        pendingSubmission = submission
        defer { if connection === rpc { isSubmitting = false; pendingSubmission = nil } }
        let rpcImages: [JSONObject] = submission.images.map {
            ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mimeType]
        }
        do {
            let result = try await rpc.request("prompt", fields: ["message": text, "images": rpcImages, "streamingBehavior": "steer"], timeout: 600)
            // Pi 1.1 reports whether input started a run, was queued, or was handled
            // synchronously by an extension. Events, rather than this response, remain
            // authoritative for busy state and completion.
            if let disposition = result["disposition"] as? String,
               !["started", "queued", "handled"].contains(disposition) {
                // The prompt was already accepted, so report a protocol warning without
                // restoring it to the draft and risking a duplicate submission.
                self.error = "Pi returned an unknown prompt disposition: \(disposition)"
            }
        } catch {
            guard connection === rpc else { return }
            self.error = error.localizedDescription
            if case DeskError.deliveryUnknown = error {
                restoreImages(submission.images, deliveryUnknown: true)
                record.deliveryUnknown = text
            } else {
                restoreImages(submission.images)
                if !text.isEmpty { record.draft = text + (record.draft.isEmpty ? "" : "\n\n" + record.draft) }
            }
            return
        }
        guard connection === rpc else { return }
        pendingSubmission = nil
        record.updatedAt = Date()
        // Once accepted, a failed state query must never restore the sent prompt.
        do { try await refreshState(rpc) }
        catch { if connection === rpc { self.error = error.localizedDescription } }
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

    func compact(customInstructions: String? = nil) async {
        guard canConfigure, let rpc = connection else { return }
        await configure(rpc) {
            var fields: JSONObject = [:]
            if let customInstructions { fields["customInstructions"] = customInstructions }
            _ = try await rpc.request("compact", fields: fields, timeout: 600)
            let result = try await rpc.request("get_messages")
            guard self.connection === rpc else { return }
            self.messages = parseConversationMessages(result["messages"] as? [JSONObject] ?? [])
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
            if replacement.durationMS == nil { replacement.durationMS = messages[index].durationMS }
            messages[index] = replacement
        } else { messages.append(message) }
    }

    private func handle(_ event: JSONObject) {
        if ["agent_start", "agent_settled", "compaction_start", "compaction_end", "auto_retry_start"].contains(event["type"] as? String ?? "") {
            activityRevision += 1
        }
        switch event["type"] as? String {
        case "agent_start":
            hasActiveTurn = true
            isBusy = true; activity = "Working…"
        case "agent_settled":
            // Only final settlement completes a turn, not tool steps, retries,
            // compaction, prompt acknowledgements, or a disconnected transport.
            let finished = hasActiveTurn && event["aborted"] as? Bool != true
            hasActiveTurn = false
            isBusy = false; activity = ""
            if event["aborted"] as? Bool == true {
                activeMessages = [:]; blocks = [:]
                for index in messages.indices { messages[index].isRunning = false }
            }
            record.updatedAt = Date()
            if finished { onTurnFinished?() }
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
            if !starting, message.role == "assistant", message.body.isEmpty, message.thinking.isEmpty, message.images.isEmpty {
                messages.removeAll { $0.id == message.id }
                return
            }
            if starting && message.isUser && record.title == "New conversation" {
                let title = String(message.body.prefix(64)).replacingOccurrences(of: "\n", with: " ")
                record.title = title.isEmpty && !message.images.isEmpty ? "Image conversation" : title
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
            if let duration = event["durationMs"] as? NSNumber { message.durationMS = duration.doubleValue }
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
                let attempt = connectAttempt
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout / 1000) { [weak self] in
                    guard let self, self.connectAttempt == attempt else { return }
                    self.dialogs.removeAll { $0.id == id }
                }
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
