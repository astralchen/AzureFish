// swift-tools-version: 6.3
import PackageDescription

/// 定义协议产品及官方 SwiftProtobufPlugin 构建生成规则，不提交生成类型。
let package = Package(
    name: "AzureFishProtocol",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AzureFishProtocol", targets: ["AzureFishProtocol"])],
    dependencies: [.package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")],
    targets: [
        .target(
            name: "AzureFishProtocol",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            plugins: [.plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")]
        ),
        .testTarget(name: "AzureFishProtocolTests", dependencies: ["AzureFishProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
