import XCTest
@testable import Backline

/// R01b: the 550 MB model download waits for a yes (App Store 4.2.3(ii)).
final class ModelConsentTests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: ModelDownloads.consentKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: ModelDownloads.consentKey)
    }

    func testAnswersAreRemembered() {
        UserDefaults.standard.removeObject(forKey: ModelDownloads.consentKey)
        XCTAssertEqual(ModelDownloads.consent, .unasked)
        ModelDownloads.consent = .no
        XCTAssertEqual(ModelDownloads.consent, .no)
        ModelDownloads.consent = .yes
        XCTAssertEqual(ModelDownloads.consent, .yes)
        UserDefaults.standard.set("garbage", forKey: ModelDownloads.consentKey)
        XCTAssertEqual(ModelDownloads.consent, .unasked, "anything unknown asks again")
    }

    func testNothingStartsWithoutAYes() {
        typealias M = ModelDownloads
        XCTAssertFalse(M.mayStart(force: false, consent: .unasked, missing: true), "a fresh install fetches nothing")
        XCTAssertFalse(M.mayStart(force: false, consent: .no, missing: true), "Not now is never overridden automatically")
        XCTAssertTrue(M.mayStart(force: false, consent: .yes, missing: true))
        XCTAssertTrue(M.mayStart(force: true, consent: .no, missing: true), "Settings ▸ Download now is a yes")
        XCTAssertFalse(M.mayStart(force: true, consent: .yes, missing: false), "nothing to fetch")
        XCTAssertTrue(M.mayStart(force: true, consent: .unasked, missing: true), "Download on the row is a yes")
    }

    /// A Mac 1.0 "Not now" (`no`) no longer hides the offer: the extra parts row shows whenever a model is
    /// missing, whatever the stored answer, and nothing starts until it is clicked.
    @MainActor func testAnOldNotNowStillGetsTheOffer() {
        let remind = UserDefaults.standard.object(forKey: ExtraParts.remindKey)
        defer { UserDefaults.standard.set(remind, forKey: ExtraParts.remindKey) }
        UserDefaults.standard.removeObject(forKey: ExtraParts.remindKey)
        ModelDownloads.consent = .no
        XCTAssertTrue(ExtraParts.remind, "the reminder is on unless it was turned off")
        XCTAssertFalse(ModelDownloads.mayStart(force: false, consent: ModelDownloads.consent, missing: true),
                       "nothing starts on its own")
        XCTAssertTrue(ModelDownloads.mayStart(force: true, consent: ModelDownloads.consent, missing: true),
                      "Download on the row is the yes")
    }
}
