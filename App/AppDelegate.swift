import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_: Notification) {
        // Two copies would kill each other's servers as orphans, so the second
        // one quits before it touches anything.
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        model.start()
    }

    func applicationWillTerminate(_: Notification) {
        model.shutdown()
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0 != NSRunningApplication.current }
    }
}
