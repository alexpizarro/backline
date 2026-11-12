import Foundation
import Testing
@testable import BacklineKit

/// U06: the naming rules, on stored shares (no audio). Numbers from `docs/release/part-detection.md`.
struct NameCheckTests {
    func s(_ g: Float, _ k: Float) -> InstrumentShares { InstrumentShares(guitar: g, keys: k) }

    @Test func aSongWithGuitarKeepsItsGuitar() {
        #expect(NameCheck.guitarFate(mix: s(0.62, 0.2), guitarStem: s(0.99, 0.1)) == .keep)      // La Isla Bonita
        #expect(NameCheck.guitarFate(mix: s(0.68, 0.28), guitarStem: nil) == .keep)              // Los Infieles
    }

    @Test func aKeyboardRiffFiledAsGuitarJoinsKeys() {
        #expect(NameCheck.guitarFate(mix: s(0.01, 0.75), guitarStem: s(0.31, 0.75)) == .joinKeys) // Still D.R.E.
    }

    @Test func anUnclearGuitarInASongWithoutGuitarGoesToMoreParts() {
        // HUMBLE.: the classifier hears the separated piano as guitar, so the stem can't be trusted for the name.
        #expect(NameCheck.guitarFate(mix: s(0.01, 0.6), guitarStem: s(1.0, 0.2)) == .moreParts)
        #expect(NameCheck.guitarFate(mix: s(0.11, 0.8), guitarStem: nil) == .moreParts)          // Someone Like You
    }

    @Test func withoutSharesNothingChanges() {
        #expect(NameCheck.guitarFate(mix: nil, guitarStem: nil) == .keep)
        #expect(NameCheck.trustLead(nil))
    }

    @Test func leadGuitarNeedsToSoundLikeGuitar() {
        #expect(NameCheck.trustLead(s(0.91, 0.1)))       // Isla
        #expect(NameCheck.trustLead(s(0.81, 0.2)))       // Infieles
        #expect(!NameCheck.trustLead(s(0.26, 0.74)))     // Still D.R.E. (the riff)
        #expect(!NameCheck.trustLead(s(0.5, 0.6)))       // more keys than guitar
    }
}
