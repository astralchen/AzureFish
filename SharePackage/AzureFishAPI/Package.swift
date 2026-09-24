// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AzureFishAPI",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AzureFishAPI", targets: ["AzureFishAPI"])],
    dependencies: [
        .package(path: "../AzureFishProtocol"),
        .package(path: "../AzureFishNetwork"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(name: "AzureFishAPI", dependencies: [
            .product(name: "AzureFishProtocol", package: "AzureFishProtocol"),
            .product(name: "AzureFishNetwork", package: "AzureFishNetwork"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ]),
        .testTarget(name: "AzureFishAPITests", dependencies: [
            "AzureFishAPI", .product(name: "AzureFishNetworkTestSupport", package: "AzureFishNetwork"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
