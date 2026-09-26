import BacklineKit
import SwiftUI

// The persisted model types (StemKind, SongSettings, SongRecord, …) live in BacklineKit so they
// can be unit-tested; this file adds their UI-only extensions.

extension StemKind {
    @MainActor var color: Color { Theme.stemColor(hue: hue) }
}
