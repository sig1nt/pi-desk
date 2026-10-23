import Foundation

struct Client: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host = ""
    var isLocal = true
    var port = 22
    var workingDirectory = "~"
    var executable = "pi"
    /// Optional host-side discovery root, including per-invocation --session-dir locations.
    var sessionDirectory: String?
    var sessions: [SessionRecord] = []

    var address: String { isLocal ? "Local" : host + (port == 22 ? "" : ":\(port)") }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeskError.message("Enter a display name.")
        }
        for value in [name, host, workingDirectory, executable, sessionDirectory ?? ""] {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw DeskError.message("Connection fields cannot contain control characters.")
            }
        }
        guard workingDirectory == "~" || workingDirectory.hasPrefix("~/") || workingDirectory.hasPrefix("/") else {
            throw DeskError.message("Use an absolute working directory or a path beginning with ~/.")
        }
        if let directory = sessionDirectory, !directory.isEmpty {
            guard directory == "~" || directory.hasPrefix("~/") || directory.hasPrefix("/") else {
                throw DeskError.message("Use an absolute session directory or a path beginning with ~/.")
            }
        }
        guard !executable.isEmpty, !executable.hasPrefix("-") else {
            throw DeskError.message("Enter a Pi executable name or full path, not command-line options.")
        }
        if !isLocal {
            // A destination is one SSH argument, never an option or a shell fragment.
            let pattern = #"^(?:[A-Za-z0-9_.-]+@)?(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|\[[A-Fa-f0-9:]+\])$"#
            guard !host.hasPrefix("-"), host.range(of: pattern, options: .regularExpression) != nil, (1...65535).contains(port) else {
                throw DeskError.message("Use an SSH alias or user@hostname, with a port from 1 to 65535. IPv6 addresses must be in brackets.")
            }
        }
    }
}

struct SessionRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "New conversation"
    var workingDirectory: String
    var sessionPath: String?
    /// When moving a conversation to another directory, Pi forks the old active branch
    /// into a new session whose header and runtime both use the new directory.
    var forkFromPath: String?
    var updatedAt = Date()
    var draft = ""
    /// Persist ambiguity across reconnect/relaunch; never silently resend this text.
    var deliveryUnknown: String?

    var time: String {
        let interval = Date().timeIntervalSince(updatedAt)
        if interval < 60 { return "Now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if Calendar.current.isDateInToday(updatedAt) { return updatedAt.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(updatedAt) { return "Yesterday" }
        return updatedAt.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct Workspace: Codable {
    var version = 1
    var clients: [Client]
    var selectedClientID: UUID?
    var selectedSessionID: UUID?
    var connectOnLaunch = true
}

struct PiModel: Identifiable, Equatable {
    let provider: String
    let modelID: String
    let name: String
    var id: String { provider + "/" + modelID }
    init?(_ json: JSONObject) {
        guard let provider = json["provider"] as? String, let id = json["id"] as? String else { return nil }
        self.provider = provider
        modelID = id
        name = json["name"] as? String ?? id
    }
}

struct PiCommand: Identifiable, Equatable {
    let name: String
    let description: String
    let source: String
    let argumentHint: String
    var id: String { name }

    init?(json: JSONObject) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        description = json["description"] as? String ?? ""
        source = json["source"] as? String ?? "command"
        argumentHint = json["argumentHint"] as? String ?? json["argument-hint"] as? String ?? ""
    }

    init(name: String, description: String, source: String, argumentHint: String = "") {
        self.name = name; self.description = description; self.source = source; self.argumentHint = argumentHint
    }
}

struct ProjectPath: Identifiable, Equatable {
    let path: String
    let isDirectory: Bool
    var id: String { path }

    init?(json: JSONObject) {
        guard let path = json["path"] as? String, !path.isEmpty else { return nil }
        self.path = path
        isDirectory = json["isDirectory"] as? Bool == true
    }

    init(path: String, isDirectory: Bool) { self.path = path; self.isDirectory = isDirectory }
}

struct ComposerSuggestion: Identifiable, Equatable {
    enum Kind: String { case command, path }
    let kind: Kind
    let value: String
    let title: String
    let detail: String
    let isDirectory: Bool
    var id: String { kind.rawValue + ":" + value }
}

enum ComposerCompletion {
    static func suggestions(text: String, commands: [PiCommand], paths: [ProjectPath], limit: Int = 8) -> [ComposerSuggestion] {
        if text.hasPrefix("/"), !text.dropFirst().contains(where: { $0.isWhitespace }) {
            let query = String(text.dropFirst()).lowercased()
            return commands
                .filter { fuzzyScore($0.name, query: query) != nil }
                .sorted {
                    let left = fuzzyScore($0.name, query: query) ?? 0, right = fuzzyScore($1.name, query: query) ?? 0
                    return left == right ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : left > right
                }
                .prefix(limit).map {
                    let description = [$0.argumentHint, $0.description].filter { !$0.isEmpty }.joined(separator: $0.argumentHint.isEmpty || $0.description.isEmpty ? "" : " — ")
                    return ComposerSuggestion(kind: .command, value: $0.name, title: "/" + $0.name, detail: description.isEmpty ? $0.source : description, isDirectory: false)
                }
        }
        guard let range = mentionRange(in: text) else { return [] }
        var query = String(text[range].dropFirst())
        if query.hasPrefix("\"") { query.removeFirst() }
        let lowered = query.lowercased()
        return paths
            .filter { fuzzyScore($0.path, query: lowered) != nil }
            .sorted {
                let left = fuzzyScore($0.path, query: lowered) ?? 0, right = fuzzyScore($1.path, query: lowered) ?? 0
                if left != right { return left > right }
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
            .prefix(limit).map {
                ComposerSuggestion(kind: .path, value: $0.path, title: "@" + $0.path + ($0.isDirectory ? "/" : ""), detail: $0.isDirectory ? "Folder" : "Project file", isDirectory: $0.isDirectory)
            }
    }

    static func applying(_ suggestion: ComposerSuggestion, to text: String) -> String {
        switch suggestion.kind {
        case .command:
            guard text.hasPrefix("/"), !text.dropFirst().contains(where: { $0.isWhitespace }) else { return text }
            return "/" + suggestion.value + " "
        case .path:
            guard let range = mentionRange(in: text) else { return text }
            let escaped = suggestion.value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let reference = escaped.contains(where: { $0.isWhitespace }) ? "@\"\(escaped)\"" : "@" + escaped
            return text.replacingCharacters(in: range, with: reference + " ")
        }
    }

    private static func mentionRange(in text: String) -> Range<String.Index>? {
        if let quoted = text.range(of: "@\"", options: .backwards),
           (quoted.lowerBound == text.startIndex || text[text.index(before: quoted.lowerBound)].isWhitespace),
           !text[quoted.upperBound...].contains("\"") {
            return quoted.lowerBound..<text.endIndex
        }
        let start = text.lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) } ?? text.startIndex
        guard start < text.endIndex, text[start] == "@" else { return nil }
        return start..<text.endIndex
    }

    private static func fuzzyScore(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 1 }
        let value = candidate.lowercased()
        let name = value.split(separator: "/").last.map(String.init) ?? value
        if name == query { return 100 }
        if name.hasPrefix(query) { return 80 }
        if name.contains(query) { return 60 }
        if value.contains(query) { return 40 }
        var position = value.startIndex
        for character in query {
            guard let match = value[position...].firstIndex(of: character) else { return nil }
            position = value.index(after: match)
        }
        return 20
    }
}

struct ChatMessage: Identifiable {
    var id = UUID().uuidString
    var role: String
    var body = ""
    var thinking = ""
    var toolName: String?
    var arguments = ""
    var isError = false
    var isRunning = false
    /// Pi 1.1 records monotonic tool execution time on live completion events.
    var durationMS: Double?
    var timestamp = Date()
    var images: [MessageImage] = []
    var isUser: Bool { role == "user" }
    var time: String { timestamp.formatted(date: .omitted, time: .shortened) }
    var toolStatus: String {
        if isRunning { return "Running…" }
        let status = isError ? "Failed" : "Done"
        guard let durationMS else { return status }
        let duration = durationMS / 1000
        return duration < 10 ? status + String(format: " · %.1fs", duration) : status + String(format: " · %.0fs", duration)
    }
    var toolDisplayName: String {
        let name = toolName ?? "Tool"
        let object: JSONObject? = arguments.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? JSONObject
        }
        if name == "bash" {
            if let command = object?["command"] as? String, !command.isEmpty { return command }
            let command = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? "bash" : command
        }
        if ["read", "write", "edit"].contains(name),
           let path = object?["path"] as? String, !path.isEmpty {
            return "\(name) · \(path)"
        }
        return name
    }

    static func parse(_ json: JSONObject) -> ChatMessage? {
        let role = json["role"] as? String ?? "custom"
        // System entries carry model instructions, not visible conversation content.
        // Filter here for both restored history and live message events.
        if role == "system" { return nil }
        if role == "custom", json["display"] as? Bool == false { return nil }
        var message = ChatMessage(role: role)
        if let stamp = json["timestamp"] as? Double { message.timestamp = Date(timeIntervalSince1970: stamp / 1000) }
        message.body = textContent(json["content"])
        if let blocks = json["content"] as? [JSONObject] {
            var visibleText: [String] = []
            for block in blocks {
                if block["type"] as? String == "image" {
                    if let image = MessageImage(block) { message.images.append(image) }
                    else { visibleText.append("[Image unavailable or too large]") }
                } else if block["type"] as? String == "text", let text = block["text"] as? String {
                    visibleText.append(text)
                }
            }
            message.body = visibleText.joined(separator: "\n")
            message.thinking = blocks.filter { $0["type"] as? String == "thinking" }.compactMap { $0["thinking"] as? String }.joined(separator: "\n\n")
            message.arguments = blocks.filter { $0["type"] as? String == "toolCall" }.map {
                "\($0["name"] as? String ?? "tool")\n\(prettyJSON($0["arguments"]))"
            }.joined(separator: "\n\n")
        }
        if role == "toolResult" {
            message.id = "tool-" + (json["toolCallId"] as? String ?? UUID().uuidString)
            message.toolName = json["toolName"] as? String ?? "Tool"
        }
        if role == "bashExecution" {
            message.toolName = "bash"
            message.arguments = json["command"] as? String ?? ""
            message.body = json["output"] as? String ?? ""
        }
        if let summary = json["summary"] as? String { message.body = summary }
        message.isError = json["isError"] as? Bool == true || json["stopReason"] as? String == "error"
        if let error = json["errorMessage"] as? String, !error.isEmpty {
            message.body += (message.body.isEmpty ? "" : "\n\n") + error
        }
        if json["stopReason"] as? String == "aborted" { message.body += "\n\n[Stopped]" }
        return message
    }
}

struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
    let mimeType: String
    let name: String
}

struct MessageImage: Identifiable {
    let id = UUID()
    let data: Data
    let mimeType: String
    init?(_ block: JSONObject) {
        guard block["type"] as? String == "image",
              let encoded = block["data"] as? String, encoded.utf8.count <= 28_000_000,
              let data = Data(base64Encoded: encoded) else { return nil }
        self.data = data
        mimeType = block["mimeType"] as? String ?? "application/octet-stream"
    }
}

/// Restores tool arguments from the assistant tool call onto its result row. Pi stores
/// those as separate messages, while the UI intentionally renders one consolidated row.
func parseConversationMessages(_ rawMessages: [JSONObject]) -> [ChatMessage] {
    var calls: [String: (name: String, arguments: String)] = [:]
    for raw in rawMessages where raw["role"] as? String == "assistant" {
        for block in raw["content"] as? [JSONObject] ?? [] where block["type"] as? String == "toolCall" {
            guard let id = block["id"] as? String else { continue }
            calls[id] = (block["name"] as? String ?? "Tool", prettyJSON(block["arguments"]))
        }
    }
    return rawMessages.compactMap { raw in
        guard var message = ChatMessage.parse(raw) else { return nil }
        if message.role == "assistant", message.body.isEmpty, message.thinking.isEmpty, message.images.isEmpty { return nil }
        if raw["role"] as? String == "toolResult",
           let callID = raw["toolCallId"] as? String,
           let call = calls[callID] {
            message.toolName = call.name
            message.arguments = call.arguments
        }
        return message
    }
}

typealias JSONObject = [String: Any]

func textContent(_ content: Any?) -> String {
    if let text = content as? String { return text }
    return (content as? [JSONObject] ?? []).compactMap { block in
        switch block["type"] as? String {
        case "text": return block["text"] as? String
        case "image": return "[Image]"
        default: return nil
        }
    }.joined(separator: "\n")
}

func prettyJSON(_ object: Any?) -> String {
    guard let object, JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "" }
    return text
}

enum DeskError: LocalizedError {
    case message(String)
    case deliveryUnknown(String)
    var errorDescription: String? {
        switch self { case .message(let text), .deliveryUnknown(let text): return text }
    }
}

struct ExtensionDialog: Identifiable {
    let id: String
    let method: String
    let title: String
    let message: String
    let options: [String]
    let prefill: String
    let placeholder: String
}

/// Strict LF framing preserves Unicode separators and split UTF-8 code points.
struct JSONLDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [JSONObject] {
        buffer.append(data)
        var records: [JSONObject] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let object = try JSONSerialization.jsonObject(with: line) as? JSONObject else {
                throw DeskError.message("Pi sent a non-object RPC record.")
            }
            records.append(object)
        }
        guard buffer.count <= 64 * 1024 * 1024 else { throw DeskError.message("Pi RPC record exceeded 64 MB.") }
        return records
    }
}

struct ProcessInvocation {
    var executable: String
    var arguments: [String]

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func path(_ value: String) -> String {
        if value == "~" { return "\"$HOME\"" }
        if value.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(value.dropFirst(2))) }
        return quote(value)
    }

    static func rpc(client: Client, session: SessionRecord) throws -> ProcessInvocation {
        try client.validate()
        guard let url = PiResources.bundle.url(forResource: "session-process", withExtension: "js") else {
            throw DeskError.message("Session process helper is missing.")
        }
        let helper = try String(contentsOf: url, encoding: .utf8)
        var command = "exec node -e " + quote(helper) + " -- " + path(client.executable) + " --mode rpc"
        if let source = session.forkFromPath { command += " --fork " + path(source) }
        else if let file = session.sessionPath { command += " --session " + path(file) }
        if let directory = client.sessionDirectory, !directory.isEmpty { command += " --session-dir " + path(directory) }
        return shell(client: client, command: "cd " + path(session.workingDirectory) + " && " + command)
    }

    static func scopedModelProbe(client: Client, workingDirectory: String) throws -> ProcessInvocation {
        try client.validate()
        let command = "exec " + path(client.executable) + " --mode rpc --no-session"
        return shell(client: client, command: "cd " + path(workingDirectory) + " && " + command)
    }

    static func shell(client: Client, command: String) -> ProcessInvocation {
        // Login shells support version managers; fallback paths cover Finder's sparse environment.
        let script = "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin\"; " + command
        if client.isLocal {
            return ProcessInvocation(executable: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", arguments: ["-lc", script])
        }
        let remote = "exec \"${SHELL:-/bin/sh}\" -lc " + quote(script)
        return ProcessInvocation(executable: "/usr/bin/ssh", arguments: [
            "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-p", String(client.port), client.host, remote
        ])
    }
}
