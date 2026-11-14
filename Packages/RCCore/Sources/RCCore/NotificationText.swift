import Foundation

/// Builds notification text. Pure: no UI or system calls.
public enum NotificationText {
    public struct RepoState: Equatable {
        public var name: String
        public var status: ServerStatus

        public init(name: String, status: ServerStatus) {
            self.name = name
            self.status = status
        }
    }

    /// Summary once every enabled repo is up or untrusted (or after 60 seconds).
    /// Nil when there are no repos.
    ///
    /// - "Remote Control up: q, stitch" when all are connected.
    /// - "Remote Control: 1 of 2 up. stitch: not trusted" otherwise.
    public static func startupSummary(_ repos: [RepoState]) -> String? {
        guard !repos.isEmpty else { return nil }
        let up = repos.filter(isUp)
        if up.count == repos.count {
            return "Remote Control up: " + repos.map(\.name).joined(separator: ", ")
        }
        let others = repos.filter { !isUp($0) }.map { "\($0.name): \(reason($0.status))" }
        return "Remote Control: \(up.count) of \(repos.count) up. " + others.joined(separator: "; ")
    }

    /// Body text for a failure notice, or nil if this status is not a failure.
    static func failureBody(name: String, status: ServerStatus) -> String? {
        switch status {
        case .untrusted:
            return "\(name) is not trusted. Run `claude` in this folder once to accept the workspace trust dialog."
        case let .retrying(attempt, _, lastError) where attempt >= 3:
            return "\(name) keeps failing: \(lastError)"
        default:
            return nil
        }
    }

    private static func isUp(_ repo: RepoState) -> Bool {
        if case .connected = repo.status { return true }
        return false
    }

    private static func reason(_ status: ServerStatus) -> String {
        switch status {
        case .connected: "up"
        case .starting: "starting"
        case .stopping: "stopping"
        case .stopped: "off"
        case .retrying: "retrying"
        case .untrusted: "not trusted"
        }
    }
}

/// Sends at most one failure notice per retry streak. A streak ends when the
/// repo is turned off or removed.
public struct FailureNotifier {
    private var notified: Set<UUID> = []

    public init() {}

    /// Returns the notice body to show now, or nil if none is due.
    public mutating func notice(repoID: UUID, name: String, status: ServerStatus) -> String? {
        if case .stopped = status {
            notified.remove(repoID)
            return nil
        }
        guard let body = NotificationText.failureBody(name: name, status: status),
              notified.insert(repoID).inserted
        else {
            return nil
        }
        return body
    }
}
