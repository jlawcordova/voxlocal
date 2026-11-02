// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Voxlocal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Voxlocal", targets: ["Voxlocal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        // Pure logic with no third-party dependencies, so it is easy to test.
        .target(name: "VoxlocalCore"),
        .executableTarget(
            name: "Voxlocal",
            dependencies: [
                "VoxlocalCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(name: "VoxlocalCoreTests", dependencies: ["VoxlocalCore"]),
    ]
)
