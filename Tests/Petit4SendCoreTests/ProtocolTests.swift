import XCTest
@testable import Petit4SendCore

final class ProtocolTests: XCTestCase {
    func testCRCReference() {
        // CRC-16/KOOPMAN: reflected polynomial C7ED, init/xorout FFFF.
        XCTAssertEqual(Codec.crc(Array("123456789".utf8)), 0x0b3a)
        XCTAssertEqual(Codec.crc([]),0)
    }
    func testLZLiteralAndOverlappingReference() throws {
        // Independent hand-packed tokens: literal A (0+41), reference distance=1 length=32.
        let decoded = try Codec.decompress([0x82,0x02,0xf0,0x01],size:33)
        XCTAssertEqual(decoded,[UInt8](repeating:65,count:33))
    }
    func testCompressionRoundTrip() throws {
        var random: UInt32 = 1234
        let noise: [UInt8] = (0..<5000).map { _ in random = random &* 1664525 &+ 1013904223; return UInt8(truncatingIfNeeded:random >> 16) }
        let cases = [[], [0], [255], Array("日本語\nPRINT 123\r\n".utf8), [UInt8](repeating:42,count:5000), noise, noise+noise]
        for bytes in cases {
            let compressed = Codec.compress(bytes)
            XCTAssertEqual(compressed.count%4,0)
            XCTAssertEqual(try Codec.decompress(compressed,size:bytes.count),bytes)
        }
    }
    func testMalformedLZ() {
        XCTAssertThrowsError(try Codec.decompress([],size:1))
        XCTAssertThrowsError(try Codec.decompress([1],size:1))
        XCTAssertThrowsError(try Codec.decompress([],size:Codec.maximumSize+1))
    }
    func testUSBHeader() throws {
        let bytes: [UInt8] = [0x41,0,0x42,0]
        let stream = try USBProtocol.stream(bytes:bytes,name:"test",kind:.text,compression:.none)
        XCTAssertEqual(Array(stream[0..<16]),[UInt8](repeating:0,count:16))
        XCTAssertEqual(Array(stream[16..<66]),[UInt8](repeating:1,count:50))
        XCTAssertEqual(stream[66],0)
        XCTAssertEqual(String(bytes:stream[67..<75],encoding:.ascii),"TXT:TEST")
        XCTAssertEqual(Codec.integer(stream,103,4),4)
        XCTAssertEqual(stream[111],0)
        XCTAssertEqual(Codec.integer(stream,112,4),4)
        XCTAssertEqual(Array(stream[116..<120]),bytes)
        XCTAssertEqual(Codec.integer(stream,120,2),Int(Codec.crc(bytes)))
        XCTAssertThrowsError(try USBProtocol.stream(bytes:bytes,name:"日本語",kind:.text,compression:.none))
    }
    func testHIDReportsAgainstSwitchReceiver() throws {
        let input = (0..<1000).map { UInt8(truncatingIfNeeded:$0*37) }
        let packets = try USBProtocol.reports(input,syncKey:12)
        var output = BitWriter()
        for (clock,packet) in packets.enumerated() {
            XCTAssertEqual(packet.count,12); XCTAssertEqual(packet[0],50)
            let indices = packet[1...6].map { keyCodes.firstIndex(of:$0)! }.sorted()
            XCTAssertEqual(Set(indices).count,6)
            var value: UInt64 = 0
            // Exact combinatorial sum used by @RECEIVE in P4SEND122.PRG.
            for (i,n) in indices.enumerated() { value += USBProtocol.choose(n,i+1) }
            value |= UInt64(packet[7]&4) << 34
            if clock&1 != 0 {
                let m = packet[8]
                output.put(UInt64((m&7)|((m&8)<<1)|((m&16)>>1)),5)
            }
            output.put(value,37)
            XCTAssertEqual(packet[7]&10,UInt8(((clock&1)<<3)|(clock&2)))
        }
        XCTAssertEqual(Array(output.bytes.prefix(input.count)),input)
        XCTAssertThrowsError(try USBProtocol.reports(input,syncKey:25))
    }
    func page(_ body: [UInt8], original: [UInt8], index: Int = 0, total: Int = 1, compression: UInt8 = 0, name: String = "DAT:TEST") throws -> ScreenshotPage {
        var bytes = [UInt8](repeating:0,count:60)
        func put(_ n:Int,_ offset:Int,_ count:Int) { bytes.replaceSubrange(offset..<offset+count,with:Codec.little(n,count)) }
        put(0x505a5332,0,4); put(original.count,4,4); put(Int(Codec.crc(original)),8,4)
        bytes.replaceSubrange(12..<12+name.utf8.count,with:name.utf8)
        bytes[48] = UInt8(total); bytes[49] = UInt8(index); bytes[50] = 0xa7; bytes[51] = compression
        put(body.count,52,4); put(720,56,2); put(720,58,2)
        bytes += body.map { $0 ^ 0xa7 }
        return try ScreenshotPage(stream:bytes)
    }
    func testSplitOrderDuplicatesAndMissing() throws {
        let original: [UInt8] = [1,2,3,4,5,6,7,8]
        let a = try page([1,2,3,4],original:original,total:2)
        let b = try page([5,6,7,8],original:original,index:1,total:2)
        XCTAssertEqual(try ScreenshotPage.assemble([b,a,a]),original)
        XCTAssertThrowsError(try ScreenshotPage.assemble([b]))
        let corrupt = try page([5,6,7,9],original:original,index:1,total:2)
        XCTAssertThrowsError(try ScreenshotPage.assemble([a,corrupt]))
        XCTAssertThrowsError(try ScreenshotPage.assemble([a,b,corrupt]))
        let other = try page([5,6,7,8],original:original,index:1,total:2,name:"DAT:OTHER")
        XCTAssertThrowsError(try ScreenshotPage.assemble([a,other]))
    }
    func testCompressedPage() throws {
        let bytes = [UInt8](repeating:65,count:33)
        XCTAssertEqual(try ScreenshotPage.assemble([page([0x82,0x02,0xf0,1],original:bytes,compression:1)]),bytes)
    }
    func testExportTextAndNoOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let text = "PRINT \"日本語\"\r\n", bytes = Array(text.data(using:.utf16LittleEndian)!)
        let p = try page(bytes,original:bytes,name:"TXT:HELLO")
        let first = try ScreenshotPage.export([p],directory:directory)
        let second = try ScreenshotPage.export([p],directory:directory)
        XCTAssertNotEqual(first,second)
        XCTAssertEqual(try String(contentsOf:first,encoding:.utf8),text)
    }
    func testPNGOrientationAndBGRA() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let pixels: [UInt8] = [0,0,255,255, 0,255,0,255, 255,0,0,255, 255,255,255,255]
        let data: [UInt8] = [2,0,2,0]+pixels
        let file = try ScreenshotPage.export([page(data,original:data,name:"GRP:COLORS")],directory:directory)
        let raster = try Raster.load(file)
        XCTAssertEqual(raster.width,2); XCTAssertEqual(raster.height,2)
        XCTAssertEqual(raster.bgra,pixels)
    }
    func testIndependentScreenshotFixtures() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let a = try ScreenshotPage.load(root.appendingPathComponent("page-1.png"))
        let b = try ScreenshotPage.load(root.appendingPathComponent("page-2.png"))
        XCTAssertEqual(a.index,0); XCTAssertEqual(b.index,1)
        XCTAssertEqual(try ScreenshotPage.assemble([b,a]),Array(try Data(contentsOf:root.appendingPathComponent("expected.bin"))))
    }
}
