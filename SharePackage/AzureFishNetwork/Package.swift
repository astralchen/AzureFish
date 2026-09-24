// swift-tools-version: 6.3
import PackageDescription

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
