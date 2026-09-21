import Foundation

enum AgentMode: String, CaseIterable, Identifiable {
    case manual = "Observe mode"
    case ask = "Ask Before Command"
    case autonomous = "Autonomous"
    var id: String { rawValue }
}

struct SessionState: Codable {
    var location = "local"
    var hostname = ProcessInfo.processInfo.hostName
    var username = NSUserName()
    var sshAppearsConnected = false
    var connection = "Local shell"
    var lastCommand = ""
    var commandAppearsRunning = false
    var interactivePrompt: String?
    var processRunning = false
    var outputRevision = 0
    var note = "Host and command completion are best-effort observations; quiet output does not prove completion."
}

enum TerminalHeuristics {
    static func prompt(in text: String) -> String? {
        let last = text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let s = last.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("password:") || s.contains("password for") || s.contains("passphrase for") || s.contains("verification code:") || s.contains("(password)") { return "Password or authentication prompt" }
        if s.contains("are you sure you want to continue connecting") { return "SSH host key confirmation" }
        if s.hasSuffix("[y/n]") || s.hasSuffix("[y/n]:") || s.hasSuffix("(yes/no)?") { return "Confirmation prompt" }
        return nil
    }
    static func looksLikeShellPrompt(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["$", "#", "%", ">", "❯"].contains { s.hasSuffix($0) }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func sshDestination(arguments: String) -> String? {
        // ps output is not a shell parser. Ambiguous commands stay unknown.
        let parts = arguments.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let i = parts.firstIndex(where: { $0 == "ssh" || $0.hasSuffix("/ssh") }) else { return nil }
        let optionsWithValue = Set(["-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S", "-W", "-w"])
        var skip = false
        for part in parts.dropFirst(i + 1) {
            if skip { skip = false; continue }
            if optionsWithValue.contains(part) { skip = true; continue }
            if part.hasPrefix("-") { continue }
            return part.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return nil
    }
}

struct SSHConnection {
    var host: String
    var user: String
    var port: String
    func command() throws -> String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AppError.message("Enter a hostname, IP address, or SSH config alias (without ssh or user@).")
        }
        guard user.isEmpty || (!user.hasPrefix("-") && user.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains)) else {
            throw AppError.message("Enter a valid SSH username, or leave it blank to use SSH config.")
        }
        var args = ["/usr/bin/ssh"]
        if !port.isEmpty {
            guard let number = Int(port), (1...65535).contains(number) else { throw AppError.message("Port must be between 1 and 65535.") }
            args += ["-p", String(number)]
        }
        if !user.isEmpty { args += ["-l", TerminalHeuristics.shellQuote(user)] }
        args += [TerminalHeuristics.shellQuote(host)]
        return args.joined(separator: " ")
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
