import Foundation

public struct Repo: Codable, Identifiable, Equatable {
    public var id: UUID
    /// Absolute, tilde expanded, no trailing slash.
    public var path: String
    /// false = listed but not served.
    public var enabled: Bool
    /// true adds `--spawn worktree`.
    public var worktreeMode: Bool

    public init(id: UUID = UUID(), path: String, enabled: Bool, worktreeMode: Bool) {
        self.id = id
        self.path = path
        self.enabled = enabled
        self.worktreeMode = worktreeMode
    }
}

public enum ServerStatus: Equatable {
    case stopped
    case starting
    case connected(sessions: Int, url: URL?)
    case stopping
    case retrying(attempt: Int, at: Date, lastError: String)
    case untrusted
}
