@testable import RCCore
import XCTest

final class SmokeTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(RCCore.version.isEmpty)
    }
}
