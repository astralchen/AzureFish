// swift-tools-version: 6.3
import PackageDescription

/// 定义账号加密存储产品、固定 SQLCipher GRDB 依赖及测试目标。
let package = Package(
    name: "AzureFishStorage",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AzureFishStorage", targets: ["AzureFishStorage"])],
    dependencies: [.package(url: "https://github.com/sqlcipher/GRDB.swift.git", revision: "a285e4ca87ec6b3584c97b0ec25fc61fec02de60")],
    targets: [
        .target(name: "AzureFishStorage", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "AzureFishStorageTests", dependencies: ["AzureFishStorage"])
    ],
    swiftLanguageModes: [.v6]
)
