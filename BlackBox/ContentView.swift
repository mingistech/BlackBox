import SwiftUI
import Combine

@MainActor
final class Workspace: ObservableObject {
    let terminal: TerminalSession
    let agent: AgentSession
    init() {
        let terminal = TerminalSession()
        self.terminal = terminal
        self.agent = AgentSession(terminal: terminal)
    }
}

struct ContentView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        WorkspaceView(terminal: workspace.terminal, agent: workspace.agent)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
                    await SmokeTests.run(terminal: workspace.terminal)
                }
                #endif
            }
    }
}

struct WorkspaceView: View {
    @ObservedObject var terminal: TerminalSession
    @ObservedObject var agent: AgentSession
    @State private var showingConnect = false
    @Environment(\.openSettings) private var openSettings
    @State private var secret = ""

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: terminal.state.location == "remote" ? "network" : "terminal")
                        Text(terminal.state.hostname).fontWeight(.medium)
                        Spacer()
                        if terminal.state.commandAppearsRunning { Text("Active").foregroundStyle(.secondary) }
                        Button { try? terminal.send("\u{03}") } label: { Label("Interrupt", systemImage: "stop.circle") }
                            .buttonStyle(.borderless).help("Send Ctrl-C to the terminal")
                    }.font(.caption).padding(12).background(.bar)
                    TerminalPane(session: terminal)
                        .padding(8).background(Color(red: 0.065, green: 0.075, blue: 0.095))
                    if terminal.awaitingSecret {
                        HStack {
                            Image(systemName: "lock.fill")
                            SecureField("Password or code — sent only to terminal", text: $secret)
                                .onSubmit(sendSecret)
                            Button("Send", action: sendSecret).disabled(secret.isEmpty)
                        }.padding(10).background(.bar)
                    } else if let prompt = terminal.state.interactivePrompt {
                        Label("\(prompt) — respond in the terminal", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.caption).padding(10)
                    }
                }.frame(minWidth: 430, idealWidth: 740)
                AgentPane(agent: agent, needsSetup: !agent.configuredProviders.contains(agent.provider), showSettings: { openSettings() })
                    .frame(minWidth: 340, idealWidth: 390, maxWidth: 480)
            }
            Divider()
            HStack(spacing: 14) {
                Circle().fill(terminal.state.processRunning ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(terminal.state.connection)
                Text("\(terminal.state.username) @ \(terminal.state.hostname)").lineLimit(1)
                Spacer()
                Text("\(agent.provider.name) · \(agent.model)").lineLimit(1).truncationMode(.middle)
                Text(agent.status).foregroundStyle(agent.isBusy ? Color.accentColor : Color.secondary)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 900, minHeight: 580)
        .toolbar {
            ToolbarItem { Button { showingConnect = true } label: { Label("Connect", systemImage: "network") }.disabled(agent.isBusy || terminal.state.location == "remote") }
            ToolbarItem {
                Menu {
                    Picker("Agent Mode", selection: $agent.mode) {
                        ForEach(AgentMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(agent.mode.rawValue)
                        .padding(.horizontal, 6)
                }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Agent Mode: \(agent.mode.rawValue)")
                .help("Manual: read only. Ask: approve each action. Autonomous: act without approval.")
            }
            ToolbarItem { Button { openSettings() } label: { Image(systemName: "gearshape") }.help("AI providers and API keys") }
        }
        .sheet(isPresented: $showingConnect) { ConnectView(terminal: terminal) }
        .alert("Terminal", isPresented: Binding(get: { terminal.error != nil }, set: { if !$0 { terminal.error = nil } })) {
            Button("OK") { terminal.error = nil }
        } message: { Text(terminal.error ?? "") }
        .onAppear(perform: refreshSetupState)
        .onDisappear { agent.stop(); terminal.shutdown() }
    }
    private func refreshSetupState() {
        agent.refreshProviderConfiguration()
    }
    private func sendSecret() {
        do { try terminal.sendSecret(secret); secret = "" }
        catch { terminal.error = error.localizedDescription }
    }
}

struct AgentPane: View {
    @ObservedObject var agent: AgentSession
    let needsSetup: Bool
    let showSettings: () -> Void
    @State private var draft = ""
    @State private var promptHistory = PromptHistory()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Assistant", systemImage: "sparkle").fontWeight(.semibold)
                Spacer()
                Button { agent.clear() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).disabled(agent.isBusy || agent.entries.isEmpty).help("Clear conversation")
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if agent.entries.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Image(systemName: "terminal.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                                Text("One terminal. One assistant.").font(.title3.weight(.semibold))
                                Text("Ask about the machine in this terminal. The assistant can inspect output and help you run the next command.")
                                    .foregroundStyle(.secondary)
                                Text("Terminal context is sent to \(agent.provider.name) when you chat. Enter passwords in the terminal, never in chat.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if needsSetup {
                                    Button("Set up \(agent.provider.name)", action: showSettings)
                                }
                                ForEach(["Identify this machine", "Help troubleshoot this SSH connection"], id: \.self) { suggestion in
                                    Button(suggestion) { draft = suggestion }.buttonStyle(.link)
                                }
                            }.padding(.vertical, 28)
                        }
                        ForEach(agent.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.role.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                if entry.role == "Tool" {
                                    Text(entry.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                                } else {
                                    Text(entry.text).font(.system(size: 13)).lineSpacing(4)
                                }
                            }.textSelection(.enabled).id(entry.id)
                        }
                        if agent.isBusy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(agent.status).foregroundStyle(.secondary).font(.caption) }.id("status") }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: agent.entries.count) { _, _ in
                    if let last = agent.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let error = agent.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { agent.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }.padding(12).background(Color.orange.opacity(0.08))
            }
            if let approval = agent.approval {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Approve terminal action", systemImage: "hand.raised").font(.headline)
                    Text("\(approval.name) on \(approval.host)").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(approval.arguments.debugDescription).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    HStack {
                        Button("Deny") { agent.resolveApproval(false) }
                        Spacer()
                        Button("Allow once") { agent.resolveApproval(true) }.buttonStyle(.borderedProminent)
                    }
                }.padding(14).background(Color.accentColor.opacity(0.08))
            }
            Divider()
            VStack(spacing: 10) {
                PromptInput(text: $draft, isEnabled: !agent.isBusy, send: sendPrompt,
                            previous: { promptHistory.previous(draft: draft) },
                            next: { promptHistory.next() })
                HStack(spacing: 8) {
                    Text(agent.mode == .manual ? "Read-only access" : agent.mode == .ask ? "You approve terminal actions" : "Terminal actions run automatically")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    ModelPickerButton(agent: agent)
                    if agent.isBusy {
                        Button("Stop") { agent.stop() }.keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button(action: sendPrompt) { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding(14)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func sendPrompt() {
        guard !agent.isBusy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = draft
        promptHistory.record(message)
        draft = ""
        agent.submit(message)
    }


}

struct ConnectView: View {
    @ObservedObject var terminal: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect over SSH").font(.title2.weight(.semibold))
            Text("Uses /usr/bin/ssh and your existing ~/.ssh/config. Passwords and host-key confirmations appear in the terminal.").font(.callout).foregroundStyle(.secondary)
            TextField("Hostname, IP, or SSH config alias", text: $host)
            TextField("Username (optional — use SSH config)", text: $user)
            TextField("Port (optional — use SSH config)", text: $port)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") {
                    do { try terminal.connect(SSHConnection(host: host, user: user, port: port)); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(host.isEmpty)
            }
        }.padding(26).frame(width: 430)
    }
}
