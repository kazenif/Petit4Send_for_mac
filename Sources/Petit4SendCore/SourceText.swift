import Foundation

/// TXT を送信用の BOM なし UTF-16LE にする。
///
/// 判定は次の順。先に当たったものを使い、UTF-8 として読めたバイト列をシフトJISにはしない。
/// 1. BOM 付き UTF-16（LE / BE）
/// 2. UTF-8（BOM があれば外す）
/// 3. シフトJIS（Mac の `shiftJIS` は日本語 Windows の CP932）
///
/// 改行はそのまま残す。空かどうかは送信側が見る。
public enum SourceText {
    public static func utf16LE(from data: Data) throws -> [UInt8] {
        let text = try decode(data)
        guard let encoded = text.data(using: .utf16LittleEndian) else { throw TransferError("UTF-16LEへ変換できません。") }
        return Array(encoded)
    }
    private static func decode(_ data: Data) throws -> String {
        let decoded: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            decoded = String(data: data, encoding: .utf16)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            decoded = utf8
        } else {
            decoded = String(data: data, encoding: .shiftJIS)
        }
        guard var text = decoded else { throw TransferError("TXTはUTF-8、BOM付きUTF-16、またはシフトJISで保存してください。") }
        if text.first == "\u{feff}" { text.removeFirst() }
        return text
    }
}
