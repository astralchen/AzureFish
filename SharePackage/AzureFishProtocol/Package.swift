// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AzureFishProtocol",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AzureFishProtocol", targets: ["AzureFishProtocol"])],
    dependencies: [.package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")],
    targets: [
        .target(name: "AzureFishProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .testTarget(name: "AzureFishProtocolTests", dependencies: ["AzureFishProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
