// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClearMix",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "ClearMixCore", targets: ["ClearMixCore"]),
        .executable(name: "clearmix-dsp", targets: ["ClearMixDSP"]),
        .executable(name: "clearmix-mic", targets: ["ClearMixMic"]),
        .executable(name: "clearmix-mix", targets: ["ClearMixMix"]),
        .executable(name: "clearmix-ui", targets: ["ClearMixUI"]),
    ],
    targets: [
        // Small C target for the lock-free primitives that must not touch the
        // Swift runtime from a realtime audio callback.
        .target(name: "CMixRT"),
        // RNNoise plus the thin C shim that keeps its int16 sample scale on the
        // C side. The vendored model and its BSD licence live in vendor/.
        .target(
            name: "CMixRNNoise",
            path: "Sources/CMixRNNoise",
            cSettings: [
                .headerSearchPath("vendor/include"),
                .headerSearchPath("vendor/src"),
            ]
        ),
        .target(
            name: "ClearMixCore",
            dependencies: ["CMixRT", "CMixRNNoise"]
        ),
        .executableTarget(
            name: "ClearMixDSP",
            dependencies: ["ClearMixCore"]
        ),
        .executableTarget(
            name: "ClearMixMic",
            dependencies: ["ClearMixCore"]
        ),
        .executableTarget(
            name: "ClearMixMix",
            dependencies: ["ClearMixCore"]
        ),
        .executableTarget(
            name: "ClearMixUI",
            dependencies: ["ClearMixCore"]
        ),
        .testTarget(
            name: "ClearMixCoreTests",
            dependencies: ["ClearMixCore"]
        ),
    ]
)
