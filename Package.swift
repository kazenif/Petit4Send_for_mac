// swift-tools-version: 5.9
import PackageDescription

// Petit4Send for Mac。プロトコルとシリアルと画像復元を Petit4SendCore に置き、
// SwiftUI の実行ファイルがそれを使う。単体実行でもアイコンと HELP.md を同梱できるよう、
// リソースはターゲットへコピーする。テスト用の画像はコンパイル対象にしない。
let package = Package(name: "Petit4Send", platforms: [.macOS(.v14)], products: [.executable(name: "Petit4SendMac", targets: ["Petit4SendMac"])], targets: [.target(name: "Petit4SendCore"), .executableTarget(name: "Petit4SendMac", dependencies: ["Petit4SendCore"], resources: [.copy("Resources/Petit4SendMac.icns"), .copy("Resources/HELP.md")]), .testTarget(name: "Petit4SendCoreTests", dependencies: ["Petit4SendCore"], exclude: ["Fixtures"])])
