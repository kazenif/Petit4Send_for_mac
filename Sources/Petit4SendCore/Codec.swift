import Foundation

public struct TransferError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum Codec {
    public static let maximumSize = 64 * 1024 * 1024
    public static func crc(_ bytes: [UInt8]) -> UInt16 {
        var c: UInt16 = 0xffff
        for b in bytes {
            c ^= UInt16(b)
            for _ in 0..<8 { c = (c >> 1) ^ ((c & 1) != 0 ? 0xc7ed : 0) }
        }
        return c ^ 0xffff
    }
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
        // Switch UNLZ consumes little-endian 32-bit words.
        var out = bits.bytes
        while out.count % 4 != 0 { out.append(0) }
        return out
    }
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
    public static func little(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0*8)) } }
    public static func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(bytes[offset+$1]) << ($1*8) }
    }
}
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
