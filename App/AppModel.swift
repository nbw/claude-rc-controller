import AppKit
import Combine
import Foundation
import RCCore

/// Bridges the RCCore types to SwiftUI. Views observe this one object.
@MainActor
final class AppModel: ObservableObject {
    enum PendingChange: Equatable {
        case disable(UUID)
        case remove(UUID)
        case worktree(UUID, Bool)

        var repoID: UUID {
            switch self {
            case let .disable(id), let .remove(id), let .worktree(id, _):
                id
            }
        }
    }

    @Published private(set) var repos: [Repo] = []
    @Published private(set) var startingSince: [UUID: Date] = [:]
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published var addError: String?
    @Published var loginItemError: String?

    let supervisor: ServerSupervisor
    private let paths: AppPaths
    private let pidStore: PidRecordStore
    private let notifier = Notifier()
    private var store: RepoStore?
    private var failures = FailureNotifier()
    private var summaryPosted = false
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    /// Does no disk work, so it is safe to run before the single-instance check.
    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        let log = EventLog(fileURL: paths.logFile)
        let pids = PidRecordStore(fileURL: paths.pidsFile)
        pidStore = pids
        supervisor = ServerSupervisor(
            launcher: ShellProcessLauncher(),
            log: { path, entry in log.record(repo: path, entry) },
            onLiveChange: { live in _ = try? pids.save(live) }
        )
    }

    // MARK: Lifecycle

    /// Orphan cleanup, load the repo list, start the enabled repos, ask for
    /// notification permission. Call once, from a single instance only.
    func start() {
        started = true
        OrphanCleaner.run(store: pidStore, inspector: SystemProcessInspector())

        do {
            store = try RepoStore(fileURL: paths.reposFile, importURL: paths.legacyDirsFile)
            repos = store?.repos ?? []
        } catch {
            addError = "Cannot load repo list: \(error.localizedDescription)"
        }

        supervisor.$statuses
            .sink { [weak self] statuses in self?.statusesChanged(statuses) }
            .store(in: &cancellables)
        supervisor.$statuses
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        notifier.start()
        supervisor.apply(repos)

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.postSummary(force: true)
        }
    }

    /// App quit. Ends every server and its sessions.
    func shutdown() {
        guard started else { return }
        supervisor.stopAll()
    }

    // MARK: Queries

    func status(of id: UUID) -> ServerStatus? {
        supervisor.statuses[id]
    }

    /// True while a server is up or coming up, so changing it ends sessions.
    func isLive(_ id: UUID) -> Bool {
        switch supervisor.statuses[id] ?? .stopped {
        case .starting, .connected:
            true
        default:
            false
        }
    }

    /// True when an enabled repo needs the user: untrusted, or retrying 3 times or more.
    var hasProblem: Bool {
        repos.contains { repo in
            guard repo.enabled else { return false }
            switch supervisor.statuses[repo.id] ?? .stopped {
            case .untrusted:
                return true
            case let .retrying(attempt, _, _):
                return attempt >= 3
            default:
                return false
            }
        }
    }

    // MARK: Mutations

    func addRepos(_ urls: [URL]) {
        guard let store else {
            addError = "Repo list is unavailable."
            return
        }
        var problems: [String] = []
        for url in urls {
            do {
                try store.add(path: url.path)
            } catch let RepoStoreError.duplicate(path) {
                problems.append("Already listed: \(path)")
            } catch let RepoStoreError.notADirectory(path) {
                problems.append("Not a folder: \(path)")
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        addError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        commit()
    }

    func remove(_ id: UUID) {
        mutate { try $0.remove(id: id) }
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        mutate { try $0.setEnabled(id: id, enabled) }
    }

    func setWorktreeMode(_ id: UUID, _ on: Bool) {
        mutate { try $0.setWorktreeMode(id: id, on) }
    }

    func perform(_ change: PendingChange) {
        switch change {
        case let .disable(id):
            setEnabled(id, false)
        case let .remove(id):
            remove(id)
        case let .worktree(id, on):
            setWorktreeMode(id, on)
        }
    }

    func retryNow(_ id: UUID) {
        supervisor.retryNow(id)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: Actions

    func openTerminal(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }

    func openLog() {
        let url = paths.logFile
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Private

    private func mutate(_ change: (RepoStore) throws -> Void) {
        guard let store else { return }
        do {
            try change(store)
            commit()
        } catch {
            addError = "Cannot save repo list: \(error.localizedDescription)"
        }
    }

    private func commit() {
        repos = store?.repos ?? repos
        supervisor.apply(repos)
    }

    private func statusesChanged(_ statuses: [UUID: ServerStatus]) {
        for repo in repos {
            let status = statuses[repo.id] ?? .stopped
            if case .starting = status {
                if startingSince[repo.id] == nil {
                    startingSince[repo.id] = Date()
                }
            } else {
                startingSince[repo.id] = nil
            }
            if let body = failures.notice(repoID: repo.id, name: name(of: repo), status: status) {
                notifier.post(title: "Remote Control: \(name(of: repo))", body: body)
            }
        }
        postSummary(force: false)
    }

    /// Posts the startup summary once per launch: when every enabled repo is up
    /// or untrusted, or when forced by the 60-second timer.
    private func postSummary(force: Bool) {
        guard !summaryPosted else { return }
        let states = repos.filter(\.enabled).map { repo in
            NotificationText.RepoState(name: name(of: repo), status: supervisor.statuses[repo.id] ?? .stopped)
        }
        let settled = states.allSatisfy { state in
            switch state.status {
            case .connected, .untrusted:
                true
            default:
                false
            }
        }
        guard force || settled else { return }
        summaryPosted = true
        if let text = NotificationText.startupSummary(states) {
            notifier.post(title: "Remote Control", body: text)
        }
    }

    private func name(of repo: Repo) -> String {
        URL(fileURLWithPath: repo.path).lastPathComponent
    }
}
