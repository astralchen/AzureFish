// swift-tools-version:6.3
import PackageDescription

let package = Package(name: "AzureFishMoments", platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AzureFishMoments", targets: ["AzureFishMoments"])],
    dependencies: [.package(path: "../AzureFishAPI"), .package(path: "../AzureFishStorage"),
        .package(url: "https://github.com/sqlcipher/GRDB.swift.git", revision: "a285e4ca87ec6b3584c97b0ec25fc61fec02de60")],
    targets: [.target(name: "AzureFishMoments", dependencies: [.product(name: "AzureFishAPI", package: "AzureFishAPI"),
        .product(name: "AzureFishStorage", package: "AzureFishStorage"), .product(name: "GRDB", package: "GRDB.swift")])], swiftLanguageModes: [.v6])
