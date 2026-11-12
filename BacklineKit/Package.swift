// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "BacklineKit",
    platforms: [.macOS("15.0"), .iOS("18.0")],
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
        // LAME 3.100 (encoder only), compiled in for MP3 export.
        .target(
            name: "CLame",
            path: "Lame",
            exclude: ["COPYING"],
            sources: ["bitstream.c", "encoder.c", "fft.c", "gain_analysis.c", "id3tag.c", "lame.c", "newmdct.c", "presets.c",
                      "psymodel.c", "quantize.c", "quantize_pvt.c", "reservoir.c", "set_get.c", "tables.c", "takehiro.c",
                      "util.c", "vbrquantize.c", "VbrTag.c", "version.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("STDC_HEADERS", to: "1"),
                .define("HAVE_STDINT_H", to: "1"),
                .define("HAVE_LIMITS_H", to: "1"),
                .define("HAVE_STRING_H", to: "1"),
                .define("HAVE_MEMCPY", to: "1"),
                .define("LAME_LIBRARY_BUILD", to: "1"),
                .define("ieee754_float32_t", to: "float"),
                .unsafeFlags(["-O3", "-w"]),
            ]
        ),
        // Turns Objective-C exceptions from system frameworks into Swift errors.
        .target(name: "ObjCSafe", path: "ObjCSafe", publicHeadersPath: "include"),
        .target(
            name: "BacklineKit",
            dependencies: ["BacklineEngine", "CLame", "ObjCSafe"],
            path: "Sources",
            // Required-reason APIs the kit calls (R02): file timestamps on its own checkpoints.
            resources: [.copy("PrivacyInfo.xcprivacy")]
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
