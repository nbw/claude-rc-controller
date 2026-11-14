import Foundation
@testable import RCCore
import XCTest

final class OutputParserTests: XCTestCase {
    private let envURL = URL(string: "https://claude.ai/code?environment=env_01AYJsf2oB2Mja4hXbJnT6TD")!

    private func fixture(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.resourceURL)
        return try Data(contentsOf: base.appendingPathComponent("Fixtures/\(name).txt"))
    }

    private func parse(_ data: Data) -> [OutputEvent] {
        var parser = OutputParser()
        var events = parser.feed(data)
        events += parser.finish()
        return events
    }

    // MARK: Fixtures

    func testConnectedFixtureEvents() throws {
        let events = try parse(fixture("connected"))
        XCTAssertTrue(events.contains(.connecting))
        XCTAssertTrue(events.contains(.connected))
        XCTAssertTrue(events.contains(.sessions(0)))
        XCTAssertTrue(events.contains(.sessions(1)))
        XCTAssertTrue(events.contains(.environmentURL(envURL)))
    }

    func testConnectedFixtureNeverReportsSessionLinkAsEnvironmentURL() throws {
        let events = try parse(fixture("connected"))
        for case let .environmentURL(url) in events {
            XCTAssertEqual(url, envURL)
        }
    }

    func testUntrustedFixture() throws {
        let events = try parse(fixture("untrusted"))
        XCTAssertTrue(events.contains(.untrustedWorkspace))
    }

    func testAlreadyServedFixture() throws {
        let events = try parse(fixture("already-served"))
        XCTAssertTrue(events.contains(.alreadyServed))
    }

    func testFixtureFedOneByteAtATimeGivesSameEvents() throws {
        for name in ["connected", "untrusted", "already-served"] {
            let data = try fixture(name)
            var parser = OutputParser()
            var events: [OutputEvent] = []
            for byte in data {
                events += parser.feed(Data([byte]))
            }
            events += parser.finish()
            XCTAssertEqual(events, parse(data), name)
        }
    }

    // MARK: Noise and classification

    func testZshNoiseIsOther() {
        var parser = OutputParser()
        let events = parser.feed(Data("""
        (eval):1: can't change option: zle
        mise WARN  missing: rust@stable

        """.utf8))
        XCTAssertEqual(events, [
            .other("(eval):1: can't change option: zle"),
            .other("mise WARN  missing: rust@stable"),
        ])
    }

    func testEmptyLinesProduceNothing() {
        var parser = OutputParser()
        XCTAssertEqual(parser.feed(Data("\n\r\n\r   \n".utf8)), [])
    }

    func testCSIAndOSCAreStripped() {
        var parser = OutputParser()
        let line = "\u{1B}[1A\u{1B}[J\u{1B}]8;;https://claude.ai/code/session_x\u{07}Attached\u{1B}]8;;\u{07}"
        XCTAssertEqual(parser.feed(Data((line + "\n").utf8)), [.other("Attached")])
    }

    func testOSCTerminatedByStringTerminator() {
        var parser = OutputParser()
        let line = "\u{1B}]8;;https://x.example\u{1B}\\Hi\n"
        XCTAssertEqual(parser.feed(Data(line.utf8)), [.other("Hi")])
    }

    func testCarriageReturnSplitsRepaints() {
        var parser = OutputParser()
        let events = parser.feed(Data("Capacity: 0/32\rCapacity: 1/32\r".utf8))
        XCTAssertEqual(events, [.sessions(0), .sessions(1)])
    }

    func testPartialLineIsHeldUntilTerminatorOrFinish() {
        var parser = OutputParser()
        XCTAssertEqual(parser.feed(Data("untrusted".utf8)), [])
        XCTAssertEqual(parser.feed(Data(" workspace".utf8)), [])
        XCTAssertEqual(parser.finish(), [.other("untrusted workspace")])
        XCTAssertEqual(parser.finish(), [])
    }

    func testMultiByteCharacterSplitAcrossChunks() {
        var parser = OutputParser()
        let bytes = Array("· Connected · q · main\n".utf8)
        var events: [OutputEvent] = []
        for byte in bytes {
            events += parser.feed(Data([byte]))
        }
        XCTAssertEqual(events, [.connected])
    }

    func testInvalidUTF8DecodesLossilyWithoutCrashing() {
        var parser = OutputParser()
        let events = parser.feed(Data([0x66, 0xFF, 0x6F, 0x0A]))
        XCTAssertEqual(events.count, 1)
    }
}
