import SwiftUI

@main
struct ClaudeRCControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView()
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.window)
    }
}
