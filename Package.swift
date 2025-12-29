// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Reader", targets: ["Reader"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Reader",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Reader"
        )
    ]
)
