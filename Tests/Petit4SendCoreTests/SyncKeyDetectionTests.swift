import XCTest
@testable import Petit4SendCore

final class SyncKeyDetectionTests: XCTestCase {
    func testWindowsCommandSequence() throws {
        var events: [String] = []
        try SyncKeyDetection.run(exchange: { bytes, cancellable in
            XCTAssertEqual(bytes.count, 12)
            XCTAssertEqual(Array(bytes.dropFirst()), [UInt8](repeating: 0, count: 11))
            events.append("\(bytes[0]):\(cancellable)")
        }, pause: { duration in
            XCTAssertEqual(duration, 4)
            events.append("wait")
        })
        XCTAssertEqual(events, ["1:true", "wait", "0:false", "0:false"])
    }
    func testCancellationStillStopsTwice() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try SyncKeyDetection.run(exchange: { bytes, _ in
            commands.append(bytes[0])
        }, pause: { _ in throw TransferError("cancelled") }))
        XCTAssertEqual(commands, [1, 0, 0])
    }
    func testStartTimeoutStillAttemptsStops() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try SyncKeyDetection.run(exchange: { bytes, _ in
            commands.append(bytes[0])
            if bytes[0] == 1 { throw TransferError("timeout") }
        }, pause: { _ in XCTFail("Must not wait after start failure") }))
        XCTAssertEqual(commands, [1, 0, 0])
    }
    func testStopFailureStillAttemptsSecondStopAndReportsError() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try SyncKeyDetection.run(exchange: { bytes, _ in
            commands.append(bytes[0])
            if commands.count == 2 { throw TransferError("stop timeout") }
        }, pause: { _ in }))
        XCTAssertEqual(commands, [1, 0, 0])
    }
}
