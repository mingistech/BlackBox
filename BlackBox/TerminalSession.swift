import AppKit
import Combine
import Darwin
import SwiftTerm
import SwiftUI

final class ObservedTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(data)
        super.send(source: source, data: data)
    }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published private(set) var state = SessionState()
    @Published var error: String?
    let view = ObservedTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
    private var timer: Timer?
    private(set) var inputRevision = 0
    private var inputLine = ""
    private var inputReliable = true
    private var lastOutput = Date.distantPast
    private var lastAction = Date.distantPast
    private var lastAgentSnapshot = ""
    private var started = false
    private var connectingTo: SSHConnection?
    private var lastForeground: pid_t = -1
    private var sensitiveInput = false

    override init() {
        super.init()
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.065, green: 0.075, blue: 0.095, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedRed: 0.86, green: 0.9, blue: 0.93, alpha: 1)
        view.onOutput = { [weak self] in self?.receivedOutput() }
        view.onInput = { [weak self] bytes in self?.recordInput(bytes) }
    }

    func start() {
        guard !started else { return }
        started = true
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let shell = environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(executable: shell, args: ["-l"], environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: NSHomeDirectory())
        state.processRunning = view.process.running
        if !state.processRunning { error = "Could not start \(shell)." }
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let session = self else { return }
            Task { @MainActor in session.refreshState() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if view.process.running { view.terminate() }
    }

    var echoDisabled: Bool {
        guard view.process.childfd >= 0 else { return false }
        var settings = termios()
        return tcgetattr(view.process.childfd, &settings) == 0 && settings.c_lflag & UInt(ECHO) == 0
    }
    var awaitingSecret: Bool { state.interactivePrompt == "Password or authentication prompt" }

    func send(_ text: String, fromAgent: Bool = false) throws {
        guard state.processRunning else { throw AppError.message("The shell has exited. Reopen the app to start a new session.") }
        if fromAgent && awaitingSecret { throw AppError.message("Authentication is waiting for the user. Do not send credentials through chat.") }
        let bytes = Array(text.utf8)[...]
        recordInput(bytes, fromAgent: fromAgent)
        view.process.send(data: bytes)
    }

    // Credentials are sent directly to the PTY and never enter the agent history or command tracker.
    func sendSecret(_ secret: String) throws {
        guard awaitingSecret, echoDisabled else { throw AppError.message("Secret input is available only at an authentication prompt with terminal echo disabled.") }
        guard !secret.contains("\n"), !secret.contains("\r") else { throw AppError.message("Enter a single-line password or verification code.") }
        inputRevision += 1
        sensitiveInput = true
        inputLine = ""
        view.process.send(data: Array((secret + "\r").utf8)[...])
        lastAction = Date()
    }

    func connect(_ connection: SSHConnection) throws {
        refreshState()
        guard state.location == "local", !state.commandAppearsRunning, inputLine.isEmpty else {
            throw AppError.message("Return to an empty local shell prompt before connecting. You can also run ssh directly in the terminal.")
        }
        let command = try connection.command()
        connectingTo = connection
        try send(command + "\r")
        state.location = "remote"
        state.hostname = connection.host
        state.username = connection.user.isEmpty ? "SSH config / unknown" : connection.user
        state.connection = "Connecting (inferred)"
    }

    func snapshot(consumeNew: Bool = true) -> String {
        refreshState()
        let screen = terminalText()
        let fresh: String
        if screen == lastAgentSnapshot { fresh = "(no new visible output)" }
        else if !lastAgentSnapshot.isEmpty, screen.hasPrefix(lastAgentSnapshot) { fresh = String(screen.dropFirst(lastAgentSnapshot.count)) }
        else { fresh = screen } // Redraws and scrollback rollover need a fresh snapshot.
        if consumeNew { lastAgentSnapshot = screen }
        let json = stateSnapshot()
        return "SESSION STATE\n\(json)\nNEW / CHANGED OUTPUT\n\(fresh.suffix(16000))\nTERMINAL SNAPSHOT\n\(screen.suffix(20000))"
    }

    func stateSnapshot() -> String {
        refreshState()
        return (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func waitForOutput(seconds: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(min(max(seconds, 0), 15))
        let began = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(150))
            refreshState()
            if Date().timeIntervalSince(began) >= 0.8 && (state.interactivePrompt != nil || Date().timeIntervalSince(max(lastOutput, lastAction)) > 0.8) { break }
        }
    }

    private func terminalText() -> String {
        let data = view.getTerminal().getBufferAsData()
        return String(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).suffix(40000))
    }

    private func receivedOutput() {
        lastOutput = Date()
        state.outputRevision += 1
        let text = terminalText()
        state.interactivePrompt = TerminalHeuristics.prompt(in: text)
        if state.interactivePrompt == nil { sensitiveInput = false }
        if state.location == "remote", state.interactivePrompt == nil, TerminalHeuristics.looksLikeShellPrompt(text) {
            state.sshAppearsConnected = true
            state.connection = "SSH connected (inferred)"
        }
    }

    private func recordInput(_ bytes: ArraySlice<UInt8>, fromAgent: Bool = false) {
        inputRevision += 1
        lastAction = Date()
        state.outputRevision += 1
        // Raw-mode editors also disable echo. Treating their input as private is intentional.
        let localShellInput = tcgetpgrp(view.process.childfd) == view.process.shellPid
        guard !awaitingSecret, !sensitiveInput, fromAgent || localShellInput || !echoDisabled else { inputLine = ""; return }
        for byte in bytes {
            switch byte {
            case 13, 10:
                state.lastCommand = inputReliable ? inputLine : "(edited in terminal; exact command unknown)"
                inputLine = ""
                inputReliable = true
                state.commandAppearsRunning = true
            case 3:
                inputLine = ""; inputReliable = true; state.commandAppearsRunning = false
            case 127, 8:
                if !inputLine.isEmpty { inputLine.removeLast() }
            case 21: inputLine = ""
            case 27, 9: inputReliable = false
            case 32...126: inputLine.append(Character(UnicodeScalar(byte)))
            default: break
            }
        }
    }

    private func refreshState() {
        state.processRunning = view.process.running
        guard state.processRunning else { return }
        let foreground = tcgetpgrp(view.process.childfd)
        let shellForeground = foreground == view.process.shellPid
        let quiet = Date().timeIntervalSince(max(lastAction, lastOutput)) > 0.9
        state.commandAppearsRunning = !quiet || (!shellForeground && state.interactivePrompt == nil && !TerminalHeuristics.looksLikeShellPrompt(terminalText()))
        if foreground != lastForeground {
            lastForeground = foreground
            if shellForeground {
                connectingTo = nil
                state.location = "local"
                state.hostname = ProcessInfo.processInfo.hostName
                state.username = NSUserName()
                state.sshAppearsConnected = false
                state.connection = "Local shell"
            } else if foreground > 0 {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-p", String(foreground), "-o", "comm=", "-o", "args="]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let command = String(decoding: data, as: UTF8.self)
                    // The first column is comm, the remainder is argv including ssh itself.
                    let args = command.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                    if command.split(whereSeparator: { $0.isWhitespace }).first.map({ $0 == "ssh" || $0.hasSuffix("/ssh") }) == true {
                        state.location = "remote"
                        let destination = TerminalHeuristics.sshDestination(arguments: args) ?? connectingTo?.host ?? "unknown SSH host"
                        let pieces = destination.split(separator: "@", maxSplits: 1)
                        state.hostname = pieces.last.map(String.init) ?? destination
                        state.username = pieces.count == 2 ? String(pieces[0]) : (connectingTo?.user.isEmpty == false ? connectingTo!.user : "SSH config / unknown")
                        state.connection = "SSH active (inferred)"
                    }
                }
            }
        }
        if state.location == "remote", state.interactivePrompt == nil, TerminalHeuristics.looksLikeShellPrompt(terminalText()), quiet {
            state.sshAppearsConnected = true
            state.connection = "SSH connected (inferred)"
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        state.processRunning = false
        state.commandAppearsRunning = false
        state.sshAppearsConnected = false
        state.connection = "Shell exited (\(exitCode.map(String.init) ?? "unknown status"))"
        timer?.invalidate()
    }
}

struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> ObservedTerminalView {
        DispatchQueue.main.async { session.start(); session.view.window?.makeFirstResponder(session.view) }
        return session.view
    }
    func updateNSView(_ nsView: ObservedTerminalView, context: Context) {}
}
