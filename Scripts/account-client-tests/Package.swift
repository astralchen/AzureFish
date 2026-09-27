// swift-tools-version:6.3
import PackageDescription

// 与应用共享源文件的主机测试入口，补充模拟器验证，不替代 UIKit／Keychain 真机验收。
let package = Package(name: "AccountClientTests", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../SharePackage/AzureFishAPI"), .package(path: "../../SharePackage/AzureFishNetwork"),
                   .package(path: "../../SharePackage/AzureFishProtocol"), .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")],
    targets: [
        .target(name: "AzureFish", dependencies: [.product(name: "AzureFishAPI", package: "AzureFishAPI")]),
        .testTarget(name: "AccountTests", dependencies: ["AzureFish", .product(name: "AzureFishAPI", package: "AzureFishAPI"),
            .product(name: "AzureFishNetwork", package: "AzureFishNetwork"), .product(name: "AzureFishProtocol", package: "AzureFishProtocol"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf")])
    ])
