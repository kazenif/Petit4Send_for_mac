import XCTest
@testable import Petit4SendCore

/// シリアルポートの抜き差しで、選択をどう残すかを固定する。
final class PortSelectionTests: XCTestCase {
    func testSelectsTheSinglePortThatAppeared() {
        let choice = SerialPort.choose(previous: ["/dev/cu.Bluetooth"], current: ["/dev/cu.Bluetooth", "/dev/cu.usbserial"], selected: "")
        XCTAssertEqual(choice, "/dev/cu.usbserial")
    }
    func testKeepsTheCurrentSelectionWhenAnotherPortAppears() {
        let choice = SerialPort.choose(previous: ["/dev/cu.usbserial"], current: ["/dev/cu.usbserial", "/dev/cu.other"], selected: "/dev/cu.usbserial")
        XCTAssertEqual(choice, "/dev/cu.usbserial")
    }
    func testClearsSelectionWhenTheChosenPortDisappears() {
        let choice = SerialPort.choose(previous: ["/dev/cu.usbserial", "/dev/cu.other"], current: ["/dev/cu.other"], selected: "/dev/cu.usbserial")
        XCTAssertEqual(choice, "")
    }
    func testDoesNotGuessWhenSeveralPortsAppearTogether() {
        let choice = SerialPort.choose(previous: [], current: ["/dev/cu.a", "/dev/cu.b"], selected: "")
        XCTAssertEqual(choice, "")
    }
    func testRestoresOnlyAPortThatIsPresent() {
        XCTAssertEqual(SerialPort.restored(saved: "/dev/cu.usbserial", available: ["/dev/cu.Bluetooth", "/dev/cu.usbserial"]), "/dev/cu.usbserial")
        XCTAssertEqual(SerialPort.restored(saved: "/dev/cu.usbserial", available: ["/dev/cu.Bluetooth"]), "")
        XCTAssertEqual(SerialPort.restored(saved: "", available: ["/dev/cu.usbserial"]), "")
    }
}
