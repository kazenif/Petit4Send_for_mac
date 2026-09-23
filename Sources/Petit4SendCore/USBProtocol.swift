import Foundation
public enum Compression: String, CaseIterable { case auto = "自動", lzss = "LZSS", none = "無圧縮" }
public enum FileKind: String, CaseIterable { case text = "TXT:", data = "DAT:", graphics = "GRP:" }
public enum USBProtocol {
    public static func stream(bytes: [UInt8], name: String, kind: FileKind, compression: Compression, width: Int = 0, height: Int = 0) throws -> [UInt8] {
        guard bytes.count <= Codec.maximumSize else { throw TransferError("上限64 MiBを超えています。") }
        let nameBytes = Array(name.uppercased().utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 32, nameBytes.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 58 && $0 != 47 && $0 != 92 }) else { throw TransferError("送信先名は半角ASCII 1〜32文字で指定してください（: / \\ は不可）。") }
        let zipped = compression == .none ? [] : Codec.compress(bytes)
        let useZip = compression == .lzss || (compression == .auto && zipped.count < bytes.count)
        let body = useZip ? zipped : bytes
        var out = [UInt8](repeating: 0, count: 16) + [UInt8](repeating: 1, count: 50) + [0]
        out += Array(kind.rawValue.utf8) + nameBytes + [UInt8](repeating: 0, count: 32-nameBytes.count)
        out += Codec.little(bytes.count, 4) + Codec.little(width, 2) + Codec.little(height, 2)
        out += [useZip ? 1 : 0] + Codec.little(body.count, 4) + body
        out += Codec.little(Int(Codec.crc(bytes)), 2) + [UInt8](repeating: 0, count: 16)
        return out
    }
    static func choose(_ n: Int, _ k: Int) -> UInt64 {
        if n < k { return 0 }; if k == 0 { return 1 }
        return (1...k).reduce(UInt64(1)) { $0 * UInt64(n-$1+1) / UInt64($1) }
    }
    public static func reports(_ stream: [UInt8], syncKey: Int = -1) throws -> [[UInt8]] {
        Array(try HIDReports(stream, syncKey: syncKey))
    }
}
/// Builds packets lazily so multi-megabyte transfers do not allocate millions of arrays.
public struct HIDReports: Sequence {
    let stream: [UInt8]
    public let command: UInt8
    public var count: Int { let bits = stream.count*8; return bits/79*2 + (bits%79 == 0 ? 0 : bits%79 <= 42 ? 1 : 2) }
    public init(_ stream: [UInt8], syncKey: Int = -1) throws {
        guard (-1...24).contains(syncKey) else { throw TransferError("Sync Keyは-1〜24です。") }
        self.stream = stream; command = syncKey < 0 ? 3 : UInt8(2+syncKey*4)
    }
    public func makeIterator() -> Iterator { Iterator(reader: BitReader(stream), command: command) }
    public struct Iterator: IteratorProtocol {
        var reader: BitReader
        let command: UInt8
        var clock = 0
        var mouse: UInt8 = 0
        mutating func take(_ n: Int) -> UInt64 {
            let available = Swift.min(n, reader.bytes.count*8-reader.position)
            return available > 0 ? (try! reader.get(available)) : 0
        }
        public mutating func next() -> [UInt8]? {
            guard reader.position < reader.bytes.count*8 else { return nil }
            let value = take(37)
            var remainder = value & 0xfffffffff, indices = [Int](repeating: 0, count: 6), upper = 194
            for k in stride(from: 6, through: 1, by: -1) {
                while USBProtocol.choose(upper,k) > remainder { upper -= 1 }
                indices[6-k] = upper; remainder -= USBProtocol.choose(upper,k); upper -= 1
            }
            var report = [UInt8](repeating: 0, count: 12)
            report[0] = command
            for i in 0..<6 { report[i+1] = keyCodes[indices[i]] }
            report[7] = UInt8(((clock&1)<<3) | (clock&2)) | UInt8((value >> 34)&4)
            if clock&1 == 0 {
                let m = UInt8(take(5)); mouse = ((m&8)<<1) | ((m&16)>>1) | (m&7)
            }
            report[8] = mouse; clock += 1
            return report
        }
    }
}
