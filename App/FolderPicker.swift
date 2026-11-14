import AppKit

enum FolderPicker {
    /// Modal folder chooser. Activates the app first, since a menu bar app is
    /// usually in the background.
    @MainActor
    static func chooseFolders() -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
