import Combine
import Darwin
import Foundation

/// Keeps one `claude remote-control` server running per enabled repo.
///
/// Call `apply(_:)` with the full repo list whenever it changes. All state
/// changes happen on the main actor.
@MainActor
public final class ServerSupervisor: ObservableObject {
    @Published public private(set) var statuses: [UUID: ServerStatus] = [:]

    static let stableWindow: TimeInterval = 60
    static let killGrace: TimeInterval = 5
    static let stopAllTimeout: TimeInterval = 3

    private let launcher: ProcessLauncher
    private let clock: SupervisorClock
    private let inspector: ProcessInspector
    private let log: (String) -> Void

    private var runs: [UUID: Run] = [:]

    /// Per-repo bookkeeping that is not published.
    private final class Run {
        var repo: Repo
        var wanted = false
        var removed = false
        var pendingStart = false
        var generation = 0
        var process: RunningProcess?
        var parser = OutputParser()
        var attempt = 0
        var sessions = 0
        var url: URL?
        var untrusted = false
        var alreadyServed = false
        var lastLine: String?
        var retryTimer: Cancellable?
        var stableTimer: Cancellable?
        var killTimer: Cancellable?

        init(repo: Repo) {
            self.repo = repo
        }
    }

    public init(
        launcher: ProcessLauncher,
        clock: SupervisorClock = SystemClock(),
        inspector: ProcessInspector = SystemProcessInspector(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.launcher = launcher
        self.clock = clock
        self.inspector = inspector
        self.log = log
    }

    // MARK: Public

    /// Brings the servers in line with `list`. Repos missing from `list` are stopped
    /// and forgotten; disabled repos are stopped and kept; changed repos (path or
    /// worktree mode) are restarted.
    public func apply(_ list: [Repo]) {
        let listed = Set(list.map(\.id))
        for id in Array(runs.keys) where !listed.contains(id) {
            guard let run = runs[id] else { continue }
            run.wanted = false
            run.removed = true
            stop(id)
        }

        for repo in list {
            let run: Run
            if let existing = runs[repo.id] {
                run = existing
            } else {
                run = Run(repo: repo)
                runs[repo.id] = run
            }
            let changed = run.repo.path != repo.path || run.repo.worktreeMode != repo.worktreeMode
            run.repo = repo
            run.wanted = repo.enabled
            run.removed = false

            guard repo.enabled else {
                stop(repo.id)
                continue
            }

            switch statuses[repo.id] ?? .stopped {
            case .starting, .connected:
                if changed {
                    stop(repo.id)
                    run.pendingStart = true
                }
            case .stopping:
                run.pendingStart = true
            case .stopped, .retrying, .untrusted:
                // Only restart on a change or for a new repo; otherwise a
                // retrying or untrusted repo keeps its own schedule.
                if changed || statuses[repo.id] == nil || statuses[repo.id] == .stopped {
                    launch(repo.id)
                }
            }
        }
    }

    /// Retry now, from `retrying` or `untrusted`. Resets the backoff.
    public func retryNow(_ id: UUID) {
        guard let run = runs[id], run.wanted else { return }
        switch statuses[id] ?? .stopped {
        case .retrying, .untrusted:
            run.attempt = 0
            launch(id)
        default:
            break
        }
    }

    /// App quit. Synchronous. Sends SIGTERM to every live server, polls for up to
    /// 3 seconds, then SIGKILLs any survivor. Does not wait for main-queue callbacks.
    public func stopAll() {
        var pids: [Int32] = []
        for id in Array(runs.keys) {
            guard let run = runs[id] else { continue }
            run.wanted = false
            run.pendingStart = false
            run.generation += 1 // ignore any late callbacks
            run.retryTimer?.cancel()
            run.stableTimer?.cancel()
            run.killTimer?.cancel()
            if let process = run.process {
                pids.append(process.pid)
            }
            run.process = nil
            statuses[id] = .stopped
        }
        runs.removeAll()

        for pid in pids {
            inspector.send(SIGTERM, to: pid)
        }
        var waited: TimeInterval = 0
        while waited < Self.stopAllTimeout, pids.contains(where: inspector.isAlive) {
            inspector.sleep(0.1)
            waited += 0.1
        }
        for pid in pids where inspector.isAlive(pid) {
            inspector.send(SIGKILL, to: pid)
        }
    }

    // MARK: Start

    private func launch(_ id: UUID) {
        guard let run = runs[id] else { return }
        run.retryTimer?.cancel()
        run.retryTimer = nil
        run.generation += 1
        let generation = run.generation
        run.parser = OutputParser()
        run.sessions = 0
        run.url = nil
        run.untrusted = false
        run.alreadyServed = false
        run.lastLine = nil

        do {
            run.process = try launcher.launch(
                repo: run.repo,
                onOutput: { [weak self] data in
                    MainActor.assumeIsolated { self?.handleOutput(id, generation, data) }
                },
                onExit: { [weak self] code in
                    MainActor.assumeIsolated { self?.handleExit(id, generation, code) }
                }
            )
        } catch {
            run.process = nil
            let message = "Cannot start: \(error)"
            log(message)
            scheduleRetry(id, lastError: message)
            return
        }
        log("start \(run.repo.path)")
        setStatus(id, .starting)
    }

    private func retryFired(_ id: UUID) {
        guard let run = runs[id], run.wanted else { return }
        if case .retrying = statuses[id] ?? .stopped {
            launch(id)
        }
    }

    private func scheduleRetry(_ id: UUID, lastError: String) {
        guard let run = runs[id], run.wanted else { return }
        run.attempt += 1
        let delay: TimeInterval = run.attempt == 1 ? 5 : 30
        setStatus(id, .retrying(
            attempt: run.attempt,
            at: clock.now().addingTimeInterval(delay),
            lastError: lastError
        ))
        run.retryTimer = clock.schedule(after: delay) { [weak self] in
            MainActor.assumeIsolated { self?.retryFired(id) }
        }
    }

    // MARK: Output and exit

    private func handleOutput(_ id: UUID, _ generation: Int, _ data: Data) {
        guard let run = runs[id], run.generation == generation else { return }
        for event in run.parser.feed(data) {
            handle(event, id, run)
        }
    }

    private func handle(_ event: OutputEvent, _ id: UUID, _ run: Run) {
        switch event {
        case .connecting:
            // A reconnect is not a failure, but the stability window restarts.
            if case .connected = statuses[id] ?? .stopped {
                run.stableTimer?.cancel()
                run.stableTimer = nil
                setStatus(id, .starting)
            }
        case .connected:
            guard case .starting = statuses[id] ?? .stopped else { return }
            setStatus(id, .connected(sessions: run.sessions, url: run.url))
            if run.stableTimer == nil {
                run.stableTimer = clock.schedule(after: Self.stableWindow) { [weak self] in
                    MainActor.assumeIsolated { self?.resetStreak(id) }
                }
            }
        case let .sessions(count):
            run.sessions = count
            publishConnectedIfNeeded(id, run)
        case let .environmentURL(url):
            run.url = url
            publishConnectedIfNeeded(id, run)
        case .untrustedWorkspace:
            run.untrusted = true
        case .alreadyServed:
            run.alreadyServed = true
            run.process?.terminate()
        case let .other(line):
            run.lastLine = line
            log(line)
        }
    }

    private func publishConnectedIfNeeded(_ id: UUID, _ run: Run) {
        if case .connected = statuses[id] ?? .stopped {
            setStatus(id, .connected(sessions: run.sessions, url: run.url))
        }
    }

    private func resetStreak(_ id: UUID) {
        guard let run = runs[id] else { return }
        run.stableTimer = nil
        run.attempt = 0
    }

    private func handleExit(_ id: UUID, _ generation: Int, _ code: Int32) {
        guard let run = runs[id], run.generation == generation else { return }
        for event in run.parser.finish() {
            handle(event, id, run)
        }
        run.process = nil
        run.killTimer?.cancel()
        run.killTimer = nil
        run.stableTimer?.cancel()
        run.stableTimer = nil
        log("exit \(code)")

        switch statuses[id] ?? .stopped {
        case .stopping:
            if run.pendingStart, run.wanted {
                run.pendingStart = false
                launch(id)
            } else {
                didBecomeStopped(id)
            }
        case .starting, .connected:
            if run.untrusted {
                run.retryTimer?.cancel()
                run.retryTimer = nil
                setStatus(id, .untrusted)
            } else {
                scheduleRetry(id, lastError: lastError(for: run, code: code))
            }
        case .stopped, .retrying, .untrusted:
            break
        }
    }

    private func lastError(for run: Run, code: Int32) -> String {
        if run.alreadyServed {
            return "Already served by another process"
        }
        if code == 127 {
            return "claude not found at ~/.local/bin/claude"
        }
        return "\(run.lastLine ?? "Exited") (exit \(code))"
    }

    // MARK: Stop

    private func stop(_ id: UUID) {
        guard let run = runs[id] else { return }
        run.pendingStart = false
        run.retryTimer?.cancel()
        run.retryTimer = nil

        switch statuses[id] ?? .stopped {
        case .starting, .connected:
            run.stableTimer?.cancel()
            run.stableTimer = nil
            setStatus(id, .stopping)
            run.process?.terminate()
            run.killTimer = clock.schedule(after: Self.killGrace) { [weak self] in
                MainActor.assumeIsolated { self?.forceKill(id) }
            }
        case .retrying, .untrusted, .stopped:
            didBecomeStopped(id)
        case .stopping:
            break
        }
    }

    private func forceKill(_ id: UUID) {
        guard let run = runs[id], case .stopping = statuses[id] ?? .stopped else { return }
        run.process?.kill()
    }

    private func didBecomeStopped(_ id: UUID) {
        guard let run = runs[id] else { return }
        if run.removed {
            runs[id] = nil
            statuses[id] = nil
        } else {
            setStatus(id, .stopped)
        }
    }

    // MARK: Helpers

    private func setStatus(_ id: UUID, _ status: ServerStatus) {
        statuses[id] = status
    }
}
