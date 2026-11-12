import BacklineKit
import XCTest
@testable import Backline

/// R01d: the model manifest only says where to look; the app decides what it trusts. Ported from iOS; the Mac
/// reads the `macos` entries only.
final class ModelManifestTests: XCTestCase {
    private let roformer = ModelDownloads.assets[0]
    private let fallback = URL(string: "https://github.com/alexpizarro/backline/releases/download/models-1/BSRoformerSW-fp16-1.aar")!

    private func manifest(_ files: String, withdrawn: String = "[]", format: Int = 1) -> Data {
        Data(#"{"format":\#(format),"updated":"2026-11-01","withdrawn":\#(withdrawn),"files":[\#(files)]}"#.utf8)
    }

    private func entry(platform: String = "macos", sha: String? = nil, bytes: Int64? = nil, urls: [String]) -> String {
        let list = urls.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"platform":"\#(platform)","model":"BSRoformerSW","file":"BSRoformerSW-fp16-1.aar","bytes":\#(bytes ?? roformer.bytes),"sha256":"\#(sha ?? roformer.sha256)","urls":[\#(list)]}"#
    }

    func testMatchingEntriesComeFirstThenGitHub() throws {
        let doc = try XCTUnwrap(ModelManifest.parse(manifest(entry(urls: ["https://models.backlinestems.com/v1/macos/BSRoformerSW-fp16-1.aar", fallback.absoluteString]))))
        XCTAssertEqual(ModelManifest.sources(for: roformer, in: doc, fallback: fallback).map(\.absoluteString),
                       ["https://models.backlinestems.com/v1/macos/BSRoformerSW-fp16-1.aar", fallback.absoluteString],
                       "GitHub isn't repeated when the manifest already lists it")
    }

    func testOnlyExactMatchesAndHTTPSCount() throws {
        let files = [
            entry(platform: "android", urls: ["https://evil.example/android.aar"]),
            // The iOS entries list the same files, but the Mac only trusts its own platform's.
            entry(platform: "ios", urls: ["https://evil.example/ios.aar"]),
            entry(sha: String(repeating: "0", count: 64), urls: ["https://evil.example/other-hash.aar"]),
            entry(bytes: 1, urls: ["https://evil.example/other-size.aar"]),
            entry(urls: ["http://plain.example/x.aar", "ftp://x/y", "not a url", "https://a.example/1", "https://b.example/2",
                         "https://c.example/3", "https://d.example/4", "https://e.example/5"]),
        ].joined(separator: ",")
        let doc = try XCTUnwrap(ModelManifest.parse(manifest(files)))
        XCTAssertEqual(ModelManifest.sources(for: roformer, in: doc, fallback: fallback).map(\.absoluteString),
                       ["https://a.example/1", "https://b.example/2", "https://c.example/3", "https://d.example/4", fallback.absoluteString],
                       "other platforms, hashes and sizes are ignored; https only; at most four mirrors")
    }

    func testNoManifestMeansGitHub() {
        XCTAssertEqual(ModelManifest.sources(for: roformer, in: nil, fallback: fallback), [fallback])
        XCTAssertNil(ModelManifest.parse(manifest(entry(urls: []), format: 2)), "an unknown format is no manifest")
        XCTAssertNil(ModelManifest.parse(Data("<html>".utf8)))
        XCTAssertNotNil(ModelManifest.parse(Data(#"{"format":1,"files":[]}"#.utf8)), "withdrawn and updated are optional")
    }

    func testWithdrawalIsByHash() throws {
        let doc = try XCTUnwrap(ModelManifest.parse(manifest(entry(urls: []), withdrawn: "[\"\(roformer.sha256)\"]")))
        XCTAssertTrue(ModelManifest.isWithdrawn(roformer, in: doc))
        XCTAssertFalse(ModelManifest.isWithdrawn(ModelDownloads.assets[1], in: doc))
        XCTAssertFalse(ModelManifest.isWithdrawn(roformer, in: nil))
    }

    func testTheLastGoodCopyLastsThirtyDays() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        try manifest(entry(urls: ["https://a.example/1"])).write(to: cache)
        XCTAssertNotNil(ModelManifest.lastGood(cache: cache, now: Date().addingTimeInterval(29 * 86_400)))
        XCTAssertNil(ModelManifest.lastGood(cache: cache, now: Date().addingTimeInterval(31 * 86_400)))
    }

    func testDownloadsStopPastTheModelSize() {
        XCTAssertFalse(Downloader.exceeds(100, written: 100, expected: 100))
        XCTAssertTrue(Downloader.exceeds(100, written: 101, expected: -1), "more bytes than the model has")
        XCTAssertTrue(Downloader.exceeds(100, written: 0, expected: 5_000), "a Content-Length bigger than the model")
        XCTAssertFalse(Downloader.exceeds(100, written: 0, expected: -1), "no length announced yet")
    }

    @MainActor func testModelsScreenWords() {
        XCTAssertEqual(ModelsView.size(344_259_466), "344 MB")
        XCTAssertEqual(ModelsView.size(202_873_466), "203 MB")
        let a = roformer
        XCTAssertEqual(ModelsView.status(a, installed: true, downloading: nil, progress: nil, withdrawn: []).text, "Ready")
        XCTAssertEqual(ModelsView.status(a, installed: false, downloading: a.name, progress: 0.42, withdrawn: []).text, "Downloading 42%")
        XCTAssertEqual(ModelsView.status(a, installed: false, downloading: nil, progress: nil, withdrawn: []).text, "Not downloaded")
        XCTAssertEqual(ModelsView.status(a, installed: false, downloading: nil, progress: nil, withdrawn: [a.name]).text, "Not available right now")
        XCTAssertEqual(ModelsView.info(CleanerPartsJob.modelName).title, "Cleaner parts")
        XCTAssertEqual(ModelsView.info(DrumSeparator.modelName).title, "Drum parts")
    }
}
