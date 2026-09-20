import XCTest
@testable import BlackBoxCore

final class CoreTests: XCTestCase {
    func testSSHArgumentsPreserveConfigAndRejectInjection() throws {
        XCTAssertEqual(try SSHConnection(host: "work-mac", user: "", port: "").command(), "/usr/bin/ssh 'work-mac'")
        XCTAssertEqual(try SSHConnection(host: "::1", user: "alice", port: "2222").command(), "/usr/bin/ssh -p 2222 -l 'alice' '::1'")
        for host in ["-oProxyCommand=evil", "host;touch /tmp/no", "host\ncommand", "user@host", "$(id)"] {
            XCTAssertThrowsError(try SSHConnection(host: host, user: "", port: "").command())
        }
        XCTAssertThrowsError(try SSHConnection(host: "host", user: "-root", port: "").command())
        XCTAssertThrowsError(try SSHConnection(host: "host", user: "", port: "65536").command())
    }
    func testPromptDetectionOnlyUsesLastVisibleLine() {
        XCTAssertEqual(TerminalHeuristics.prompt(in: "banner\nalice@mac's password: "), "Password or authentication prompt")
        XCTAssertEqual(TerminalHeuristics.prompt(in: "Enter passphrase for key '/Users/me/.ssh/id':"), "Password or authentication prompt")
        XCTAssertEqual(TerminalHeuristics.prompt(in: "Are you sure you want to continue connecting (yes/no/[fingerprint])?"), "SSH host key confirmation")
        XCTAssertNil(TerminalHeuristics.prompt(in: "alice@mac's password:\nalice@mac ~ % "))
        XCTAssertTrue(TerminalHeuristics.looksLikeShellPrompt("alice@mac ~ % "))
        XCTAssertFalse(TerminalHeuristics.looksLikeShellPrompt("working…"))
    }
    func testSSHStateParsing() {
        XCTAssertEqual(TerminalHeuristics.sshDestination(arguments: "/usr/bin/ssh -p 2222 -i /tmp/key alice@host"), "alice@host")
        XCTAssertEqual(TerminalHeuristics.sshDestination(arguments: "ssh -J bastion -l alice alias"), "alias")
    }
    func testManualToolSurfaceIsReadOnly() {
        let names = OpenRouterClient.tools(mode: .manual).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), Set(["read_terminal", "get_session_state"]))
        XCTAssertEqual(OpenRouterClient.tools(mode: .ask).count, 5)
        XCTAssertEqual(OpenRouterClient.tools(mode: .autonomous).count, 5)
    }
    func testToolCallRoundTripRetainsProtocolIDs() throws {
        let message = APIMessage(role: "assistant", content: nil, tool_calls: [ToolCall(id: "call_1", function: .init(name: "send_text", arguments: "{\"text\":\"pwd\\n\"}"))])
        let decoded = try JSONDecoder().decode(APIMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.tool_calls?.first?.id, "call_1")
        XCTAssertEqual(decoded.tool_calls?.first?.function.name, "send_text")
    }
}
