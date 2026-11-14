import AppKit
import SwiftUI

/// The menu bar panel: one row per repo, then the footer.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var pending: AppModel.PendingChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.repos.isEmpty {
                Text("No repos yet. Add a folder to keep Remote Control running there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(model.repos) { repo in
                    RepoRow(model: model, repo: repo, pending: $pending)
                    Divider()
                }
            }
            footer
        }
        .frame(width: 340)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Add repo…") {
                    model.addRepos(FolderPicker.chooseFolders())
                }
                Spacer()
                Button("Open log") {
                    model.openLog()
                }
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)

            if let error = model.addError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .buttonStyle(.borderless)
        .padding(12)
    }
}
