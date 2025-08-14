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
        .library(name: "HarmonyKit", targets: ["HarmonyKit"]),
        // You may later expose a unified product "SonifiedLLMKit" that depends on the three modules above.
        .library(name: "SonifiedLLMRuntimeSupport", targets: ["SonifiedLLMRuntimeSupport"]),
        .executable(name: "CLI", targets: ["CLI"]),
        .executable(name: "ModelIndexGen", targets: ["ModelIndexGen"])
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
        // Wrapper target to carry required linker settings for the static runtime
        .target(
            name: "SonifiedLLMRuntimeSupport",
            dependencies: ["SonifiedLLMRuntime"],
            path: "Sources/SonifiedLLMRuntimeSupport",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                // binary includes static C++ libs; link libc++ and c++abi explicitly
                .linkedLibrary("c++"),
                .linkedLibrary("c++abi")
            ]
        ),
        .target(
            name: "SonifiedLLMCore",
            dependencies: ["SonifiedLLMRuntimeSupport"],
            path: "Sources/SonifiedLLMCore",
            linkerSettings: []
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
        .target(
            name: "HarmonyKit",
            dependencies: ["SonifiedLLMCore"],
            path: "Sources/HarmonyKit"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["SonifiedLLMCore", "SonifiedLLMDownloader"],
            path: "Examples/CLI"
        ),
        .executableTarget(
            name: "HarmonyCLI",
            dependencies: ["HarmonyKit", "SonifiedLLMDownloader"],
            path: "Examples/HarmonyCLI"
        ),
        .executableTarget(
            name: "ModelIndexGen",
            dependencies: ["SonifiedLLMDownloader"],
            path: "Examples/Tools/ModelIndexGen"
        ),
        .testTarget(
            name: "SonifiedLLMCoreTests",
            dependencies: ["SonifiedLLMCore", "SonifiedLLMDownloader"],
            path: "Tests/SonifiedLLMCoreTests",
            resources: [
                .process("Resources")
            ]
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
        ),
        .testTarget(
            name: "HarmonyKitTests",
            dependencies: ["HarmonyKit", "SonifiedLLMCore"],
            path: "Tests/HarmonyKitTests",
            resources: [
                .process("Goldens")
            ]
        )
    ]
)
