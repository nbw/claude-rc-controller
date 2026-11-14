import Foundation
@testable import RCCore
import XCTest

final class AppPathsTests: XCTestCase {
    func testLocations() {
        let paths = AppPaths(home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(
            paths.reposFile.path,
            "/Users/test/Library/Application Support/claude-rc-controller/repos.json"
        )
        XCTAssertEqual(
            paths.pidsFile.path,
            "/Users/test/Library/Application Support/claude-rc-controller/pids.json"
        )
        XCTAssertEqual(paths.logFile.path, "/Users/test/Library/Logs/claude-rc-controller/controller.log")
        XCTAssertEqual(paths.legacyDirsFile.path, "/Users/test/.claude/remote-control/dirs.txt")
    }
}
