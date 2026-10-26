// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaMeter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaMeter", targets: ["QuotaMeter"])],
    targets: [
        .executableTarget(name: "QuotaMeter", path: "Sources/QuotaMeter"),
        .testTarget(name: "QuotaMeterTests", dependencies: ["QuotaMeter"])
    ]
)
