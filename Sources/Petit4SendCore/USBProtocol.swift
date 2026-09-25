import Foundation

/// 圧縮の選び方。自動は LZSS 結果が元より短いときだけ圧縮する。
public enum Compression: String, CaseIterable { case auto = "自動", lzss = "LZSS", none = "無圧縮" }
/// ストリーム先頭の 4 バイト種別。TXT はテキスト、DAT は生バイト、GRP は画像。
public enum FileKind: String, CaseIterable {
    case text = "TXT:", data = "DAT:", graphics = "GRP:"
    /// ファイルを選んだ直後に使う種類。該当しない拡張子は nil で、今の設定を残す。
    /// 比較は大文字小文字を区別しない。
    public static func inferred(pathExtension: String) -> FileKind? {
        switch USBProtocol.asciiUppercased(pathExtension) {
        case "TXT", "PRG": return .text
        case "FONT", "DAT", "CMT", "D88", "BIN": return .data
        case "JPG", "PNG", "JPEG": return .graphics
        default: return nil
        }
    }
}

/// ファイル本体を P4SEND 1.2.2 の USB バイトストリームと HID レポートにする。
public enum USBProtocol {
    /// 非圧縮の元バイトから送信用ストリームを作る。多バイト整数はリトルエンディアン。
    ///
    /// 配置は次のとおり。
    /// - 0...15 は 0、16...65 は 1、66 は 0 の同期バイト
    /// - 67 から種別 4 バイトと、0 埋めした 32 バイトの ASCII 名
    /// - 103 に元のバイト数、107 / 109 に GRP の幅と高さ（それ以外は 0）
    /// - 111 が圧縮フラグ（0 が生、1 が LZSS）、112 が実際に送るペイロード長
    /// - 116 からペイロード、その直後に元バイトの CRC16、末尾に 16 バイトの 0
    ///
    /// TXT は BOM なし UTF-16LE、DAT は生バイト、GRP は寸法を本体に含まない行優先 BGRA。
    /// 名前は `:` `/` `\` を含まない半角 ASCII で 1...32 文字。
    /// `shouldCancel` は LZSS の途中で見る。準備中の中止であり、まだ Switch へは送っていない。
    public static func stream(bytes: [UInt8], name: String, kind: FileKind, compression: Compression, width: Int = 0, height: Int = 0, shouldCancel: () -> Bool = { false }) throws -> [UInt8] {
        guard bytes.count <= Codec.maximumSize else { throw TransferError("上限64 MiBを超えています。") }
        if let message = switchNameError(name) { throw TransferError(message) }
        let nameBytes = Array(asciiUppercased(name).utf8)
        let zipped = compression == .none ? [] : try Codec.compress(bytes, shouldCancel: shouldCancel)
        let useZip = compression == .lzss || (compression == .auto && zipped.count < bytes.count)
        let body = useZip ? zipped : bytes
        var out = [UInt8](repeating: 0, count: 16) + [UInt8](repeating: 1, count: 50) + [0]
        out += Array(kind.rawValue.utf8) + nameBytes + [UInt8](repeating: 0, count: 32-nameBytes.count)
        out += Codec.little(bytes.count, 4) + Codec.little(width, 2) + Codec.little(height, 2)
        out += [useZip ? 1 : 0] + Codec.little(body.count, 4) + body
        out += Codec.little(Int(Codec.crc(bytes)), 2) + [UInt8](repeating: 0, count: 16)
        return out
    }
    /// 組み合わせ C(n, k)。HID レポートの 36 ビットを 6 個のキー添字へ戻すときに使う。
    /// `n < k` は 0、`k == 0` は 1。
    static func choose(_ n: Int, _ k: Int) -> UInt64 {
        if n < k { return 0 }; if k == 0 { return 1 }
        return (1...k).reduce(UInt64(1)) { $0 * UInt64(n-$1+1) / UInt64($1) }
    }
    /// 送信前に見せる制約。満たせない名前では `switchNameError` が同じ文言を返す。
    public static let switchNameRule = "半角ASCII 1〜32文字（: / \\ は不可）"
    /// 大文字化したあと、空・33文字以上・半角ASCII以外・`:` `/` `\` なら送信できない理由を返す。
    public static func switchNameError(_ name: String) -> String? {
        let nameBytes = Array(asciiUppercased(name).utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 32, nameBytes.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 58 && $0 != 47 && $0 != 92 }) else {
            return "送信先名は半角ASCII 1〜32文字で指定してください（: / \\ は不可）。"
        }
        return nil
    }
    /// `a`...`z` だけを大文字にする。`String.uppercased()` はロケールによって `i` や `ß` を ASCII の外へ出す。
    public static func asciiUppercased(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if (97...122).contains(value), let upper = UnicodeScalar(value - 32) { scalars.append(upper) }
            else { scalars.append(scalar) }
        }
        return String(scalars)
    }
    /// テスト用に全レポートを配列へ展開する。本番の送信は `HIDReports` を直接走査する。
    public static func reports(_ stream: [UInt8], syncKey: Int = -1) throws -> [[UInt8]] {
        Array(try HIDReports(stream, syncKey: syncKey))
    }
}
/// バイトストリームを 12 バイトの HID レポートへ、必要な分だけ作る。
///
/// 数 MiB の転送でレポート配列を数百万個確保しないための `Sequence`。
/// コマンドバイトは Sync Key が自動（-1）なら 3、0...24 なら `2 + 4 * syncKey`。
/// 2 フレームで 79 ビット（37 + マウス 5 + 37）を運ぶ。端数は 0 埋め。
/// レポートの並びはコマンド、キーコード 6 個、修飾バイト、マウスボタン、0 が 3 バイト。
public struct HIDReports: Sequence {
    let stream: [UInt8]
    public let command: UInt8
    /// 79 ビットあたり 2 レポート。余りが 42 ビット以下なら 1 個、それを超えるなら 2 個足す。
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
        /// 残りのストリームから最大 `n` ビット取る。足りない分は 0 として末尾フレームを埋める。
        mutating func take(_ n: Int) -> UInt64 {
            let available = Swift.min(n, reader.bytes.count*8-reader.position)
            return available > 0 ? (try! reader.get(available)) : 0
        }
        public mutating func next() -> [UInt8]? {
            guard reader.position < reader.bytes.count*8 else { return nil }
            // 37 ビットのうち下位 36 ビットが「0...194 から異なる 6 個」の組み合わせ順位。
            // 残りの 1 ビット（ビット 36）は修飾バイトのビット 2 に載せる。
            let value = take(37)
            var remainder = value & 0xfffffffff, indices = [Int](repeating: 0, count: 6), upper = 194
            // 大きい添字から選ぶ組み合わせ番号系。キーは添字の降順になり、Windows 版と一致する。
            for k in stride(from: 6, through: 1, by: -1) {
                while USBProtocol.choose(upper,k) > remainder { upper -= 1 }
                indices[6-k] = upper; remainder -= USBProtocol.choose(upper,k); upper -= 1
            }
            var report = [UInt8](repeating: 0, count: 12)
            report[0] = command
            for i in 0..<6 { report[i+1] = keyCodes[indices[i]] }
            // ビット 3 はクロックの偶奇、ビット 1 はクロックのビット 1。ビット 2 は上の 37 ビット由来。
            report[7] = UInt8(((clock&1)<<3) | (clock&2)) | UInt8((value >> 34)&4)
            // 偶数フレームだけ次の 5 ビットをマウスボタンにし、続く奇数フレームでも同じ値を保持する。
            // ビット 3 と 4 は入れ替える。Switch は奇数クロックで、キーより先にこの保持値を読む。
            if clock&1 == 0 {
                let m = UInt8(take(5)); mouse = ((m&8)<<1) | ((m&16)>>1) | (m&7)
            }
            report[8] = mouse; clock += 1
            return report
        }
    }
}
