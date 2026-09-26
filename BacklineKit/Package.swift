// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "BacklineKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BacklineKit", targets: ["BacklineKit"]),
        .executable(name: "backline-cli", targets: ["backline-cli"]),
    ],
    targets: [
        // Real-time stem mixer + Signalsmith Stretch (MIT), compiled C++ with Accelerate.
        .target(
            name: "BacklineEngine",
            path: "Engine",
            exclude: ["vendor/LICENSE-signalsmith-stretch.txt", "vendor/LICENSE-signalsmith-linear.txt",
                      "vendor/signalsmith-linear/platform/linear-xsimd-dispatch.cpp"],
            sources: ["BacklineEngine.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-O3", "-ffp-contract=fast"]),
                .define("NDEBUG"),
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "BacklineKit",
            dependencies: ["BacklineEngine"],
            path: "Sources"
        ),
        .executableTarget(
            name: "backline-cli",
            dependencies: ["BacklineKit"],
            path: "CLI"
        ),
        .testTarget(
            name: "BacklineKitTests",
            dependencies: ["BacklineKit"],
            path: "Tests",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
