import XCTest

/// Release review ios-ui-links#1 and mac-shell#1, ported from iOS `PrivacyManifestTests`: App Store Connect refuses
/// an upload whose code calls one of Apple's required-reason APIs without that reason in the bundle's
/// `PrivacyInfo.xcprivacy` (ITMS-91053). This looks the way that scan does, at the built binaries, against the
/// manifest. The Mac's own: the app has no extensions, and a Mac bundle keeps its binary in `Contents/MacOS` and its
/// manifest in `Contents/Resources`.
final class PrivacyManifestTests: XCTestCase {
    /// What gives each category away in a binary: a selector, an imported symbol or a constant's name.
    private static let signs: [String: [String]] = [
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "\0_mach_absolute_time\0", "\0_mach_continuous_time\0"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["VolumeAvailableCapacity", "VolumeTotalCapacity", "NSFileSystemFreeSize",
                                                  "NSFileSystemSize", "\0_statfs\0", "\0_statvfs\0", "\0_fstatfs\0", "\0_fstatvfs\0"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["NSFileModificationDate", "NSFileCreationDate", "ContentModificationDateKey",
                                                      "CreationDateKey", "\0_getattrlist\0", "\0_fgetattrlist\0", "\0_getattrlistbulk\0",
                                                      "\0_stat\0", "\0_fstat\0", "\0_lstat\0", "\0_fstatat\0"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["NSUserDefaults"],
    ]

    /// The app has no reason to read the boot time, and declares none: nothing in it may call such an API.
    func testNoBinaryReadsTheBootTime() throws {
        for target in try targets() {
            let found = try Self.categories(in: target.binaries)
            XCTAssertFalse(found.contains("NSPrivacyAccessedAPICategorySystemBootTime"),
                           "\(target.name) calls a boot-time API (systemUptime, mach_absolute_time)")
        }
    }

    /// Every category a binary shows signs of is declared in its own bundle's manifest.
    func testEveryRequiredReasonAPIInUseIsDeclared() throws {
        let all = try targets()
        XCTAssertGreaterThanOrEqual(all.count, 1, "the app")
        for target in all {
            XCTAssertFalse(target.binaries.isEmpty, "\(target.name) has no binary")
            let found = try Self.categories(in: target.binaries)
            let declared = try Self.declared(in: target.bundle)
            XCTAssertTrue(found.isSubset(of: declared),
                          "\(target.name) uses \(found.subtracting(declared).sorted()) without a reason in its PrivacyInfo.xcprivacy")
        }
    }

    // MARK: Helpers

    private struct Target {
        var name: String
        var bundle: URL
        var binaries: [URL]
    }

    /// The app (its executable and, in a Debug build, the debug dylib beside it) and any `.appex`. The test bundle
    /// and the test frameworks Xcode copies in are not the app's.
    private func targets() throws -> [Target] {
        let app = Bundle.main.bundleURL
        XCTAssertEqual(app.pathExtension, "app", "these tests run inside the app")
        var out = [Target(name: app.lastPathComponent, bundle: app, binaries: binaries(in: app))]
        let plugins = app.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: plugins.path)) ?? [] where name.hasSuffix(".appex") {
            let ext = plugins.appendingPathComponent(name, isDirectory: true)
            out.append(Target(name: name, bundle: ext, binaries: binaries(in: ext)))
        }
        return out
    }

    private func binaries(in bundle: URL) -> [URL] {
        guard let exec = Bundle(url: bundle)?.executableURL else { return [] }
        var out = [exec]
        let dir = exec.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".debug.dylib") {
            out.append(dir.appendingPathComponent(name))
        }
        return out
    }

    private static func categories(in binaries: [URL]) throws -> Set<String> {
        var found: Set<String> = []
        for url in binaries {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            for (category, needles) in signs where !found.contains(category) {
                if needles.contains(where: { data.range(of: Data($0.utf8)) != nil }) { found.insert(category) }
            }
        }
        return found
    }

    private static func declared(in bundle: URL) throws -> Set<String> {
        guard let url = Bundle(url: bundle)?.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
              let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let types = plist?["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        return Set(types.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
    }
}
