import XCTest
@testable import Petit4SendCore

/// Sync Key 検出が Windows 版と同じバイト列と失敗時の停止を守っていることを確認する。
final class SyncKeyDetectionTests: XCTestCase {
    /// 開始 `0x01`（中止可）→ 4 秒 → 停止 `0x00` を 2 回（中止不可）。
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
    /// 待機中に中止しても、停止パケットは 2 回送る。
    func testCancellationStillStopsTwice() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try SyncKeyDetection.run(exchange: { bytes, _ in
            commands.append(bytes[0])
        }, pause: { _ in throw TransferError("cancelled") }))
        XCTAssertEqual(commands, [1, 0, 0])
    }
    /// 開始が失敗したら待たず、停止だけ 2 回試みる。
    func testStartTimeoutStillAttemptsStops() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try SyncKeyDetection.run(exchange: { bytes, _ in
            commands.append(bytes[0])
            if bytes[0] == 1 { throw TransferError("timeout") }
        }, pause: { _ in XCTFail("Must not wait after start failure") }))
        XCTAssertEqual(commands, [1, 0, 0])
    }
    /// 1 回目の停止が失敗しても 2 回目を送り、先に起きたエラーを返す。
    func testStopFailureStillAttemptsSecondStopAndReportsError() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try SyncKeyDetection.run(exchange: { bytes, _ in
            commands.append(bytes[0])
            if commands.count == 2 { throw TransferError("stop timeout") }
        }, pause: { _ in }))
        XCTAssertEqual(commands, [1, 0, 0])
    }
}
