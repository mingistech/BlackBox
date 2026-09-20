import SwiftUI

@main
struct BlackBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace: Workspace

    init() {
        ReleasePreferences.migrate()
        _workspace = StateObject(wrappedValue: Workspace())
    }
    var body: some Scene {
        Window("BlackBox", id: "workspace") {
            ContentView(workspace: workspace)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AboutCommands()
        }

        Settings {
            SettingsView(agent: workspace.agent)
        }
        .windowResizability(.contentSize)

        Window("About BlackBox", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About BlackBox") { openWindow(id: "about") }
        }
    }
}

private struct AboutView: View {
    private var appIcon: NSImage {
        // Read the compiled icon from this build instead of the application's
        // system-cached icon, which can survive an artwork update.
        let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "BlackBox"
        let filename = (iconFile as NSString).pathExtension.isEmpty ? iconFile + ".icns" : iconFile
        if let url = Bundle.main.resourceURL?.appendingPathComponent(filename),
           let data = try? Data(contentsOf: url),
           let image = NSImage(data: data) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 160, height: 160)
                .accessibilityLabel("BlackBox app icon")
            Text("BlackBox")
                .font(.system(size: 24, weight: .semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 30)
        .padding(.bottom, 36)
        .frame(width: 320)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
