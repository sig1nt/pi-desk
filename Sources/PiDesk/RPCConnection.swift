import Foundation
import Darwin

/// One RPC process per conversation. All protocol state is confined to the main actor.
@MainActor
final class RPCConnection {
    var onEvent: ((JSONObject) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var decoder = JSONLDecoder()
    private var stderr = ""
    private var stopping = false
    private let writer = DispatchQueue(label: "PiDesk.rpc.writer")
    private var pending: [String: (CheckedContinuation<JSONObject, Error>, DispatchWorkItem, String)] = [:]

    var isRunning: Bool { process?.isRunning == true && !stopping }

    func start(_ invocation: ProcessInvocation) throws {
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        // Do not leak the launching agent's session identity to the controlled client.
        for key in ["PI_SESSION_ID", "PI_SESSION_FILE", "PI_PROVIDER", "PI_MODEL", "PI_REASONING_LEVEL"] { environment.removeValue(forKey: key) }
        process.environment = environment
        let readers = DispatchGroup()
        readers.enter(); readers.enter()
        process.terminationHandler = { [weak self] process in
            readers.notify(queue: .main) {
                DispatchQueue.main.async { self?.exited(process.terminationStatus) }
            }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        try? stdout.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        read(stdout.fileHandleForReading, group: readers) { [weak self] data in self?.receive(data) }
        read(errorPipe.fileHandleForReading, group: readers) { [weak self] data in
            guard let self else { return }
            self.stderr = String((self.stderr + String(decoding: data, as: UTF8.self)).suffix(12_000))
        }
    }

    private func read(_ handle: FileHandle, group: DispatchGroup, receive: @escaping @MainActor (Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? handle.close(); group.leave() }
            while true {
                // read(upToCount:) can wait to fill the requested size on a pipe.
                // availableData returns each currently available chunk, enabling live streaming.
                let data = handle.availableData
                if data.isEmpty { break }
                DispatchQueue.main.async { receive(data) }
            }
        }
    }

    func request(_ type: String, fields: JSONObject = [:], timeout: TimeInterval = 30) async throws -> JSONObject {
        guard isRunning else { throw DeskError.message("Pi is not connected.") }
        let id = UUID().uuidString
        var command = fields
        command["type"] = type
        command["id"] = id
        return try await withCheckedThrowingContinuation { continuation in
            let expiry = DispatchWorkItem { [weak self] in
                guard let self, let (waiting, _, command) = self.pending.removeValue(forKey: id) else { return }
                let message = "Pi timed out responding to \(type). Check the connection before retrying; the command may have been accepted."
                waiting.resume(throwing: command == "prompt" ? DeskError.deliveryUnknown(message) : DeskError.message(message))
            }
            pending[id] = (continuation, expiry, type)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: expiry)
            do { try send(command) }
            catch { finish(id: id, result: .failure(error)) }
        }
    }

    func send(_ object: JSONObject) throws {
        guard isRunning, let input else { throw DeskError.message("Pi is not connected.") }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        data.append(0x0A)
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch { DispatchQueue.main.async { self?.fail("Could not write to Pi: \(error.localizedDescription)") } }
        }
    }

    private func receive(_ data: Data) {
        guard !stopping else { return }
        do {
            for record in try decoder.append(data) {
                if record["type"] as? String == "response" {
                    guard let id = record["id"] as? String else { continue }
                    if record["success"] as? Bool == true {
                        finish(id: id, result: .success(record["data"] as? JSONObject ?? [:]))
                    } else {
                        finish(id: id, result: .failure(DeskError.message(record["error"] as? String ?? "Pi rejected the request.")))
                    }
                } else { onEvent?(record) }
            }
        } catch {
            fail("Invalid Pi RPC output: \(error.localizedDescription)\nEnsure shell startup scripts do not print to stdout.")
        }
    }

    private func finish(id: String, result: Result<JSONObject, Error>) {
        guard let (continuation, expiry, _) = pending.removeValue(forKey: id) else { return }
        expiry.cancel()
        continuation.resume(with: result)
    }

    private func rejectPending(_ message: String) {
        for (id, entry) in pending {
            let error: DeskError = entry.2 == "prompt" ? .deliveryUnknown(message) : .message(message)
            finish(id: id, result: .failure(error))
        }
    }

    private func fail(_ message: String) {
        guard !stopping else { return }
        stop()
        onDisconnect?(message)
    }

    private func exited(_ status: Int32) {
        let expected = stopping
        stopping = true
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "Pi disconnected (exit \(status))." + (detail.isEmpty ? "" : "\n" + detail)
        rejectPending(message)
        try? input?.close()
        input = nil
        if !expected { onDisconnect?(message) }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        rejectPending("Connection closed.")
        // EOF lets Pi perform its own shutdown/abort before escalating.
        let handle = input
        input = nil
        writer.async { try? handle?.close() }
        guard let process else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if process.isRunning { process.terminate() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }

    func waitForExit() async {
        for _ in 0..<35 {
            guard process?.isRunning == true else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
