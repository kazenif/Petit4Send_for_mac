// アイコン原画から、非可逆圧縮のノイズを除く。
//
// icon-candidate.png は平坦な色のドット絵を約 198px に描いたもので、非可逆圧縮を
// 通っている。色は 6859 種に割れ、縁にはリンギングがあり、白い余白に暗い点がある。
// 意図した少ないパレットへ戻し、余白を透明にして macOS のアイコンとして使えるようにする。
//
// キャンバスサイズを渡すと拡大もする。絵は整数倍で複製してドットの縁を直角に保ち、
// 外形のアルファだけ出力解像度で評価して、外縁は滑らかにする。
//
// 使い方: swift Tools/clean-icon.swift <input.png> <output.png> [canvas]

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else {
    FileHandle.standardError.write(
        Data("usage: clean-icon.swift <input.png> <output.png> [canvas]\n".utf8))
    exit(2)
}
let inputPath = args[1], outputPath = args[2]
let canvas = args.count == 4 ? Int(args[3]) : nil
if args.count == 4 && canvas == nil {
    FileHandle.standardError.write(Data("canvas must be an integer\n".utf8))
    exit(2)
}

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(inputPath)\n".utf8))
    exit(1)
}
let w = image.width, h = image.height
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

var raw = [UInt8](repeating: 0, count: w * h * 4)
raw.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}

struct Color {
    var r: Double, g: Double, b: Double
    static func += (l: inout Color, r: Color) { l.r += r.r; l.g += r.g; l.b += r.b }
    func scaled(_ f: Double) -> Color { Color(r: r * f, g: g * f, b: b * f) }
    func dist2(_ o: Color) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return dr * dr + dg * dg + db * db
    }
}

var pixels = [Color](repeating: Color(r: 0, g: 0, b: 0), count: w * h)
for i in 0..<(w * h) {
    pixels[i] = Color(r: Double(raw[i * 4]), g: Double(raw[i * 4 + 1]), b: Double(raw[i * 4 + 2]))
}
func at(_ buf: [Color], _ x: Int, _ y: Int) -> Color {
    buf[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
}

// 手順 1: チャンネルごとの 3×3 中央値で、圧縮のリンギングを落とす。
// 平坦な領域と直線の縁はそのまま残る。
var smoothed = pixels
for y in 0..<h {
    for x in 0..<w {
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let c = at(pixels, x + dx, y + dy)
                rs.append(c.r); gs.append(c.g); bs.append(c.b)
            }
        }
        rs.sort(); gs.sort(); bs.sort()
        smoothed[y * w + x] = Color(r: rs[4], g: gs[4], b: bs[4])
    }
}

// 手順 2: k-means で意図したパレットを取り戻す。種は粗く量子化した色の出現順で、
// クラスタが最初から離れるようにする。20 個にすると、工具箱の暗い陰影と
// オリーブ色の持ち手が別色のまま残る。
let k = 20
var seedCounts: [Int: Int] = [:]
for c in smoothed {
    let key = (Int(c.r) >> 4) << 8 | (Int(c.g) >> 4) << 4 | (Int(c.b) >> 4)
    seedCounts[key, default: 0] += 1
}
var centroids: [Color] = seedCounts.sorted { $0.value > $1.value }.prefix(k).map { entry in
    Color(r: Double((entry.key >> 8) & 0xF) * 16 + 8,
          g: Double((entry.key >> 4) & 0xF) * 16 + 8,
          b: Double(entry.key & 0xF) * 16 + 8)
}
var assignment = [Int](repeating: 0, count: w * h)
for _ in 0..<30 {
    var sums = [Color](repeating: Color(r: 0, g: 0, b: 0), count: centroids.count)
    var counts = [Int](repeating: 0, count: centroids.count)
    for i in 0..<(w * h) {
        var bestJ = 0, bestD = Double.infinity
        for (j, c) in centroids.enumerated() {
            let d = smoothed[i].dist2(c)
            if d < bestD { bestD = d; bestJ = j }
        }
        assignment[i] = bestJ
        sums[bestJ] += smoothed[i]
        counts[bestJ] += 1
    }
    for j in 0..<centroids.count where counts[j] > 0 {
        centroids[j] = sums[j].scaled(1 / Double(counts[j]))
    }
}
var quantised = [Color](repeating: Color(r: 0, g: 0, b: 0), count: w * h)
for i in 0..<(w * h) { quantised[i] = centroids[assignment[i]] }

// 手順 3: まだらを落とす。近傍にほとんど出てこないパレット番号は、
// 意図したディテールではなく圧縮の屑なので、周囲の最頻値に置き換える。
var indices = assignment
for _ in 0..<2 {
    var next = indices
    for y in 0..<h {
        for x in 0..<w {
            var tally: [Int: Int] = [:]
            for dy in -1...1 {
                for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let xx = min(max(x + dx, 0), w - 1), yy = min(max(y + dy, 0), h - 1)
                    tally[indices[yy * w + xx], default: 0] += 1
                }
            }
            let own = indices[y * w + x]
            if tally[own, default: 0] <= 1, let mode = tally.max(by: { $0.value < $1.value })?.key {
                next[y * w + x] = mode
            }
        }
    }
    indices = next
}
for i in 0..<(w * h) { quantised[i] = centroids[indices[i]] }

// 手順 4: 白い余白は四辺に達する 1 つの連結領域なので、縁からの塗りつぶしで
// シアンのタイルに触れずに特定できる。
let whiteThreshold = 232.0
var isSurround = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
func seed(_ x: Int, _ y: Int) {
    let i = y * w + x
    let c = quantised[i]
    if !isSurround[i] && c.r > whiteThreshold && c.g > whiteThreshold && c.b > whiteThreshold {
        isSurround[i] = true
        stack.append(i)
    }
}
for x in 0..<w { seed(x, 0); seed(x, h - 1) }
for y in 0..<h { seed(0, y); seed(w - 1, y) }
while let i = stack.popLast() {
    let x = i % w, y = i / w
    if x > 0 { seed(x - 1, y) }
    if x < w - 1 { seed(x + 1, y) }
    if y > 0 { seed(x, y - 1) }
    if y < h - 1 { seed(x, y + 1) }
}

// 手順 5: デザインはシアンのタイルの周りに白い縁を残す。縁とその外側の余白は
// 同じ白なので、塗りつぶしでは区別できない。輪郭をそのままオフセットすると、
// 圧縮が残した揺れまで写る。タイルに角丸矩形を当て、縁の幅だけ広げたものを
// 外形にする。形は正確で、符号付き距離が縁をアンチエイリアスする。

// タイルは余白以外でいちばん大きい連結成分。余白に残った不透明な屑で
// 外接矩形が広がらないようにする。
var component = [Int](repeating: -1, count: w * h)
var bestComponent = -1, bestSize = 0
var nextLabel = 0
for start in 0..<(w * h) where !isSurround[start] && component[start] == -1 {
    var size = 0
    var work = [start]
    component[start] = nextLabel
    while let i = work.popLast() {
        size += 1
        let x = i % w, y = i / w
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let xx = x + dx, yy = y + dy
            guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
            let j = yy * w + xx
            if !isSurround[j] && component[j] == -1 {
                component[j] = nextLabel
                work.append(j)
            }
        }
    }
    if size > bestSize { bestSize = size; bestComponent = nextLabel }
    nextLabel += 1
}
var x0 = w, y0 = h, x1 = -1, y1 = -1
for y in 0..<h {
    for x in 0..<w where component[y * w + x] == bestComponent {
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
    }
}
func inTile(_ x: Int, _ y: Int) -> Bool { component[y * w + x] == bestComponent }

// 角丸矩形までの符号付き距離。内側は負。
func roundedRectDistance(_ px: Double, _ py: Double, minX: Double, minY: Double,
                         maxX: Double, maxY: Double, radius: Double) -> Double {
    let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    let ex = (maxX - minX) / 2 - radius, ey = (maxY - minY) / 2 - radius
    let qx = abs(px - cx) - ex, qy = abs(py - cy) - ey
    let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
    return outside + min(max(qx, qy), 0) - radius
}

// タイルのマスクにいちばん合う角の半径を選ぶ。
let tileMinX = Double(x0), tileMinY = Double(y0)
let tileMaxX = Double(x1 + 1), tileMaxY = Double(y1 + 1)
var tileRadius = 0.0, bestMismatch = Int.max
for candidate in stride(from: 2.0, through: 40.0, by: 0.5) {
    var mismatch = 0
    for y in y0...y1 {
        for x in x0...x1 {
            let d = roundedRectDistance(Double(x) + 0.5, Double(y) + 0.5,
                                        minX: tileMinX, minY: tileMinY,
                                        maxX: tileMaxX, maxY: tileMaxY, radius: candidate)
            if (d < 0) != inTile(x, y) { mismatch += 1 }
        }
    }
    if mismatch < bestMismatch { bestMismatch = mismatch; tileRadius = candidate }
}

let rimWidth = 6.0
let edgeHalo = 3.0

// 縁とタイルの色はパレットが落ち着いた値を使う。純白や固定のシアンとは限らないので、
// 実際の画素から最頻色を読み戻す。
func modeColor(_ predicate: (Int, Int) -> Bool) -> Color {
    var tally: [Int: Int] = [:]
    for y in 0..<h { for x in 0..<w where predicate(x, y) { tally[indices[y * w + x], default: 0] += 1 } }
    return centroids[tally.max(by: { $0.value < $1.value })!.key]
}
let rimColor = modeColor { x, y in isSurround[y * w + x] }
let tileColor = modeColor { x, y in
    guard !isSurround[y * w + x] else { return false }
    let d = roundedRectDistance(Double(x) + 0.5, Double(y) + 0.5,
                                minX: tileMinX, minY: tileMinY,
                                maxX: tileMaxX, maxY: tileMaxY, radius: tileRadius)
    return d > -6 && d < -1
}

// 手順 6: 出力を合成する。キャンバスが無ければ元のサイズのまま。
// あれば収まる最大の整数倍で中央に置き、周りは透明にする。色は最近傍サンプルなので
// ドットの縁は硬いまま。タイルの内外の縁は、合わせた図形の符号付き距離を
// 出力スケールで評価する。拡大しても輪郭の揺れは拡大されず、階段にもならない。
let scale = canvas.map { max(1, min($0 / w, $0 / h)) } ?? 1
let outW = canvas ?? w, outH = canvas ?? h
let offX = (outW - w * scale) / 2, offY = (outH - h * scale) / 2
let s = Double(scale)

var out = [UInt8](repeating: 0, count: outW * outH * 4)
var clear = 0, partial = 0
for y in 0..<outH {
    for x in 0..<outW {
        let i = y * outW + x
        // 距離は元画像の単位で測り、合わせた図形をそのまま使う。
        // 0.5 単位の傾斜は、出力では 1 ピクセル幅のままになる。
        let px = (Double(x - offX) + 0.5) / s, py = (Double(y - offY) + 0.5) / s
        let ramp = 0.5 / s
        let a = max(0, min(1, ramp - roundedRectDistance(
            px, py, minX: tileMinX - rimWidth, minY: tileMinY - rimWidth,
            maxX: tileMaxX + rimWidth, maxY: tileMaxY + rimWidth,
            radius: tileRadius + rimWidth)))
        if a <= 0 { clear += 1 } else if a < 1 { partial += 1 }
        guard a > 0 else { continue }

        // 合わせたタイルの内側は原画、外側は縁の色。輪郭のすぐ内側の帯はタイル色に固定する。
        // そこにははみ出した白と、圧縮縁の明るいハローがあり、原画自体は届かない。
        let dTile = roundedRectDistance(px, py, minX: tileMinX, minY: tileMinY,
                                        maxX: tileMaxX, maxY: tileMaxY, radius: tileRadius)
        let sx = (x - offX) / scale, sy = (y - offY) / scale
        var art = tileColor
        if dTile < -edgeHalo, sx >= 0, sx < w, sy >= 0, sy < h, !isSurround[sy * w + sx] {
            art = quantised[sy * w + sx]
        }
        let tile = max(0, min(1, ramp - dTile))
        let c = Color(r: rimColor.r + (art.r - rimColor.r) * tile,
                      g: rimColor.g + (art.g - rimColor.g) * tile,
                      b: rimColor.b + (art.b - rimColor.b) * tile)
        // 出力画像のビットマップと同じ、乗算済みアルファで書く。
        out[i * 4] = UInt8(max(0, min(255, (c.r * a).rounded())))
        out[i * 4 + 1] = UInt8(max(0, min(255, (c.g * a).rounded())))
        out[i * 4 + 2] = UInt8(max(0, min(255, (c.b * a).rounded())))
        out[i * 4 + 3] = UInt8(max(0, min(255, (a * 255).rounded())))
    }
}

let outImage: CGImage = out.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: outW, height: outH, bitsPerComponent: 8,
                        bytesPerRow: outW * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}
guard let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("cannot write \(outputPath)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("failed to encode \(outputPath)\n".utf8))
    exit(1)
}

print("\(w)x\(h) -> \(outW)x\(outH) at \(scale)x: palette \(centroids.count) colours, "
      + "\(clear) transparent, \(partial) antialiased edge pixels")
print(String(format: "tile [%d,%d]-[%d,%d] radius %.1f (mismatch %d px), rim %.0f",
             x0, y0, x1, y1, tileRadius, bestMismatch, rimWidth))
print("wrote \(outputPath)")
