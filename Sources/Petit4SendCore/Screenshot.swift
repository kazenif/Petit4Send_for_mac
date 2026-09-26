import Foundation
import CoreGraphics
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
        let missing = missingPageNumbers(pages)
        guard missing.isEmpty else { throw TransferError("不足ページ: " + missing.map(String.init).joined(separator: ", ")) }
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
    /// 1 始まりの不足ページ番号。同じ番号が複数あっても、1 枚あれば不足にしない。
    /// 空の配列では空。呼び出し側は同一ファイルの組だけを渡す。
    public static func missingPageNumbers(_ pages: [ScreenshotPage]) -> [Int] {
        guard let total = pages.first?.total, total > 0 else { return [] }
        let present = Set(pages.map(\.index))
        return (0..<total).compactMap { present.contains($0) ? nil : $0 + 1 }
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

/// Finder からのドロップと「画像を追加…」で読むファイルの振り分け。
/// PNG / JPEG / BMP / TIFF だけを受け、フォルダは直下のその種類だけを足す。
public enum RestoreImages {
    public static func batch(from urls: [URL]) -> (images: [URL], rejected: [URL]) {
        var images: [URL] = []
        var rejected: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                let files = children.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let found = files.filter(isImage)
                if found.isEmpty { rejected.append(url) } else { images.append(contentsOf: found) }
            } else if isImage(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                images.append(url)
            } else {
                rejected.append(url)
            }
        }
        return (images, rejected)
    }
    /// 拡張子の大文字小文字は問わない。
    public static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.png, .jpeg, .bmp, .tiff].contains { type.conforms(to: $0) }
    }
}

/// 直線（プリマルチプライされていない）RGBA。
/// GRP のアルファを落とさないため、色管理を通さず 8bit の成分をそのまま読む。
public struct Raster {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]
    public static func load(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw TransferError("画像を読み込めません（最大16Mピクセル）。") }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw TransferError("画像を読み込めません（最大16Mピクセル）。") }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= Codec.maximumSize / 4, height <= (Codec.maximumSize / 4) / width else { throw TransferError("画像を読み込めません（最大16Mピクセル）。") }
        let pixels = try straightRGBA(image)
        guard pixels.count == width * height * 4 else { throw TransferError("画像を読み込めません（最大16Mピクセル）。") }
        return Raster(width: width, height: height, rgba: pixels)
    }
    /// 8bit の RGB(A) ならデータプロバイダのバイト列を RGBA に並べる。それ以外は同じ色空間へ描く。
    private static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        if let copied = copyStraightPixels(image) { return copied }
        return try drawStraightPixels(image)
    }
    private static func copyStraightPixels(_ image: CGImage) -> [UInt8]? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 24 || image.bitsPerPixel == 32,
              let provider = image.dataProvider, let data = provider.data as Data? else { return nil }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        if order == .byteOrder16Little || order == .byteOrder16Big { return nil }
        let alpha = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
        if alpha == .alphaOnly { return nil }
        let width = image.width, height = image.height, bytesPerPixel = image.bitsPerPixel / 8
        let rowBytes = image.bytesPerRow == 0 ? width * bytesPerPixel : image.bytesPerRow
        guard data.count >= rowBytes * (height - 1) + width * bytesPerPixel else { return nil }
        let little = order == .byteOrder32Little
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let sample = base.advanced(by: y * rowBytes + x * bytesPerPixel)
                    let (r, g, b, a) = components(sample, bytesPerPixel: bytesPerPixel, alpha: alpha, little: little)
                    let destination = (y * width + x) * 4
                    if a == 0 || a == 255 || !isPremultiplied(alpha) {
                        pixels[destination] = a == 0 ? 0 : r
                        pixels[destination + 1] = a == 0 ? 0 : g
                        pixels[destination + 2] = a == 0 ? 0 : b
                    } else {
                        pixels[destination] = UInt8(min(255, Int(r) * 255 / Int(a)))
                        pixels[destination + 1] = UInt8(min(255, Int(g) * 255 / Int(a)))
                        pixels[destination + 2] = UInt8(min(255, Int(b) * 255 / Int(a)))
                    }
                    pixels[destination + 3] = a
                }
            }
        }
        return pixels
    }
    private static func components(_ sample: UnsafePointer<UInt8>, bytesPerPixel: Int, alpha: CGImageAlphaInfo, little: Bool) -> (UInt8, UInt8, UInt8, UInt8) {
        if bytesPerPixel == 3 { return (sample[0], sample[1], sample[2], 255) }
        let red, green, blue, alphaIndex: Int
        switch alpha {
        case .premultipliedFirst, .first, .noneSkipFirst:
            (red, green, blue, alphaIndex) = (1, 2, 3, 0)
        default:
            (red, green, blue, alphaIndex) = (0, 1, 2, 3)
        }
        func at(_ index: Int) -> UInt8 { sample[little ? 3 - index : index] }
        let alphaByte: UInt8
        switch alpha {
        case .none, .noneSkipFirst, .noneSkipLast: alphaByte = 255
        default: alphaByte = at(alphaIndex)
        }
        return (at(red), at(green), at(blue), alphaByte)
    }
    private static func isPremultiplied(_ alpha: CGImageAlphaInfo) -> Bool {
        alpha == .premultipliedFirst || alpha == .premultipliedLast
    }
    /// 画像自身の色空間へ 8bit RGBA で描く。失敗したときだけ sRGB へ落とす。
    private static func drawStraightPixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let spaces = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            for space in spaces {
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return false
        }
        guard drew else { throw TransferError("画像を読み込めません（最大16Mピクセル）。") }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha == 0 { pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0 }
            else if alpha < 255 {
                pixels[offset] = UInt8(min(255, Int(pixels[offset]) * 255 / alpha))
                pixels[offset + 1] = UInt8(min(255, Int(pixels[offset + 1]) * 255 / alpha))
                pixels[offset + 2] = UInt8(min(255, Int(pixels[offset + 2]) * 255 / alpha))
            }
        }
        return pixels
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
