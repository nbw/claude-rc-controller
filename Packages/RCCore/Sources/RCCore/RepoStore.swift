import Foundation

public enum RepoStoreError: Error, Equatable {
    case duplicate(String)
    case notADirectory(String)
    case unknownRepo(UUID)
}

/// Holds the repo list and persists it to `repos.json`.
public final class RepoStore {
    public private(set) var repos: [Repo] = []

    private let fileURL: URL
    private let importURL: URL?
    private let fileManager: FileManager
    private let now: () -> Date

    /// Loads `fileURL`. If it does not exist, imports `importURL` (when given
    /// and present), then writes the file at once, even if empty, so the
    /// import never runs twice. A corrupt file is moved aside and the store
    /// starts empty.
    public init(
        fileURL: URL,
        importURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.fileURL = fileURL
        self.importURL = importURL
        self.fileManager = fileManager
        self.now = now
        try load()
    }

    @discardableResult
    public func add(path rawPath: String) throws -> Repo {
        let path = PathNormalizer.normalize(rawPath)
        guard !repos.contains(where: { $0.path == path }) else {
            throw RepoStoreError.duplicate(path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RepoStoreError.notADirectory(path)
        }
        let repo = Repo(path: path, enabled: true, worktreeMode: false)
        repos.append(repo)
        try save()
        return repo
    }

    public func remove(id: UUID) throws {
        repos.removeAll { $0.id == id }
        try save()
    }

    public func setEnabled(id: UUID, _ enabled: Bool) throws {
        try update(id) { $0.enabled = enabled }
    }

    public func setWorktreeMode(id: UUID, _ worktreeMode: Bool) throws {
        try update(id) { $0.worktreeMode = worktreeMode }
    }

    // MARK: Private

    private func update(_ id: UUID, _ change: (inout Repo) -> Void) throws {
        guard let index = repos.firstIndex(where: { $0.id == id }) else {
            throw RepoStoreError.unknownRepo(id)
        }
        change(&repos[index])
        try save()
    }

    private func load() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            repos = importedRepos()
            try save()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            repos = try JSONDecoder().decode([Repo].self, from: data)
        } catch {
            let stamp = Int(now().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
            try? fileManager.moveItem(at: fileURL, to: aside)
            repos = []
            try save()
        }
    }

    private func importedRepos() -> [Repo] {
        guard let importURL,
              let text = try? String(contentsOf: importURL, encoding: .utf8)
        else {
            return []
        }
        var seen = Set<String>()
        var result: [Repo] = []
        for path in DirsFile.parse(text) where seen.insert(path).inserted {
            result.append(Repo(path: path, enabled: true, worktreeMode: false))
        }
        return result
    }

    private func save() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(repos).write(to: fileURL, options: .atomic)
    }
}
