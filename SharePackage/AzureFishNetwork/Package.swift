// swift-tools-version: 6.3
import PackageDescription

/// 定义通用网络产品、独立测试支持产品及含本地 fixture 的测试目标。
let package = Package(
    name: "AzureFishNetwork",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "AzureFishNetwork", targets: ["AzureFishNetwork"]),
        .library(name: "AzureFishNetworkTestSupport", targets: ["AzureFishNetworkTestSupport"]),
    ],
    targets: [
        .target(name: "AzureFishNetwork"),
        .target(name: "AzureFishNetworkTestSupport", dependencies: ["AzureFishNetwork"]),
        .testTarget(name: "AzureFishNetworkTests", dependencies: ["AzureFishNetwork", "AzureFishNetworkTestSupport"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
