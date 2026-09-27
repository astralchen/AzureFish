// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AzureFishServer",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AzureFishServer", targets: ["Run"]),
               .executable(name: "AzureFishMediaWorker", targets: ["MediaWorker"])],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    ],
    targets: [
        .target(name: "MediaWorkerSupport"),
        .executableTarget(name: "MediaWorker", dependencies: ["MediaWorkerSupport"]),
        .target(name: "Server", dependencies: [
            "MediaWorkerSupport",
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .executableTarget(name: "Run", dependencies: ["Server", .product(name: "Vapor", package: "vapor")]),
        .testTarget(name: "ServerTests", dependencies: ["Server", "MediaWorker", .product(name: "VaporTesting", package: "vapor")], resources: [.copy("Fixtures")]),
    ]
)
