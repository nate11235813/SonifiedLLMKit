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
        // Uncomment when you publish your binary
        // .binaryTarget(
        //     name: "SonifiedLLMRuntime",
        //     url: "https://example.com/SonifiedLLMRuntime.xcframework.zip",
        //     checksum: "SWIFTPM_CHECKSUM_PLACEHOLDER"
        // ),
        .target(
            name: "SonifiedLLMCore",
            dependencies: [
                // "SonifiedLLMRuntime" // when available
            ],
            path: "Sources/SonifiedLLMCore"
        ),
        .target(
            name: "SonifiedLLMDownloader",
            dependencies: [],
            path: "Sources/SonifiedLLMDownloader"
        ),
        .target(
            name: "SonifiedLLMUI",
            dependencies: ["SonifiedLLMCore"],
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
        )
    ]
)
