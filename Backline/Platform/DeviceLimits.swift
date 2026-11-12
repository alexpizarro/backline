import Foundation

/// How long a song this Mac can split (iOS R04). Splitting holds the song and every part in memory at once, so
/// the limit follows the Mac's memory. Apple silicon Macs start at 8 GB; links already stop at 20 minutes.
/// The tiers are the review's proposal (paritymac WP1, 20 minutes at 8 GB, 30 at 16 GB and up); the owner
/// confirms them, ideally after a measured long split on an 8 GB Mac.
nonisolated enum DeviceLimits {
    /// The longest song, in seconds, for a Mac with `memory` bytes.
    static func maxSongSeconds(memory: UInt64) -> Double {
        switch memory {
        case 15_000_000_000...: 30 * 60       // 16 GB and more
        case 7_000_000_000...: 20 * 60        // 8 GB: the smallest Apple silicon Mac
        default: 12 * 60                      // less than 8 GB (not a Mac this app supports today)
        }
    }

    static var maxSongSeconds: Double { maxSongSeconds(memory: ProcessInfo.processInfo.physicalMemory) }

    /// Whether the extra parts row offers the two big models (iOS B03 keeps them from phones under 6 GB).
    /// Every Apple silicon Mac has 8 GB or more, which is enough for the cleaner pass and the kit split.
    static let offersExtraParts = true

    /// "Longer than 20 minutes."
    static func tooLongMessage(seconds: Double = maxSongSeconds) -> String {
        "Longer than \(Int((seconds / 60).rounded())) minutes."
    }

    /// A song past the limit, said plainly.
    struct TooLong: LocalizedError, Equatable {
        var errorDescription: String? { DeviceLimits.tooLongMessage() }
    }
}
