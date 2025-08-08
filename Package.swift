// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonifiedLLMKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SonifiedLLMCore", targets: ["SonifiedLLMCore"]),
        .library(name: "SonifiedLLMDownloader", targets: ["SonifiedLLMDownloader"]),
        .library(name: "SonifiedLLMUI", targets: ["SonifiedLLMUI"]),
        // You may later expose a unified product "SonifiedLLMKit" that depends on the three modules above.
        .executable(name: "CLI", targets: ["CLI"])
    ],
    targets: [
        .binaryTarget(
            name: "SonifiedLLMRuntime",
            url: "https://github.com/nate11235813/SonifiedLLMKit/releases/download/runtime-v0.1.1/SonifiedLLMRuntime.xcframework.zip",
            checksum: "8b4010dd75bce7e90baecff4df4980c928e0b2070a28ba6021c80e377f0ce41c"
        ),
        .target(
            name: "SonifiedLLMCore",
            dependencies: ["SonifiedLLMRuntime"],
            path: "Sources/SonifiedLLMCore"
        ),
        .target(
            name: "SonifiedLLMDownloader",
            dependencies: ["SonifiedLLMCore"],
            path: "Sources/SonifiedLLMDownloader"
        ),
        .target(
            name: "SonifiedLLMUI",
            dependencies: ["SonifiedLLMCore", "SonifiedLLMDownloader"],
            path: "Sources/SonifiedLLMUI"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["SonifiedLLMCore", "SonifiedLLMDownloader"],
            path: "Examples/CLI"
        ),
        .testTarget(
            name: "SonifiedLLMCoreTests",
            dependencies: ["SonifiedLLMCore"],
            path: "Tests/SonifiedLLMCoreTests"
        ),
        .testTarget(
            name: "SonifiedLLMDownloaderTests",
            dependencies: ["SonifiedLLMDownloader"],
            path: "Tests/SonifiedLLMDownloaderTests"
        ),
        .testTarget(
            name: "SonifiedLLMRuntimeLinkTests",
            dependencies: ["SonifiedLLMCore"],
            path: "Tests/SonifiedLLMRuntimeLinkTests"
        )
    ]
)
