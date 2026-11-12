import XCTest
@testable import Backline

/// V01: the extra parts row's words and rules, straight from the plan's Copy table (iOS
/// `docs/release-1.1-plan.md` section 2). Everything here is a plain function, so the table can be checked
/// without a screen. Ported from iOS without the Wi-Fi and mobile-data cases: the Mac has neither.
final class ExtraPartsTests: XCTestCase {
    private typealias M = AppModel

    // MARK: The title

    func testTheTitleSaysWhatThisSongWouldGainInThisMode() {
        XCTAssertEqual(M.extraPartsTitle(mode: .beats, style: .other, hasDrums: true, yourPart: nil),
                       "Hear the kick, snare and hi\u{2011}hats separately")
        XCTAssertEqual(M.extraPartsTitle(mode: .dance, style: .bachata, hasDrums: true, yourPart: nil),
                       "Hear the güira, bongó and bombo separately")
        XCTAssertEqual(M.extraPartsTitle(mode: .play, style: .other, hasDrums: true, yourPart: "Vocals"),
                       "Cleaner Vocals, with less of the band")
        XCTAssertEqual(M.extraPartsTitle(mode: .play, style: .other, hasDrums: true, yourPart: nil),
                       "Cleaner parts, with less of the band in each")
    }

    /// Only when it is true: a song with no drums never promises kit parts.
    func testASongWithoutDrumsIsNotPromisedAKit() {
        XCTAssertEqual(M.extraPartsTitle(mode: .beats, style: .other, hasDrums: false, yourPart: "Guitar"),
                       "Cleaner Guitar, with less of the band")
        XCTAssertEqual(M.extraPartsTitle(mode: .dance, style: .bachata, hasDrums: false, yourPart: nil),
                       "Cleaner parts, with less of the band in each")
        // Dance for another style shows no kit, so it offers the cleaner parts instead.
        XCTAssertEqual(M.extraPartsTitle(mode: .dance, style: .salsa, hasDrums: true, yourPart: nil),
                       "Cleaner parts, with less of the band in each")
    }

    /// "hi-hats" must never break across lines.
    func testHiHatsKeepsItsNonBreakingHyphen() {
        let title = M.extraPartsTitle(mode: .beats, style: .other, hasDrums: true, yourPart: nil)
        XCTAssertTrue(title.contains("\u{2011}"), title)
        XCTAssertFalse(title.contains("hi-hats"), "the ordinary hyphen would let the word break")
    }

    // MARK: Sizes, from the assets

    func testTheSizesComeFromTheModelsThemselves() {
        let both = ModelDownloads.assets.reduce(0) { $0 + $1.bytes }
        XCTAssertEqual(both, 547_132_932, "the two models as shipped")
        XCTAssertEqual(M.extraPartsSize(both), "550 MB", "the headline rounds up to the nearest 10 MB")
        XCTAssertEqual(ModelsView.size(344_259_466), "344 MB")
        XCTAssertEqual(ModelsView.size(202_873_466), "203 MB")
    }

    func testTheDetailsNameBothModelsWithTheirOwnSizes() {
        let details = M.extraPartsDetails(ModelDownloads.assets)
        XCTAssertEqual(details.map(\.title), ["Drum parts", "Cleaner parts"])
        XCTAssertEqual(details.map(\.size), ["203 MB", "344 MB"])
        XCTAssertEqual(details[0].line, "Kick, snare, hi-hats and other drums, each with its own switch.")
        XCTAssertEqual(details[1].line, "Less of the other instruments in each part.")
    }

    /// The row never asks for room the install wouldn't: one rule, in `ModelDownloads`.
    func testTheFreeSpaceRuleIsTheOneTheInstallUses() {
        let cleaner = ModelDownloads.assets.first { $0.name == CleanerPartsJob.modelName }!
        XCTAssertEqual(ModelDownloads.spaceNeeded(cleaner), cleaner.bytes * 3 + 500_000_000)
        XCTAssertEqual(ModelDownloads.spaceNeededForMissing(ModelDownloads.assets), 1_532_778_398)
        XCTAssertEqual(M.extraPartsSpaceLine(needed: 1_532_778_398), "Needs 1.5 GB of free space")
        XCTAssertFalse(ModelDownloads.hasSpaceForMissing(ModelDownloads.assets, free: 1_000_000_000))
        XCTAssertTrue(ModelDownloads.hasSpaceForMissing(ModelDownloads.assets, free: 4_000_000_000))
        XCTAssertTrue(ModelDownloads.hasSpaceForMissing([], free: 0), "nothing missing needs no room")
        XCTAssertTrue(ModelDownloads.hasSpaceForMissing(ModelDownloads.assets, free: nil),
                      "a volume that won't say its free space refuses nothing")
    }

    // MARK: The lines

    func testTheLinesReadAsThePlanWroteThem() {
        XCTAssertEqual(ExtraPartsRow.downloadingLine(fraction: 0.38, secondsLeft: 190),
                       "Downloading · 38% · about 3 min left")
        XCTAssertEqual(ExtraPartsRow.downloadingLine(fraction: 0.38, secondsLeft: nil),
                       "Downloading · 38%", "no time until the rate has settled")
        XCTAssertEqual(ExtraPartsRow.downloadingLine(fraction: 0.99, secondsLeft: 4),
                       "Downloading · 99% · about 1 minute left", "never 0 min left, and one minute in the singular")
        XCTAssertEqual(ExtraPartsRow.downloadingLine(fraction: 0.9, secondsLeft: 80),
                       "Downloading · 90% · about 1 minute left")
        XCTAssertEqual(ExtraPartsRow.downloadingLine(fraction: 0.8, secondsLeft: 100),
                       "Downloading · 80% · about 2 min left")
        XCTAssertEqual(ExtraPartsRow.splittingLine(fraction: 0.4), "Splitting this song's drums · 40%")
        XCTAssertEqual(ExtraPartsRow.splittingLine(fraction: nil), "Splitting this song's drums…")
    }

    func testTheOfferLineNamesTheCost() {
        let offer = ExtraPartsOffer(state: .offer, title: "x", size: "550 MB", details: [])
        XCTAssertEqual(offer.offerLine, "Free download · 550 MB", "a Mac has no Wi-Fi-only choice to name")
    }

    func testOneToastNamesWhatArrived() {
        XCTAssertEqual(M.extraPartsToast(kit: true, mode: .beats, style: .other), "Kick, snare and hi-hats are ready.")
        XCTAssertEqual(M.extraPartsToast(kit: true, mode: .dance, style: .bachata), "Güira, bongó and bombo are ready.")
        XCTAssertEqual(M.extraPartsToast(kit: false, mode: .beats, style: .other), "Downloaded. Cleaner parts are on the way.")
        XCTAssertEqual(M.extraPartsToast(kit: false, mode: .play, style: .other), "Downloaded. Cleaner parts are on the way.")
    }

    // MARK: VoiceOver

    func testVoiceOverReadsTheRowAsOneSentenceAndNeverAsAPart() {
        func label(_ state: ExtraPartsState) -> String {
            ExtraPartsAccessibility.label(ExtraPartsOffer(
                state: state, title: M.extraPartsTitle(mode: .beats, style: .other, hasDrums: true, yourPart: nil),
                size: "550 MB", details: []))
        }
        XCTAssertEqual(label(.offer),
                       "Hear the kick, snare and hi-hats separately. Not downloaded. Free, 550 megabytes.")
        XCTAssertEqual(label(.downloading(fraction: 0.38, secondsLeft: 190)),
                       "Hear the kick, snare and hi-hats separately. Downloading, 38 per cent, about 3 minutes left.")
        XCTAssertEqual(label(.downloading(fraction: 0.97, secondsLeft: 20)),
                       "Hear the kick, snare and hi-hats separately. Downloading, 97 per cent, about 1 minute left.")
        XCTAssertEqual(label(.failed),
                       "Hear the kick, snare and hi-hats separately. Not downloaded. Download didn't finish.")
        XCTAssertEqual(label(.noSpace(needed: 1_532_778_398)),
                       "Hear the kick, snare and hi-hats separately. Not downloaded. Needs 1.5 gigabytes of free space.")
        XCTAssertEqual(label(.splitting(fraction: 0.4)),
                       "Hear the kick, snare and hi-hats separately. Downloaded. Splitting this song's drums, 40 per cent.")
        for state: ExtraPartsState in [.offer, .failed] {
            XCTAssertFalse(label(state).lowercased().contains(", on"), "never read like a part's switch")
        }
    }

    // MARK: One figure across both models

    @MainActor
    func testTheProgressIsOneFigureAcrossBothModelsWeightedByBytes() {
        let extras = ExtraParts()
        let assets = ModelDownloads.assets
        extras.begin(assets)
        XCTAssertNil(extras.fraction)
        XCTAssertEqual(extras.totalBytes, 547_132_932)

        // Half of the first model (344 MB of 547 MB).
        extras.startAsset(assets[0])
        extras.advance(assets[0], fraction: 0.5)
        XCTAssertEqual(extras.fraction ?? 0, 0.3147, accuracy: 0.001)
        extras.finishAsset(assets[0])
        XCTAssertEqual(extras.fraction ?? 0, 0.6293, accuracy: 0.001)

        // Half of the second: 344 MB + 101 MB of 547 MB.
        extras.startAsset(assets[1])
        extras.advance(assets[1], fraction: 0.5)
        XCTAssertEqual(extras.fraction ?? 0, 0.8147, accuracy: 0.001)
        extras.finishAsset(assets[1])
        XCTAssertEqual(extras.fraction ?? 0, 1, accuracy: 0.0001)
    }

    @MainActor
    func testTheTimeLeftWaitsForTheRateToSettle() {
        let extras = ExtraParts()
        let asset = ModelDownloads.assets[0]
        extras.begin([asset])
        extras.startAsset(asset)
        extras.advance(asset, fraction: 0.1)
        XCTAssertNil(extras.secondsLeft, "one sample says nothing yet")
        // Samples a second and a half apart, which is what the sampler keeps.
        let start = Date()
        for i in 1...4 {
            extras.advance(asset, fraction: 0.1 + 0.1 * Double(i), now: start.addingTimeInterval(Double(i) * 1.5))
        }
        let left = try? XCTUnwrap(extras.secondsLeft)
        XCTAssertNotNil(left, "after three samples there is a figure")
        XCTAssertGreaterThan(left ?? 0, 0)
    }

    @MainActor
    func testCancelForgetsEverythingSoTheOfferComesBack() {
        let extras = ExtraParts()
        extras.begin(ModelDownloads.assets)
        extras.startAsset(ModelDownloads.assets[0])
        extras.advance(ModelDownloads.assets[0], fraction: 0.5)
        extras.cancelled()
        XCTAssertNil(extras.fraction)
        XCTAssertEqual(extras.totalBytes, 0)
        XCTAssertFalse(extras.failed)
        XCTAssertNil(extras.secondsLeft)
    }

    @MainActor
    func testAFailureIsRememberedUntilTheNextTry() {
        let extras = ExtraParts()
        extras.begin(ModelDownloads.assets)
        extras.startAsset(ModelDownloads.assets[0])
        extras.fail()
        XCTAssertTrue(extras.failed)
        XCTAssertNil(extras.fraction)
        extras.begin(ModelDownloads.assets)
        XCTAssertFalse(extras.failed, "Try again starts clean")
    }

    @MainActor
    func testTheRemindSwitchIsOnUntilItIsTurnedOff() {
        let key = ExtraParts.remindKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(ExtraParts.remind, "on by default (V02)")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(ExtraParts.remind)
    }

    // MARK: The test archives the UI tests install

    /// The fixtures the harness serves are real Apple Archives that the install path unpacks, and their
    /// pinned hashes still match the committed files (so the two can never drift apart). They ride in the
    /// test bundle: the sandboxed test host can't read the repository.
    func testTheTestArchivesMatchTheirPinnedHashes() throws {
        for asset in ModelDownloads.testAssets {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: asset.file, withExtension: nil, subdirectory: "models"),
                                    "\(asset.file) is in the test bundle")
            XCTAssertEqual(try ModelDownloads.sha256(of: url), asset.sha256, asset.file)
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertEqual(Int64(size), asset.bytes, asset.file)

            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: out) }
            try ModelDownloads.extract(url, to: out)
            let unpacked = try FileManager.default.contentsOfDirectory(atPath: out.path)
            XCTAssertTrue(unpacked.contains("model.espresso.net"), "\(asset.file) unpacks: \(unpacked)")
        }
    }
}
