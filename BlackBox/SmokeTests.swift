#if DEBUG
import AppKit
import Foundation

// Opt-in, no-network integration tests: real PTY + real agent loop, scripted OpenRouter replies.
final class SmokeURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var responder: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.responder
            Self.lock.unlock()
            let data = try handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
enum SmokeTests {
    static func run(terminal: TerminalSession) async {
        var results: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw AppError.message("FAIL: \(name)") }
            results.append("PASS: \(name)")
        }
        do {
            terminal.start()
            try await Task.sleep(for: .seconds(2))
            try check(terminal.state.processRunning, "Local shell starts in a PTY")
            try terminal.send("printf 'BLACKBOX_%s\\n' 'PTY_OK'\r")
            try await terminal.waitForOutput(seconds: 4)
            try check(terminal.snapshot().contains("BLACKBOX_PTY_OK"), "Real shell executes and output is readable")
            try terminal.send("sleep 30\r")
            try await Task.sleep(for: .seconds(1))
            try terminal.send("\u{03}")
            try await terminal.waitForOutput(seconds: 3)
            try terminal.send("printf 'INTERRUPT_%s\\n' 'OK'\r")
            try await terminal.waitForOutput(seconds: 3)
            try check(terminal.snapshot().contains("INTERRUPT_OK"), "Ctrl-C interrupts foreground command and shell recovers")

            try terminal.send("/bin/sh -c 'printf \"Password: \"; stty -echo; IFS= read -r answer; stty echo; printf \"\\nAUTH_%s\\n\" \"OK\"'\r")
            try await terminal.waitForOutput(seconds: 3)
            try check(terminal.awaitingSecret && terminal.echoDisabled, "Authentication prompt is detected locally with echo disabled")
            try terminal.sendSecret("smoke-private-password-7419")
            try await terminal.waitForOutput(seconds: 3)
            let authSnapshot = terminal.snapshot()
            try check(authSnapshot.contains("AUTH_OK") && !authSnapshot.contains("smoke-private-password-7419"), "Secret reaches the PTY without entering agent context or last command")

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SmokeURLProtocol.self]
            let suite = "BlackBoxSmokeTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let agent = AgentSession(terminal: terminal, client: OpenRouterClient(session: URLSession(configuration: config)), defaults: defaults)
            agent.keyProvider = { "test-only-not-a-real-key" }
            var requestCount = 0
            var sawResult = false
            func setResponse(command: String, expectedResult: String, separateReturn: Bool = false) {
                requestCount = 0
                sawResult = false
                SmokeURLProtocol.responder = { request in
                    var data = request.httpBody
                    if data == nil, let stream = request.httpBodyStream {
                        stream.open(); defer { stream.close() }
                        var collected = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(buffer, count: count) }
                        data = collected
                    }
                    let body = try JSONSerialization.jsonObject(with: data ?? Data()) as! [String: Any]
                    let messages = body["messages"] as! [[String: Any]]
                    requestCount += 1
                    let message: APIMessage
                    if requestCount == 1 {
                        let args = try JSONSerialization.data(withJSONObject: ["text": command])
                        message = APIMessage(role: "assistant", content: nil, tool_calls: [ToolCall(id: "test-call", function: .init(name: "send_text", arguments: String(decoding: args, as: UTF8.self)))])
                    } else if separateReturn && requestCount == 2 {
                        message = APIMessage(role: "assistant", content: nil, tool_calls: [ToolCall(id: "return-call", function: .init(name: "send_key", arguments: "{\"key\":\"return\"}"))])
                    } else {
                        sawResult = messages.contains { ($0["role"] as? String) == "tool" && ($0["content"] as? String)?.contains(expectedResult) == true }
                        message = APIMessage(role: "assistant", content: "Test round trip complete.")
                    }
                    let encoded = try JSONEncoder().encode(message)
                    return try JSONSerialization.data(withJSONObject: ["choices": [["message": try JSONSerialization.jsonObject(with: encoded)]]])
                }
            }
            func awaitAgent(approval: Bool?) async throws {
                let deadline = Date().addingTimeInterval(12)
                while agent.isBusy && Date() < deadline {
                    if agent.approval != nil, let approval { agent.resolveApproval(approval) }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(!agent.isBusy && agent.error == nil, "Agent turn completes without error")
            }
            agent.mode = .ask
            setResponse(command: "printf 'AGENT_%s\\n' 'ROUNDTRIP_OK'\n", expectedResult: "AGENT_ROUNDTRIP_OK")
            agent.submit("Run the test command")
            try await Task.sleep(for: .milliseconds(350))
            try check(agent.approval != nil && !terminal.snapshot().contains("AGENT_ROUNDTRIP_OK"), "Ask mode waits before writing to the terminal")
            try await awaitAgent(approval: true)
            try check(sawResult && terminal.snapshot().contains("AGENT_ROUNDTRIP_OK"), "Approved tool executes in associated PTY and result returns to model")

            agent.clear()
            setResponse(command: "printf 'SPLIT_%s\\n' 'RETURN_OK'", expectedResult: "SPLIT_RETURN_OK", separateReturn: true)
            agent.submit("Test command with a separate Return")
            try await Task.sleep(for: .milliseconds(350))
            try check(agent.approval != nil, "Split command requests approval before typing")
            agent.resolveApproval(true)
            try await awaitAgent(approval: nil)
            try check(sawResult && terminal.snapshot().contains("SPLIT_RETURN_OK"), "Approved command and separate Return require only one approval")

            agent.clear()
            setResponse(command: "printf 'DENIED_%s\\n' 'UNEXPECTED'\n", expectedResult: "User denied")
            agent.submit("Test denied action")
            try await awaitAgent(approval: false)
            try check(sawResult && !terminal.snapshot().contains("DENIED_UNEXPECTED"), "Denied tool never executes")

            agent.clear(); agent.mode = .manual
            setResponse(command: "printf 'MANUAL_%s\\n' 'UNEXPECTED'\n", expectedResult: "Observe mode")
            agent.submit("Test malformed model write in manual mode")
            try await awaitAgent(approval: nil)
            try check(sawResult && !terminal.snapshot().contains("MANUAL_UNEXPECTED"), "Observe mode rejects writes even if the model requests one")

            agent.clear(); agent.mode = .autonomous
            setResponse(command: "printf 'AUTO_%s\\n' 'OK'\n", expectedResult: "AUTO_OK")
            agent.submit("Test autonomous mode")
            try await awaitAgent(approval: nil)
            try check(sawResult && terminal.snapshot().contains("AUTO_OK"), "Autonomous mode runs and observes a command without approval")

            agent.clear(); agent.mode = .ask
            setResponse(command: "printf 'CANCEL_%s\\n' 'UNEXPECTED'\n", expectedResult: "")
            agent.submit("Test cancellation")
            try await Task.sleep(for: .milliseconds(350))
            agent.stop()
            try await awaitAgent(approval: nil)
            try check(agent.approval == nil && !terminal.snapshot().contains("CANCEL_UNEXPECTED"), "Stopping resolves pending approval without running the action")

            try terminal.send("/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=2 -p 1 127.0.0.1\r")
            try await terminal.waitForOutput(seconds: 4)
            try check(terminal.snapshot().contains("Connection refused"), "System SSH runs inside the same PTY and reports connection errors")
            try check(terminal.state.location == "local", "SSH exit restores local session state")
        } catch { results.append(error.localizedDescription) }
        let report = results.joined(separator: "\n") + "\n"
        try? report.write(toFile: "/private/tmp/blackbox-smoke-results.txt", atomically: true, encoding: .utf8)
        terminal.shutdown()
        NSApplication.shared.terminate(nil)
    }
}
#endif
