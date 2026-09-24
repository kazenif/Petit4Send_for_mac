import XCTest
@testable import Petit4SendCore

/// CRC、LZSS、USB ヘッダー、HID レポート、スクリーンショット復元の契約を固定する。
final class ProtocolTests: XCTestCase {
    /// CRC-16/KOOPMAN。反射多項式 `0xC7ED`、初期値と終端 XOR は `0xFFFF`。
    /// `"123456789"` は `0x0B3A`。空入力は 0。別種の CRC-16 に替わるとここが落ちる。
    func testCRCReference() {
        XCTAssertEqual(Codec.crc(Array("123456789".utf8)), 0x0b3a)
        XCTAssertEqual(Codec.crc([]),0)
    }
    /// 手で詰めたトークン。リテラル `A`（フラグ 0 + `0x41`）のあと、距離 1・長さ 32 の参照。
    /// 参照はリング上で重なってよい。33 バイトすべて `A` になる。
    func testLZLiteralAndOverlappingReference() throws {
        let decoded = try Codec.decompress([0x82,0x02,0xf0,0x01],size:33)
        XCTAssertEqual(decoded,[UInt8](repeating:65,count:33))
    }
    /// 圧縮結果は 4 バイト境界まで埋まり、元の長さで止めるとパディングは内容に含まれない。
    func testCompressionRoundTrip() throws {
        var random: UInt32 = 1234
        let noise: [UInt8] = (0..<5000).map { _ in random = random &* 1664525 &+ 1013904223; return UInt8(truncatingIfNeeded:random >> 16) }
        let cases = [[], [0], [255], Array("日本語\nPRINT 123\r\n".utf8), [UInt8](repeating:42,count:5000), noise, noise+noise]
        for bytes in cases {
            let compressed = try Codec.compress(bytes)
            XCTAssertEqual(compressed.count%4,0)
            XCTAssertEqual(try Codec.decompress(compressed,size:bytes.count),bytes)
        }
    }
    /// ビットが途中で切れた列と、64 MiB を超える展開長は拒否する。
    func testMalformedLZ() {
        XCTAssertThrowsError(try Codec.decompress([],size:1))
        XCTAssertThrowsError(try Codec.decompress([1],size:1))
        XCTAssertThrowsError(try Codec.decompress([],size:Codec.maximumSize+1))
        XCTAssertThrowsError(try Codec.compress([1,2,3,4], shouldCancel: { true }))
    }
    /// 無圧縮 TXT のヘッダー位置。名前に非 ASCII は使えない。
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
        let lower = try USBProtocol.stream(bytes:bytes,name:"i",kind:.text,compression:.none)
        XCTAssertEqual(String(bytes:lower[67..<72],encoding:.ascii),"TXT:I")
        XCTAssertThrowsError(try USBProtocol.stream(bytes:bytes,name:"ß",kind:.text,compression:.none))
    }
    /// P4SEND122.PRG の `@RECEIVE` と同じ組み合わせ和でビット列を戻す。
    /// Sync Key 12 のコマンドは `2 + 4 * 12 = 50`。範囲外の Sync Key は拒否する。
    func testHIDReportsAgainstSwitchReceiver() throws {
        let input = (0..<1000).map { UInt8(truncatingIfNeeded:$0*37) }
        let packets = try USBProtocol.reports(input,syncKey:12)
        var output = BitWriter()
        for (clock,packet) in packets.enumerated() {
            XCTAssertEqual(packet.count,12); XCTAssertEqual(packet[0],50)
            let indices = packet[1...6].map { keyCodes.firstIndex(of:$0)! }.sorted()
            XCTAssertEqual(Set(indices).count,6)
            var value: UInt64 = 0
            // 送信側は添字の降順で並べる。受信側は昇順に C(添字, 順位) を足し直す。
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
    /// テスト用の 1 ページ。ペイロードはマスク `0xA7` で XOR してからヘッダーの後ろに続ける。
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
    /// 順不同と内容が同じ重複は許容する。欠落、同一番号の不一致、別ファイルの混在は拒否する。
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
    /// 圧縮フラグ 1 のページは結合後に LZSS 展開する。
    func testCompressedPage() throws {
        let bytes = [UInt8](repeating:65,count:33)
        XCTAssertEqual(try ScreenshotPage.assemble([page([0x82,0x02,0xf0,1],original:bytes,compression:1)]),bytes)
    }
    /// TXT は UTF-8 で書く。同名があれば連番の別ファイルにし、既存は上書きしない。
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
    /// GRP は幅・高さ 4 バイトのあとに BGRA。保存した PNG を読み戻すと元の BGRA になる。
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
    /// 別経路で作った 2 ページの画像を逆順に結合し、期待バイナリと一致することを確認する。
    func testIndependentScreenshotFixtures() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let a = try ScreenshotPage.load(root.appendingPathComponent("page-1.png"))
        let b = try ScreenshotPage.load(root.appendingPathComponent("page-2.png"))
        XCTAssertEqual(a.index,0); XCTAssertEqual(b.index,1)
        XCTAssertEqual(try ScreenshotPage.assemble([b,a]),Array(try Data(contentsOf:root.appendingPathComponent("expected.bin"))))
    }
}
