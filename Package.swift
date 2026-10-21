// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "S3Sil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "S3Sil", targets: ["S3Sil"])
    ],
    targets: [
        .target(
            name: "S3SilKit",
            path: "Sources/S3SilKit"
        ),
        .executableTarget(
            name: "S3Sil",
            dependencies: ["S3SilKit"],
            path: "Sources/S3Sil"
        ),
        .executableTarget(
            name: "S3SilSmoke",
            dependencies: ["S3SilKit"],
            path: "Sources/S3SilSmoke"
        ),
        .testTarget(
            name: "S3SilKitTests",
            dependencies: ["S3SilKit"],
            path: "Tests/S3SilKitTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
