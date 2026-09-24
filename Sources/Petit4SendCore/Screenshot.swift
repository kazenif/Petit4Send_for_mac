import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Switch の SCREENSHOT SEND が画像へ埋め込んだ 1 ページ。
///
/// 1280×720 の左 720×720（または最初から 720×720）を列優先で、縦 5 画素ずつ読む。
/// 緑成分を閾値 22, 64, 107, 149, 191, 234 で 0〜6 に量子化し、
/// 5 桁の 7 進数（下位桁が上の画素）の下位 14 ビットを LSB ファーストで連結する。
/// ヘッダー 60 バイトとペイロードは同じビット列で、境界にパディングはない。
/// 1 ページのペイロード上限は 181380 バイト（720×720×14÷5÷8 − 60）。
public struct ScreenshotPage {
    public let name: String
    public let fileSize: Int
    public let crc: UInt16
    public let total: Int
    public let index: Int
    public let compression: UInt8
    public let payload: [UInt8]
    /// 同一ファイルのページをまとめるキー。名前・サイズ・CRC・枚数・圧縮が一致するものだけ結合する。
    public var groupKey: String { "\(name)|\(fileSize)|\(crc)|\(total)|\(compression)" }
    /// 復元したビット列からヘッダーを読む。ペイロードは byte 50 のマスクで XOR を戻す。
    /// 種別は `TXT:` `DAT:` `GRP:` のいずれか。マジックは ASCII の `PZS2`（`0x505A5332`）。
    public init(stream: [UInt8]) throws {
        guard stream.count >= 60, Codec.integer(stream, 0, 4) == 0x505a5332 else { throw TransferError("P4SENDの画像ヘッダーが見つかりません。原寸のスクリーンショットを選択してください。") }
        fileSize = Codec.integer(stream, 4, 4)
        guard fileSize <= Codec.maximumSize, Codec.integer(stream, 8, 4) <= 65535 else { throw TransferError("画像ヘッダーが破損しています。") }
        crc = UInt16(Codec.integer(stream, 8, 4))
        let filename = Array(stream[12..<48].prefix { $0 != 0 })
        guard let decoded = String(bytes: filename, encoding: .ascii), decoded.count > 4,
              ["TXT:", "DAT:", "GRP:"].contains(String(decoded.prefix(4))) else { throw TransferError("画像のファイル名または種類が不正です。") }
        name = decoded
        total = Int(stream[48]); index = Int(stream[49]); compression = stream[51]
        let length = Codec.integer(stream, 52, 4)
        guard total > 0, index < total, compression <= 1, length <= 181380, length+60 <= stream.count,
              Codec.integer(stream, 56, 2) == 720, Codec.integer(stream, 58, 2) == 720 else { throw TransferError("ページ番号・画像サイズ・データ長が不正です。") }
        payload = stream[60..<60+length].map { $0 ^ stream[50] }
    }
    /// 画像をビット列へ戻して 1 ページにする。幅は 1280 または 720、高さは 720。
    /// 1280 幅のときは左 720 列だけを使い、右側の黒などは読まない。
    public static func load(_ url: URL) throws -> ScreenshotPage {
        let bitmap = try Raster.load(url)
        guard bitmap.width == 1280 && bitmap.height == 720 || bitmap.width == 720 && bitmap.height == 720 else { throw TransferError("画像は1280×720（または左側を切り出した720×720）の原寸が必要です。") }
        var writer = BitWriter()
        // 列を左から、各列は上から 5 画素。digit はその画素が超えた閾値の個数（0...6）。
        for x in 0..<720 {
            for y in stride(from: 0, to: 720, by: 5) {
                var value = 0, multiplier = 1
                for i in 0..<5 {
                    let g = bitmap.rgba[((y+i)*bitmap.width+x)*4+1]
                    let digit = [22,64,107,149,191,234].filter { Int(g) >= $0 }.count
                    value += digit*multiplier; multiplier *= 7
                }
                writer.put(UInt64(value & 0x3fff),14)
            }
        }
        return try ScreenshotPage(stream: writer.bytes)
    }
    /// ページを番号順に結合し、必要なら LZSS を展開して CRC を確かめる。
    ///
    /// 順不同と、内容が同じ重複ページは受け入れる。欠落、同一番号で内容が違うページ、
    /// 別ファイルの混在は拒否する。無圧縮で元サイズが 4 の倍数でないとき、BASIC は
    /// 32 ビット語の途中を書き落とすことがある。その場合はバイトを補わず、長さまたは CRC のエラーにする。
    public static func assemble(_ pages: [ScreenshotPage]) throws -> [UInt8] {
        guard let first = pages.first else { throw TransferError("画像が選択されていません。") }
        guard pages.allSatisfy({ $0.groupKey == first.groupKey }) else { throw TransferError("異なるファイルの画像が混在しています。") }
        var byIndex: [Int: ScreenshotPage] = [:]
        for page in pages {
            if let previous = byIndex[page.index], previous.payload != page.payload { throw TransferError("同じページ番号の内容が一致しません。") }
            byIndex[page.index] = page
        }
        let missing = (0..<first.total).filter { byIndex[$0] == nil }
        guard missing.isEmpty else { throw TransferError("不足ページ: " + missing.map { String($0+1) }.joined(separator: ", ")) }
        let stream = (0..<first.total).flatMap { byIndex[$0]!.payload }
        let bytes: [UInt8]
        if first.compression == 1 { bytes = try Codec.decompress(stream, size: first.fileSize) }
        else {
            guard stream.count >= first.fileSize else { throw TransferError("復元データがファイルサイズに足りません。") }
            bytes = Array(stream.prefix(first.fileSize))
        }
        guard Codec.crc(bytes) == first.crc else { throw TransferError("CRC不一致: 画像が劣化しているか、別の転送の画像が混在しています。保存を中止しました。") }
        return bytes
    }
    /// 種類に応じて書き出す。TXT は UTF-16LE を UTF-8 に、GRP は BGRA を PNG に、DAT はそのまま。
    ///
    /// ファイル名は種別 4 文字の後ろを使い、`/` `\` `:` と制御文字は `_` にする。
    /// 同名があれば ` (n)` を付け、既存ファイルは上書きしない。
    /// スクリーンショット由来の GRP は、USB の GRP と違い先頭 4 バイトが幅と高さ。
    public static func export(_ pages: [ScreenshotPage], directory: URL) throws -> URL {
        let bytes = try assemble(pages), name = pages[0].name
        var filename = String(name.dropFirst(4))
        filename = filename.map { "/\\:".contains($0) || $0.asciiValue.map({$0 < 32}) == true ? "_" : $0 }.reduce("") { $0 + String($1) }
        if filename == "." || filename == ".." || filename.isEmpty { filename = "RECEIVED" }
        let result: Data
        switch name.prefix(4) {
        case "TXT:":
            guard bytes.count % 2 == 0, let text = String(data: Data(bytes), encoding: .utf16LittleEndian) else { throw TransferError("UTF-16テキストが不正です。") }
            result = Data(text.utf8)
        case "GRP:":
            guard bytes.count >= 4 else { throw TransferError("GRPヘッダーが不足しています。") }
            let w = Codec.integer(bytes,0,2), h = Codec.integer(bytes,2,2)
            guard w > 0, h > 0, w*h*4 == bytes.count-4 else { throw TransferError("GRPのサイズが一致しません。") }
            var rgba = Array(bytes.dropFirst(4))
            // プチコンの並びは BGRA。PNG に出す前に R と B を入れ替える。
            for p in stride(from:0,to:rgba.count,by:4) { rgba.swapAt(p,p+2) }
            result = try Raster(width:w,height:h,rgba:rgba).png()
            filename += ".png"
        default: result = Data(bytes)
        }
        let base = directory.appendingPathComponent(filename)
        for suffix in 0...9999 {
            let destination = suffix == 0 ? base : directory.appendingPathComponent("\(base.deletingPathExtension().lastPathComponent) (\(suffix))" + (base.pathExtension.isEmpty ? "" : ".\(base.pathExtension)"))
            do { try result.write(to: destination, options: .withoutOverwriting); return destination }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
        }
        throw TransferError("保存先に同名ファイルが多すぎます。")
    }
}

/// 直線（プリマルチプライされていない）RGBA。
/// GRP のアルファを落とさないため、`CGImage` の乗算済みバッファではなく色成分を直接読む。
public struct Raster {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]
    public static func load(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width > 0, image.height > 0, image.width*image.height <= Codec.maximumSize/4 else { throw TransferError("画像を読み込めません（最大16Mピクセル）。") }
        // NSBitmapImageRep は乗算前の成分を返すので、GRP のアルファを保てる。
        let rep = NSBitmapImageRep(cgImage: image)
        var pixels = [UInt8](repeating:0,count:image.width*image.height*4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let original = rep.colorAt(x:x,y:y), let c = original.colorSpace.colorSpaceModel == .rgb ? original : original.usingColorSpace(.sRGB) else { throw TransferError("画像の色空間を変換できません。") }
                let p = (y*image.width+x)*4
                pixels[p] = UInt8(clamping: Int((c.redComponent*255).rounded()))
                pixels[p+1] = UInt8(clamping: Int((c.greenComponent*255).rounded()))
                pixels[p+2] = UInt8(clamping: Int((c.blueComponent*255).rounded()))
                pixels[p+3] = UInt8(clamping: Int((c.alphaComponent*255).rounded()))
            }
        }
        return Raster(width:image.width,height:image.height,rgba:pixels)
    }
    /// sRGB・非プリマルチプライの RGBA を PNG にする。補間はしない。
    public func png() throws -> Data {
        guard let provider = CGDataProvider(data:Data(rgba) as CFData), let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw TransferError("PNG画像を作成できません。") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString,1,nil) else { throw TransferError("PNG保存に失敗しました。") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw TransferError("PNG保存に失敗しました。") }
        return data as Data
    }
    /// USB 送信用。RGBA の R と B を入れ、行優先 BGRA にする。
    public var bgra: [UInt8] {
        var bytes = rgba
        for i in stride(from:0,to:bytes.count,by:4) { bytes.swapAt(i,i+2) }
        return bytes
    }
}
