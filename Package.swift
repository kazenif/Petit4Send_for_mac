// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Petit4Send", platforms: [.macOS(.v13)], products: [.executable(name: "Petit4SendMac", targets: ["Petit4SendMac"])], targets: [.target(name: "Petit4SendCore"), .executableTarget(name: "Petit4SendMac", dependencies: ["Petit4SendCore"]), .testTarget(name: "Petit4SendCoreTests", dependencies: ["Petit4SendCore"], exclude: ["Fixtures"])])
