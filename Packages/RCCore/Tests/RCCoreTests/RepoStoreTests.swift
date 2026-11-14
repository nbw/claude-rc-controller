import Foundation
@testable import RCCore
import XCTest

final class RepoStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var reposFile: URL {
        dir.appendingPathComponent("repos.json")
    }

    private var dirsFile: URL {
        dir.appendingPathComponent("dirs.txt")
    }

    private func makeFolder(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func store(importFrom: URL? = nil) throws -> RepoStore {
        try RepoStore(fileURL: reposFile, importURL: importFrom)
    }

    // MARK: First run

    func testFirstRunWithoutImportFileWritesEmptyFile() throws {
        let s = try store(importFrom: dirsFile)
        XCTAssertTrue(s.repos.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reposFile.path))
    }

    func testFirstRunImportsDirsFile() throws {
        let q = try makeFolder("q")
        let stitch = try makeFolder("stitch")
        try """
        # comment line
        \(q)   # trailing comment

        \(stitch)/
        \(q)
        """.write(to: dirsFile, atomically: true, encoding: .utf8)

        let s = try store(importFrom: dirsFile)
        XCTAssertEqual(s.repos.map(\.path), [q, stitch])
        XCTAssertTrue(s.repos.allSatisfy { $0.enabled && !$0.worktreeMode })
    }

    func testImportRunsOnlyOnce() throws {
        let q = try makeFolder("q")
        try q.write(to: dirsFile, atomically: true, encoding: .utf8)

        let first = try store(importFrom: dirsFile)
        try first.remove(id: first.repos[0].id)

        let second = try store(importFrom: dirsFile)
        XCTAssertTrue(second.repos.isEmpty)
    }

    // MARK: Add

    func testAddNormalizesPathAndDefaults() throws {
        let q = try makeFolder("q")
        let s = try store()
        let repo = try s.add(path: q + "/")
        XCTAssertEqual(repo.path, q)
        XCTAssertTrue(repo.enabled)
        XCTAssertFalse(repo.worktreeMode)
        XCTAssertEqual(s.repos, [repo])
    }

    func testAddRejectsDuplicate() throws {
        let q = try makeFolder("q")
        let s = try store()
        _ = try s.add(path: q)
        XCTAssertThrowsError(try s.add(path: q + "/")) { error in
            XCTAssertEqual(error as? RepoStoreError, .duplicate(q))
        }
        XCTAssertEqual(s.repos.count, 1)
    }

    func testAddRejectsNonDirectory() throws {
        let file = dir.appendingPathComponent("file.txt").path
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        let s = try store()
        XCTAssertThrowsError(try s.add(path: file)) { error in
            XCTAssertEqual(error as? RepoStoreError, .notADirectory(file))
        }
        XCTAssertTrue(s.repos.isEmpty)
    }

    func testAddRejectsMissingPath() throws {
        let s = try store()
        XCTAssertThrowsError(try s.add(path: dir.appendingPathComponent("nope").path))
    }

    // MARK: Mutations persist

    func testMutationsPersistAcrossReopen() throws {
        let q = try makeFolder("q")
        let stitch = try makeFolder("stitch")
        let s = try store()
        let a = try s.add(path: q)
        let b = try s.add(path: stitch)
        try s.setEnabled(id: a.id, false)
        try s.setWorktreeMode(id: b.id, true)

        let reopened = try store()
        XCTAssertEqual(reopened.repos.count, 2)
        XCTAssertEqual(reopened.repos.first { $0.id == a.id }?.enabled, false)
        XCTAssertEqual(reopened.repos.first { $0.id == b.id }?.worktreeMode, true)
    }

    func testRemovePersists() throws {
        let q = try makeFolder("q")
        let s = try store()
        let a = try s.add(path: q)
        try s.remove(id: a.id)
        XCTAssertTrue(try store().repos.isEmpty)
    }

    // MARK: Corrupt file

    func testCorruptFileIsMovedAsideAndStoreStartsEmpty() throws {
        try "{ not json".write(to: reposFile, atomically: true, encoding: .utf8)
        let s = try store()
        XCTAssertTrue(s.repos.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("repos.json.corrupt-") })

        // The store is usable afterwards.
        let q = try makeFolder("q")
        _ = try s.add(path: q)
        XCTAssertEqual(try store().repos.count, 1)
    }

    // MARK: Parsing

    func testDirsFileParsing() {
        let text = """
        # header
          /a/b   # note
        ~/c/

        \t
        """
        XCTAssertEqual(
            DirsFile.parse(text),
            ["/a/b", NSHomeDirectory() + "/c"]
        )
    }

    func testPathNormalizeStripsTrailingSlashAndExpandsTilde() {
        XCTAssertEqual(PathNormalizer.normalize("~/x/"), NSHomeDirectory() + "/x")
        XCTAssertEqual(PathNormalizer.normalize("/tmp/a//b/"), "/tmp/a/b")
    }
}
