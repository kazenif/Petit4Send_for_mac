import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public struct ScreenshotPage {
    public let name: String
    public let fileSize: Int
    public let crc: UInt16
    public let total: Int
    public let index: Int
    public let compression: UInt8
    public let payload: [UInt8]
    public var groupKey: String { "\(name)|\(fileSize)|\(crc)|\(total)|\(compression)" }
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
    public static func load(_ url: URL) throws -> ScreenshotPage {
        let bitmap = try Raster.load(url)
        guard bitmap.width == 1280 && bitmap.height == 720 || bitmap.width == 720 && bitmap.height == 720 else { throw TransferError("画像は1280×720（または左側を切り出した720×720）の原寸が必要です。") }
        var writer = BitWriter()
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

public struct Raster {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8]
    public static func load(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width > 0, image.height > 0, image.width*image.height <= Codec.maximumSize/4 else { throw TransferError("画像を読み込めません（最大16Mピクセル）。") }
        // NSBitmapImageRep reads straight (unpremultiplied) components, retaining GRP alpha.
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
    public func png() throws -> Data {
        guard let provider = CGDataProvider(data:Data(rgba) as CFData), let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw TransferError("PNG画像を作成できません。") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString,1,nil) else { throw TransferError("PNG保存に失敗しました。") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw TransferError("PNG保存に失敗しました。") }
        return data as Data
    }
    public var bgra: [UInt8] {
        var bytes = rgba
        for i in stride(from:0,to:bytes.count,by:4) { bytes.swapAt(i,i+2) }
        return bytes
    }
}
