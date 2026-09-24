import Foundation

/// 利用者に見せる失敗。メッセージはそのまま UI の状態欄へ出す。
public struct TransferError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// P4SEND 1.2.2 の CRC と LZSS。多バイト整数はリトルエンディアン。
public enum Codec {
    /// 送受信とも 64 MiB を超える本体は扱わない。
    public static let maximumSize = 64 * 1024 * 1024
    /// CRC-16/KOOPMAN。反射多項式 `0xC7ED`、初期値と終端 XOR は `0xFFFF`。
    ///
    /// BASIC の `CALC_CRCTBL` / `CALC_CRC` と同じ計算で、名前が似た別種の CRC-16 には替えられない。
    /// `"123456789"` は `0x0B3A`、空入力は 0。対象は圧縮前の元バイト。
    public static func crc(_ bytes: [UInt8]) -> UInt16 {
        var c: UInt16 = 0xffff
        for b in bytes {
            c ^= UInt16(b)
            for _ in 0..<8 { c = (c >> 1) ^ ((c & 1) != 0 ? 0xc7ed : 0) }
        }
        return c ^ 0xffff
    }
    /// LSB ファーストの LZSS。一致は 3...32 バイト、距離は最大 1024。
    ///
    /// フラグ 0 のあとにリテラル 8 ビット、フラグ 1 のあとに「距離−1」10 ビットと「長さ−1」5 ビット。
    /// 履歴は 0 で初期化した 1024 バイトのリングで、参照は自身と重なってよい。
    /// 3 バイトのハッシュ鎖で候補を探す。Switch の UNLZ が 32 ビット語で読むため、出力は 4 バイト境界まで 0 で埋める。
    public static func compress(_ input: [UInt8]) -> [UInt8] {
        var bits = BitWriter(), pos = 0
        var heads: [Int: Int] = [:]
        var previous = [Int](repeating: -1, count: 1024)
        func hash(_ p: Int) -> Int { Int(input[p]) << 16 | Int(input[p+1]) << 8 | Int(input[p+2]) }
        while pos < input.count {
            var length = 0, distance = 0
            if pos + 2 < input.count {
                let key = hash(pos)
                var start = heads[key] ?? -1
                while start >= 0 && pos-start <= 1024 {
                    var n = 0
                    while n < 32 && pos+n < input.count && input[start+n] == input[pos+n] { n += 1 }
                    if n > length { length = n; distance = pos-start }
                    if length == 32 { break }
                    start = previous[start & 1023]
                }
            }
            let advance: Int
            if length >= 3 {
                bits.put(1, 1); bits.put(UInt64(distance-1), 10); bits.put(UInt64(length-1), 5)
                advance = length
            } else { bits.put(0, 1); bits.put(UInt64(input[pos]), 8); advance = 1 }
            for p in pos..<pos+advance where p+2 < input.count {
                let key = hash(p)
                previous[p & 1023] = heads[key] ?? -1
                heads[key] = p
            }
            pos += advance
        }
        // Switch の UNLZ はリトルエンディアンの 32 ビット語で読む。端数は 0 で埋める。
        var out = bits.bytes
        while out.count % 4 != 0 { out.append(0) }
        return out
    }
    /// `size` バイトに達したところで止める。4 バイト境界のパディングはファイル内容に含めない。
    /// 参照が `size` を超えて続いても、窓の更新は最後まで行い、出力だけ打ち切る。
    public static func decompress(_ input: [UInt8], size: Int) throws -> [UInt8] {
        guard (0...maximumSize).contains(size) else { throw TransferError("ファイルサイズが上限64 MiBを超えています。") }
        var bits = BitReader(input), out: [UInt8] = [], window = [UInt8](repeating: 0, count: 1024), cursor = 0
        out.reserveCapacity(size)
        while out.count < size {
            let flag = try bits.get(1)
            if flag == 0 {
                let b = UInt8(try bits.get(8)); out.append(b); window[cursor] = b; cursor = (cursor+1)&1023
            } else {
                let distance = Int(try bits.get(10))+1, length = Int(try bits.get(5))+1
                for _ in 0..<length {
                    let b = window[(cursor-distance+1024)&1023]
                    if out.count < size { out.append(b) }
                    window[cursor] = b; cursor = (cursor+1)&1023
                }
            }
        }
        return out
    }
    /// `value` の下位 `count` バイトをリトルエンディアンで並べる。
    public static func little(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0*8)) } }
    /// `offset` から `count` バイトをリトルエンディアン整数として読む。
    public static func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(bytes[offset+$1]) << ($1*8) }
    }
}
/// LSB を先に詰めるビット列。バイト内も下位ビットから埋める。
struct BitWriter {
    var bytes: [UInt8] = []; var position = 0
    mutating func put(_ value: UInt64, _ count: Int) {
        for i in 0..<count {
            if position % 8 == 0 { bytes.append(0) }
            bytes[position/8] |= UInt8((value >> i)&1) << (position%8)
            position += 1
        }
    }
}
/// `BitWriter` と同じ順でビットを取り出す。途中でビットが尽きればエラーにする。
struct BitReader {
    let bytes: [UInt8]; var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    mutating func get(_ count: Int) throws -> UInt64 {
        guard position + count <= bytes.count*8 else { throw TransferError("圧縮データが途中で切れています。") }
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64((bytes[position/8] >> (position%8))&1) << i; position += 1 }
        return value
    }
}
