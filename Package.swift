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
        // Local dev (uncomment to use local build):
        // .binaryTarget(
        //   name: "SonifiedLLMRuntime",
        //   path: "dist/SonifiedLLMRuntime.xcframework"
        // ),
        .binaryTarget(
            name: "SonifiedLLMRuntime",
            // url: "https://github.com/<your-org>/<your-repo>/releases/download/<tag>/SonifiedLLMRuntime.xcframework.zip",
            // checksum: "48f6cd0fb8238cb97a21a413edd477e24fc2a80d9f62609f111af4cfbcbb7e10"
            path: "dist/SonifiedLLMRuntime.xcframework"
        ),
        .target(
            name: "SonifiedLLMCore",
            dependencies: ["SonifiedLLMRuntime"],
            path: "Sources/SonifiedLLMCore",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                // binary includes static C++ libs; link libc++ and c++abi explicitly
                .linkedLibrary("c++"),
                .linkedLibrary("c++abi")
            ]
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
