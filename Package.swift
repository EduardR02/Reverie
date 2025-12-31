// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Reader",
    platforms: [.macOS(.v15)],
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
            path: "Reader",
            exclude: ["Tests"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ReaderTests",
            dependencies: ["Reader"],
            path: "Reader/Tests/ReaderTests",
            resources: [
                .copy("../Fixtures")
            ]
        )
    ]
)