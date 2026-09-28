// swift-tools-version:6.3
import PackageDescription

let package = Package(name: "AzureFishChat", platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AzureFishChat", targets: ["AzureFishChat"])],
    dependencies: [.package(path: "../AzureFishAPI"),
        .package(url: "https://github.com/sqlcipher/GRDB.swift.git", revision: "a285e4ca87ec6b3584c97b0ec25fc61fec02de60")],
    targets: [.target(name: "AzureFishChat", dependencies: [.product(name: "AzureFishAPI", package: "AzureFishAPI"), .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "AzureFishChatTests", dependencies: ["AzureFishChat"])], swiftLanguageModes: [.v6])
