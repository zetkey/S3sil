import AppKit
import SwiftUI

@main
struct S3SilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("S3Sil") {
            ContentView()
                .environment(app)
                .focusedSceneValue(\.appState, app)
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            S3SilCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
