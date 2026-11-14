import AppKit
import RCCore
import SwiftUI

/// One repo: status dot, name, path, status line, enable switch, and a menu.
///
/// Turning a server off, removing it, or changing its worktree mode while it is
/// starting or connected asks first, inline. A menu inside a `MenuBarExtra`
/// window misbehaves with `.alert`, so the confirmation is plain views.
struct RepoRow: View {
    @ObservedObject var model: AppModel
    let repo: Repo
    @Binding var pending: AppModel.PendingChange?

    private var status: ServerStatus {
        model.status(of: repo.id) ?? .stopped
    }

    private var name: String {
        URL(fileURLWithPath: repo.path).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fontWeight(.medium)
                    Text(repo.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statusLine
                }

                Spacer(minLength: 4)

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                menu
            }

            if let change = pending, change.repoID == repo.id {
                confirmation(for: change)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Status

    /// A timeline, so the retry countdown and the 30-second "no status" text
    /// update each second.
    private var statusLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(statusText(now: context.date))
                .font(.caption)
                .foregroundStyle(dotColor)
        }
    }

    private func statusText(now: Date) -> String {
        switch status {
        case .stopped:
            return "Off"
        case .starting:
            if let since = model.startingSince[repo.id], now.timeIntervalSince(since) > 30 {
                return "Starting (no status yet)"
            }
            return "Starting…"
        case let .connected(sessions, _):
            return "Connected · \(sessions) session(s)"
        case .stopping:
            return "Stopping…"
        case let .retrying(_, at, lastError):
            let seconds = max(0, Int(ceil(at.timeIntervalSince(now))))
            return "Retrying in \(seconds) s: \(lastError)"
        case .untrusted:
            return "Not trusted: run `claude` in this folder once"
        }
    }

    private var dotColor: Color {
        switch status {
        case .connected:
            Color.green
        case .starting, .retrying:
            Color.yellow
        case .untrusted:
            Color.red
        case .stopped, .stopping:
            Color.gray
        }
    }

    // MARK: Controls

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { repo.enabled },
            set: { newValue in
                if newValue {
                    model.setEnabled(repo.id, true)
                } else {
                    requestChange(.disable(repo.id))
                }
            }
        )
    }

    private var worktreeBinding: Binding<Bool> {
        Binding(
            get: { repo.worktreeMode },
            set: { requestChange(.worktree(repo.id, $0)) }
        )
    }

    private var menu: some View {
        Menu {
            if case let .connected(_, url?) = status {
                Button("Open on claude.ai") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            }
            Button("Open Terminal here") {
                model.openTerminal(path: repo.path)
            }
            Toggle("New sessions in worktrees", isOn: worktreeBinding)
            if isRetryable {
                Button("Retry now") {
                    model.retryNow(repo.id)
                }
            }
            Divider()
            Button("Remove", role: .destructive) {
                requestChange(.remove(repo.id))
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var isRetryable: Bool {
        switch status {
        case .retrying, .untrusted:
            true
        default:
            false
        }
    }

    /// Acts at once when the server is not live; otherwise asks first.
    private func requestChange(_ change: AppModel.PendingChange) {
        if model.isLive(repo.id) {
            pending = change
        } else {
            model.perform(change)
        }
    }

    private func confirmation(for change: AppModel.PendingChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stop this server? Its sessions will end.")
                .font(.caption)
            HStack {
                Spacer()
                Button("Cancel") {
                    pending = nil
                }
                Button("Stop") {
                    model.perform(change)
                    pending = nil
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
    }
}
