import Darwin
import Foundation
import Synchronization

/// The background passes' one question, "may I go on?", and what happens after a memory stop (D20 c), ported
/// from iOS `Platform/MemoryBudget.swift`.
///
/// What the Mac keeps and what it leaves: iOS stops an app that goes past a per-app limit, so there the import
/// and the passes measure what is left (`os_proc_available_memory`) before each stage and chunk. macOS sets no
/// such limit and has no such call; it swaps instead, and says when memory is short through the system's
/// memory-pressure source (`AppModel+Memory`). So on the Mac the import keeps its length tiers
/// (`DeviceLimits`), `available` is 0 ("no limit", as on the iOS Simulator), and the passes stop on a pressure
/// warning and start again after `backoff`. The pass figures stay as iOS measured them, for the log and the tests.
nonisolated enum MemoryBudget {
    /// One second of decoded stereo float32 audio at 44.1 kHz.
    static let bytesPerSecond = 352_800.0

    /// What a pass holds at its worst: `copies` song copies and `fixed` bytes (a model and its working memory).
    struct Need: Equatable, Sendable {
        var copies: Double
        var fixed: Double
        func bytes(seconds: Double) -> Double { copies * seconds * MemoryBudget.bytesPerSecond + fixed }
    }

    // MARK: what is left

    /// Memory the app may still use before the system stops it: always 0 on a Mac (no per-app limit), unless a
    /// test or the harness pretends otherwise.
    static var available: UInt64 { override.withLock { $0 } ?? 0 }

    /// Pretend this much is left (nil: no limit). For tests and `--memory-available`.
    static func pretendAvailable(_ bytes: UInt64?) { override.withLock { $0 = bytes } }
    private static let override = Mutex<UInt64?>(nil)

    /// True when `bytes` more fit in what is left. Where the system sets no limit there is always room.
    static func hasRoom(for bytes: Double, available: UInt64 = MemoryBudget.available) -> Bool {
        available == 0 || bytes <= Double(available)
    }

    // MARK: background passes

    /// The passes that run after a song opens.
    enum Pass: String, Sendable {
        case leadRefine = "lead refine", kitSplit = "kit split", cleaner
        /// Writing finished parts again as AAC (D19, `PartsCompactJob`): it streams, so it holds no song copy.
        case compact = "AAC parts"

        /// The whole pass at its worst (measured for iOS on a Mac host; see the iOS file).
        var need: Need {
            switch self {
            case .leadRefine: Need(copies: 8, fixed: 700_000_000)
            case .kitSplit: Need(copies: 9, fixed: 300_000_000)
            case .cleaner: Need(copies: 11, fixed: 800_000_000)
            // A few chunk buffers, the encoder and two decoders: well under the figure, which leaves room.
            case .compact: Need(copies: 0, fixed: 50_000_000)
            }
        }

        /// What the pass still makes after any chunk: the parts it builds once the model is done.
        var afterChunks: Double {
            switch self {
            case .leadRefine: 3          // blend, rhythm, Other without the lead
            case .kitSplit: 2            // the two summed kit parts
            case .cleaner: 4             // process: guitar + Other, lead, rhythm, Other without the lead
            case .compact: 0             // nothing grows with the song
            }
        }
    }

    /// Kept free whatever a pass does: playback, the screen and the system's own share.
    static let passFloor = 300_000_000.0

    /// Before a pass starts: room for all of it, beside the floor, and no memory stop in the last while.
    ///
    /// A pass that doesn't fit is refused (`Short.refusedAtStart`), and that is not a memory stop (ios-import#4):
    /// nothing was taken from anyone, so the other passes are not held back and no retry is scheduled. The app
    /// tries that pass again when the song is next opened or the app next comes to the front.
    static func requireRoom(for pass: Pass, seconds: Double, available: UInt64 = MemoryBudget.available) throws {
        guard mayStartPass else { throw Short(pass: pass, reason: "waiting after a memory stop") }
        let need = pass.need.bytes(seconds: seconds) + passFloor
        guard hasRoom(for: need, available: available) else {
            AppLog.note("memory: \(pass.rawValue) needs \(Int(need / 1_048_576)) MB, \(Int(available / 1_048_576)) MB free: not started")
            throw Short(pass: pass, reason: "not enough memory to start", refusedAtStart: true)
        }
    }

    /// Between chunks: room for what the pass still makes, beside the floor. A pass that is short stops cleanly
    /// (as if cancelled) and starts again later. (A pressure warning stops the passes through their cancel flags.)
    static func roomForNextChunk(of pass: Pass, seconds: Double, available: UInt64 = MemoryBudget.available) -> Bool {
        let need = pass.afterChunks * seconds * bytesPerSecond + passFloor
        if hasRoom(for: need, available: available) { return true }
        noteShort("\(pass.rawValue) stopped: needs \(Int(need / 1_048_576)) MB, \(Int(available / 1_048_576)) MB free")
        return false
    }

    /// A pass that didn't start or stopped for memory. Not a failure: it is tried again later.
    struct Short: Error, Equatable {
        var pass: Pass
        var reason: String
        /// The pass didn't fit at its start (not a stop between chunks, not the minute after a memory stop).
        var refusedAtStart = false
    }

    // MARK: memory stops

    /// After a memory stop (critical pressure, or a pass short of room between chunks) no pass starts for this long.
    static let backoff: TimeInterval = 60
    private static let lastShort = Mutex<Date?>(nil)
    /// Posted (on any thread) after a memory stop; the app starts the passes again after `backoff`.
    static let shortNotification = Notification.Name("BacklineMemoryShort")

    /// A memory stop: logged, passes held back for `backoff`, and the app told so it can try again later.
    static func noteShort(_ what: String, now: Date = Date()) {
        lastShort.withLock { $0 = now }
        AppLog.note("memory: \(what)")
        NotificationCenter.default.post(name: shortNotification, object: nil)
    }

    /// False within `backoff` of a memory stop.
    static func mayStartPass(at now: Date) -> Bool {
        guard let last = lastShort.withLock({ $0 }) else { return true }
        return now.timeIntervalSince(last) >= backoff
    }

    static var mayStartPass: Bool { mayStartPass(at: Date()) }

    /// Tests: forget the last memory stop.
    static func clearShort() { lastShort.withLock { $0 = nil } }

    // MARK: readings

    /// The most the app has held since it started (the kernel's own peak), in MB; 0 if it wouldn't say.
    static var lifetimePeakMegabytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak / 1_048_576) : 0
    }
}
