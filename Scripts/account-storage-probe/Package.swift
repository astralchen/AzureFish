// swift-tools-version:6.3
import PackageDescription

// 隔离的可行性验证包，不链接进 AzureFish，不创建聊天数据库。
let package = Package(
    name: "AccountStorageProbe",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [.package(url: "https://github.com/sqlcipher/GRDB.swift.git", revision: "a285e4ca87ec6b3584c97b0ec25fc61fec02de60")],
    targets: [.testTarget(name: "AccountStorageProbeTests", dependencies: [.product(name: "GRDB", package: "GRDB.swift")])]
)
