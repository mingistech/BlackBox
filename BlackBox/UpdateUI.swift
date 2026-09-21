import SwiftUI

struct UpdateCommands: Commands {
    @ObservedObject var checker: UpdateChecker
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(checker.isChecking ? "Checking for Updates…" : "Check for Updates…") {
                Task { await checker.check() }
            }
            .disabled(checker.isChecking)
        }
    }
}

struct UpdateNoticePresenter: ViewModifier {
    @ObservedObject var checker: UpdateChecker
    @Environment(\.openURL) private var openURL
    func body(content: Content) -> some View {
        content.alert(checker.notice?.title ?? "BlackBox Updates",
                      isPresented: Binding(get: { checker.notice != nil }, set: { if !$0 { checker.notice = nil } }),
                      presenting: checker.notice) { notice in
            if let url = notice.releaseURL {
                Button("Open Release Page") { openURL(url) }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
    }
}
