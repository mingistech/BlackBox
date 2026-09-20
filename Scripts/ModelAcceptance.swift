// Opt-in live check: compile with BlackBox/Core/*.swift and KeychainStore.swift.
// Uses the saved OpenRouter key, synthetic files, and an isolated local PTY.
// Makes billable API requests. Never reads the user's terminal or chat history.
import Foundation

final class TestTerminal: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private let lock = NSLock()
    private var captured = Data()
    init(home: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-i"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "PS1": "fixture$ "]
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock(); self.captured.append(data); self.lock.unlock()
        }
        try process.run()
    }
    func send(_ text: String) throws { try input.fileHandleForWriting.write(contentsOf: Data(text.utf8)) }
    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }
    func close() {
        try? send("exit\n")
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

@main struct ModelAcceptance {
    static func main() async throws {
        guard let key = try KeychainStore.read(), !key.isEmpty else { throw AppError.message("No saved OpenRouter key.") }
        var failures = 0
        for model in RecommendedModels.all {
            if CommandLine.arguments.count > 1 && !CommandLine.arguments.dropFirst().contains(model.id) { continue }
            do {
                try await check(model: model, key: key)
                print("PASS \(model.name): command, delayed output, tool continuation")
            } catch {
                failures += 1
                print("FAIL \(model.name): \(error.localizedDescription)")
            }
            fflush(stdout)
        }
        if failures > 0 { exit(EXIT_FAILURE) }
    }
    static func check(model: RecommendedModel, key: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("BlackBoxAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = "FIRST-\(UUID().uuidString)", delayed = "DELAYED-\(UUID().uuidString)"
        try first.write(to: home.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try delayed.write(to: home.appendingPathComponent("delayed.txt"), atomically: true, encoding: .utf8)
        let terminal = try TestTerminal(home: home)
        defer { terminal.close() }
        var messages = [APIMessage(role: "system", content: "You are testing a terminal assistant in an isolated local shell. Use the tools to run exactly the supplied command, then read_terminal until the output arrives. send_text needs a trailing newline to execute; send_key return also works. Tool results include terminal snapshots. Never guess file contents. Only run the supplied command. No other commands are allowed. Report the two exact file contents when finished."),
                        APIMessage(role: "user", content: "Run this exact command: cat first.txt; sleep 2; cat delayed.txt. Read the terminal output and report both file contents.")]
        var didExecute = false, didRead = false, buffer = ""
        for _ in 0..<8 {
            let reply = try await OpenRouterClient().complete(key: key, model: model.id, messages: messages, mode: .autonomous)
            messages.append(reply)
            guard let calls = reply.tool_calls, !calls.isEmpty else {
                guard didExecute, didRead, let text = reply.content, text.contains(first), text.contains(delayed) else {
                    if CommandLine.arguments.contains("--diagnose") { print("Synthetic-fixture response: \(reply.content ?? "<empty>")") }
                    throw AppError.message("Did not report both verified terminal results (executed=\(didExecute), read=\(didRead), first=\(reply.content?.contains(first) ?? false), delayed=\(reply.content?.contains(delayed) ?? false)).")
                }
                return
            }
            for call in calls {
                let args = try JSONDecoder().decode(ToolArguments.self, from: Data(call.function.arguments.utf8))
                var result: String
                switch call.function.name {
                case "send_text", "send_key":
                    let text = call.function.name == "send_text" ? (args.text ?? "") : (args.key == "return" ? "\n" : "")
                    buffer += text.replacingOccurrences(of: "\r", with: "\n")
                    let allowed = "cat first.txt; sleep 2; cat delayed.txt"
                    guard !text.isEmpty, buffer == allowed + "\n" || allowed.hasPrefix(buffer) else {
                        throw AppError.message("Model requested a command outside the test fixture.")
                    }
                    try terminal.send(text)
                    didExecute = buffer.hasSuffix("\n")
                    result = "Typed successfully. Read terminal to observe output."
                case "read_terminal":
                    let seconds = min(5, max(0.25, args.wait_seconds ?? 0.5))
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    result = terminal.snapshot()
                    didRead = true
                case "get_session_state": result = "Local isolated test shell; prompt fixture$; command completion must be checked using read_terminal."
                default: throw AppError.message("Unexpected tool in fixture.")
                }
                messages.append(APIMessage(role: "tool", content: result, tool_call_id: call.id))
            }
        }
        throw AppError.message("Exceeded eight model responses.")
    }
}
