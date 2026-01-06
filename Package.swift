// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Reverie",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Reverie", targets: ["Reverie"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Reverie",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Reverie",
            exclude: ["Tests"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ReverieTests",
            dependencies: ["Reverie"],
            path: "Reverie/Tests/ReverieTests",
            resources: [
                .copy("../Fixtures")
            ]
        )
    ]
)