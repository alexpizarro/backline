import BacklineKit
import Foundation
import SwiftUI

/// The extra parts row (V01, iOS `docs/release-1.1-plan.md` section 2). Until the two free models are here, a
/// dimmed row sits at the top of the parts list and says what this song would gain in this mode, what it
/// costs, and has one button. It replaces 1.0's one-time card, whose "Not now" hid the offer forever.
///
/// This file holds the words and the rules; `UI/ExtraPartsRow.swift` draws them. Everything the rules need
/// is a plain function, so the Copy table can be tested without a screen. Ported from iOS; the Mac has no
/// Wi-Fi or mobile-data choice, so there is no waiting state and the offer names no network.

// MARK: - What the row says

/// What the row is doing right now. One state at a time; the row never shows two things.
nonisolated enum ExtraPartsState: Equatable, Sendable {
    /// Not downloaded: "Free download · 550 MB", with Download.
    case offer
    /// One figure across every model still to fetch, weighted by bytes. `secondsLeft` is nil until the
    /// rate has settled, so the row never shows a number that then jumps.
    case downloading(fraction: Double, secondsLeft: Double?)
    /// Downloaded, and this song's drums are being split into the kit parts the title promised.
    case splitting(fraction: Double?)
    /// Not enough room: "Needs 1.5 GB of free space", no button (nothing to click would work).
    case noSpace(needed: Int64)
    /// The last attempt didn't finish: "Download didn't finish", with Try again.
    case failed
}

/// Everything the row draws. Built by `AppModel.extraPartsOffer`, so the rules are testable.
nonisolated struct ExtraPartsOffer: Equatable, Sendable {
    var state: ExtraPartsState
    /// What you'd hear, in the words this mode already uses.
    var title: String
    /// The whole download: "550 MB".
    var size: String
    /// One line per model still to fetch, shown when the row is clicked.
    var details: [Detail]

    struct Detail: Equatable, Sendable {
        var title: String
        var size: String
        var line: String
    }

    /// "Free download · 550 MB"
    var offerLine: String { "Free download · \(size)" }
}

// MARK: - Download state

/// The extra parts row's own state: one progress across the models being fetched, the time left, whether
/// the last attempt failed, and the hand-over to the kit split. `ModelDownloads` drives it; the row reads
/// it. Reset puts it back to nothing.
@MainActor @Observable
final class ExtraParts {
    static let shared = ExtraParts()

    /// Settings ▸ Models ▸ "Remind me in the player" (V02), on by default. Off hides the row everywhere;
    /// Settings ▸ Models still offers the download, so turning it off isn't turning the models down.
    static let remindKey = "extraPartsRemindInPlayer"
    static var remind: Bool { UserDefaults.standard.object(forKey: remindKey) as? Bool ?? true }

    /// The FREE tape sticks on the first time the row is seen, and never again (2.7).
    static let tapeKey = "extraPartsTapeStuck"

    /// Bytes this run is fetching, the bytes of the models it has finished, and the one in flight.
    /// (Plain numbers, not tuples: an `@Observable` property of tuple type crashes on deinit.)
    private(set) var totalBytes: Int64 = 0
    private(set) var doneBytes: Int64 = 0
    private(set) var currentBytes: Int64 = 0
    /// How far along the whole download is, nil before the first byte.
    private(set) var fraction: Double?
    /// The last attempt didn't finish (offline, out of space, or a file that didn't check out).
    private(set) var failed = false
    /// Set when the download finishes, so the row stays for the kit split and the toast comes once.
    private(set) var finishing = false
    /// True for the moment the new parts arrive, so they land and nothing else moves.
    private(set) var landing = false

    /// Bytes a second, smoothed, and how many samples it has had: the time left waits for the third, so
    /// the first seconds of a download don't put a wild number on screen. Bookkeeping, not state the row
    /// draws, so nothing here asks for a redraw.
    @ObservationIgnored private var rate: Double?
    @ObservationIgnored private var samples = 0
    @ObservationIgnored private var lastAt: Date?
    @ObservationIgnored private var lastBytes: Int64 = 0

    // MARK: What is installed (UIP-02)

    /// The models still to fetch, and whether the device has room for them, as of the last `refresh`. The
    /// row reads these and never the disk: checking files and asking the volume for its free space in a
    /// view body ran on every fader step and every download progress callback. They are refreshed when
    /// something can change them: launch, a return to the app, Settings closing, a download starting,
    /// finishing, failing or being cancelled, and Reset.
    private(set) var missing: [ModelAsset] = []
    private(set) var hasSpace = true

    /// Looks now, on the main actor: for the moments right after an install, when the row must not show an
    /// old answer. A few file checks and one free-space query, never from a view body.
    func refresh() {
        let now = ModelDownloads.missing
        apply(missing: now, hasSpace: ModelDownloads.hasSpaceForMissing(now))
    }

    /// Looks off the main thread and applies the answer when it comes: launch and a return to the app.
    func refreshSoon() {
        Task.detached(priority: .utility) { [weak self] in
            let now = ModelDownloads.missing
            let space = ModelDownloads.hasSpaceForMissing(now)
            await self?.apply(missing: now, hasSpace: space)
        }
    }

    /// Writes only what changed, so a refresh that finds the same answer redraws nothing.
    func apply(missing now: [ModelAsset], hasSpace space: Bool) {
        if now.map(\.name) != missing.map(\.name) { missing = now }
        if space != hasSpace { hasSpace = space }
    }

    // MARK: Driven by ModelDownloads

    func begin(_ assets: [ModelAsset]) {
        totalBytes = assets.reduce(0) { $0 + $1.bytes }
        doneBytes = 0
        currentBytes = 0
        fraction = nil
        failed = false
        rate = nil
        samples = 0
        lastAt = nil
        lastBytes = 0
    }

    func startAsset(_ asset: ModelAsset) {
        currentBytes = asset.bytes
    }

    /// One model's progress, folded into the figure for all of them. `now` is only given by the tests,
    /// which can't wait several seconds for the rate to settle.
    func advance(_ asset: ModelAsset, fraction p: Double, now: Date = Date()) {
        guard totalBytes > 0 else { return }
        let bytes = doneBytes + Int64(Double(asset.bytes) * min(1, max(0, p)))
        fraction = min(1, Double(bytes) / Double(totalBytes))
        failed = false
        guard let at = lastAt else { lastAt = now; lastBytes = bytes; return }
        let seconds = now.timeIntervalSince(at)
        guard seconds >= 1 else { return }                 // one sample a second is enough
        let instant = Double(bytes - lastBytes) / seconds
        lastAt = now
        lastBytes = bytes
        guard instant > 0 else { return }
        rate = rate.map { $0 * 0.7 + instant * 0.3 } ?? instant
        samples += 1
    }

    func finishAsset(_ asset: ModelAsset) {
        doneBytes = min(totalBytes, doneBytes + asset.bytes)
        currentBytes = 0
        fraction = totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : nil
    }

    func fail() {
        failed = true
        fraction = nil
        currentBytes = 0
    }

    func cancelled() {
        begin([])
        finishing = false
    }

    /// The download is done. `kit` is true when this song and mode are about to get their kit parts, so
    /// the row stays and says "Splitting this song's drums" until they are there.
    func downloadFinished(kit: Bool) {
        failed = false
        finishing = kit
    }

    /// The new parts are here: they land, then the row is gone for good.
    func landed() {
        finishing = false
        landing = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            self?.landing = false
        }
    }

    func stopFinishing() { finishing = false }

    /// How long the rest of the download should take, once the rate has settled.
    var secondsLeft: Double? {
        guard samples >= 3, let rate, rate > 0, let fraction, totalBytes > 0 else { return nil }
        return max(0, Double(totalBytes) * (1 - fraction)) / rate
    }

    /// Reset Backline: nothing from before is remembered.
    func reset() {
        cancelled()
        landing = false
        refresh()
    }

    /// Everything here is a number or a flag: nothing has to be let go of on the main actor. Said out loud
    /// because a main-actor class otherwise gets an isolated deinit, which goes through a back-deployed shim
    /// that has crashed when the object is freed (seen on iOS). The app only ever keeps `shared`, which never
    /// goes away, but the tests make their own.
    nonisolated deinit {}
}

// MARK: - The rules

extension AppModel {
    /// What the extra parts row should show, or nil when there is nothing to offer. The row appears only
    /// when a model is missing and not withdrawn, the person hasn't turned the reminder off (V02), and this
    /// song's parts are on screen. Every Apple silicon Mac has the memory for the work.
    var extraPartsOffer: ExtraPartsOffer? {
        let extras = ExtraParts.shared
        #if DEBUG
        if let forced = Self.forcedExtraPartsState { return extraPartsOffer(state: forced) }
        #endif
        guard !resetting, song != nil, !rows.isEmpty, ExtraParts.remind, DeviceLimits.offersExtraParts else { return nil }
        // What `ExtraParts.refresh` last found: no file or volume access here (UIP-02).
        let missing = extras.missing.filter { !withdrawnModels.contains($0.name) }
        // Downloaded, and this song's kit is on its way: the row holds its place until the parts are
        // there. Only while that split is really coming: once it has run, or the mode no longer shows the
        // kit, the row is gone.
        if extras.finishing, missing.isEmpty, drumJob != nil || kitGoesFirst {
            return extraPartsOffer(state: .splitting(fraction: drumSplitProgress), missing: ModelDownloads.assets)
        }
        guard !missing.isEmpty else { return nil }
        return extraPartsOffer(state: extraPartsState(missing: missing), missing: missing)
    }

    private func extraPartsState(missing: [ModelAsset]) -> ExtraPartsState {
        let extras = ExtraParts.shared
        // Read before any condition: these are what the row observes to redraw (`modelDownloadTask` and the
        // consent aren't observable), so a read skipped by a short-circuit would leave the row frozen on the offer.
        let fraction = extras.fraction
        let secondsLeft = extras.secondsLeft
        let failed = extras.failed
        // Set by `begin` the moment Download is clicked, before the first byte: the row turns to Cancel at once.
        let started = extras.totalBytes > 0
        let running = modelDownloadTask != nil && started
        if running, ModelDownloads.consent == .yes {
            return .downloading(fraction: fraction ?? 0, secondsLeft: secondsLeft)
        }
        // The rule `install` uses, asked before Download is offered: a click that can't work is worse than
        // no button at all.
        if !extras.hasSpace {
            return .noSpace(needed: ModelDownloads.spaceNeededForMissing(missing))
        }
        return failed ? .failed : .offer
    }

    /// The row's words for a state. `missing` decides the size and the details.
    func extraPartsOffer(state: ExtraPartsState, missing: [ModelAsset] = ExtraParts.shared.missing) -> ExtraPartsOffer {
        let assets = missing.isEmpty ? ModelDownloads.assets : missing
        return ExtraPartsOffer(state: state, title: extraPartsTitle,
                               size: Self.extraPartsSize(assets.reduce(0) { $0 + $1.bytes }),
                               details: Self.extraPartsDetails(assets))
    }

    /// What you'd hear, only when it is true of this song in this mode (V01's Copy table).
    var extraPartsTitle: String {
        let hasDrums = song?.stems.contains(.drums) == true || song?.stems.contains { $0.isDrumPart } == true
        let yours = mode == .dance ? nil : playingStem.map { label($0) }
        return Self.extraPartsTitle(mode: mode, style: danceStyle, hasDrums: hasDrums, yourPart: yours)
    }

    /// The title, as a plain function of what the screen is showing.
    /// "hi&#8209;hats" keeps its non-breaking hyphen so the word never breaks across lines.
    nonisolated static func extraPartsTitle(mode: PracticeMode, style: DanceStyle, hasDrums: Bool, yourPart: String?) -> String {
        if hasDrums, mode == .beats { return "Hear the kick, snare and hi\u{2011}hats separately" }
        if hasDrums, mode == .dance, style == .bachata { return "Hear the güira, bongó and bombo separately" }
        if let yourPart { return "Cleaner \(yourPart), with less of the band" }
        return "Cleaner parts, with less of the band in each"
    }

    /// The whole download, to the nearest 10 MB and never under the real figure: "550 MB". The models'
    /// own sizes are exact ("344 MB"); the headline is a round number people can hold on to.
    nonisolated static func extraPartsSize(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 10_000_000).rounded(.up)) * 10) MB"
    }

    /// "Needs 1.5 GB of free space", to the nearest tenth of a gigabyte: three times the cleaner model plus
    /// 500 MB (1.53 GB).
    nonisolated static func extraPartsSpaceLine(needed: Int64) -> String {
        let gb = (Double(needed) / 100_000_000).rounded() / 10
        return "Needs \(gb.formatted(.number.precision(.fractionLength(0...1)))) GB of free space"
    }

    /// What the two models are, in the order the person meets them on the row.
    nonisolated static func extraPartsDetails(_ assets: [ModelAsset]) -> [ExtraPartsOffer.Detail] {
        let words: [String: (String, String)] = [
            DrumSeparator.modelName: ("Drum parts", "Kick, snare, hi-hats and other drums, each with its own switch."),
            CleanerPartsJob.modelName: ("Cleaner parts", "Less of the other instruments in each part."),
        ]
        let order = [DrumSeparator.modelName, CleanerPartsJob.modelName]
        return assets
            .sorted { (order.firstIndex(of: $0.name) ?? order.count) < (order.firstIndex(of: $1.name) ?? order.count) }
            .map { asset in
                let w = words[asset.name] ?? ("Extra parts", "")
                return ExtraPartsOffer.Detail(title: w.0, size: ModelsView.size(asset.bytes), line: w.1)
            }
    }

    // MARK: The button

    /// Download, and Try again: the yes.
    func downloadExtraParts() {
        AppLog.note("models: extra parts row, download")
        startModelDownloads(force: true)
    }

    // MARK: Finishing

    /// Every model is installed. When this song and mode will get kit parts, the row stays and counts the
    /// split; otherwise the row goes now and one toast says what arrived.
    func extraPartsDownloadFinished() {
        let kit = kitGoesFirst
        ExtraParts.shared.downloadFinished(kit: kit)
        AppLog.note("models: installed, kit next=\(kit)")
        if !kit { showToast(Toast(text: Self.extraPartsToast(kit: false, mode: mode, style: danceStyle))) }
    }

    /// The kit split that the row was waiting for has ended. The parts land, the row goes, one toast.
    func extraPartsKitSplitEnded(ok: Bool) {
        guard ExtraParts.shared.finishing else { return }
        ExtraParts.shared.landed()
        showToast(Toast(text: Self.extraPartsToast(kit: ok, mode: mode, style: danceStyle)))
    }

    /// True while the kit parts that have just arrived should land.
    var extraPartsLanding: Bool { ExtraParts.shared.landing }

    /// One toast, naming the parts the person can now hear.
    nonisolated static func extraPartsToast(kit: Bool, mode: PracticeMode, style: DanceStyle) -> String {
        guard kit else { return "Downloaded. Cleaner parts are on the way." }
        if mode == .dance, style == .bachata { return "Güira, bongó and bombo are ready." }
        return "Kick, snare and hi-hats are ready."
    }

    #if DEBUG
    /// `--extra-parts-state offer|downloading|splitting|no-space|failed`: one state on screen for a
    /// screenshot or an audit, with nothing downloaded and nothing started.
    static var forcedExtraPartsState: ExtraPartsState? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--extra-parts-state"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "offer": return .offer
        case "downloading": return .downloading(fraction: 0.38, secondsLeft: 190)
        case "splitting": return .splitting(fraction: 0.4)
        case "no-space": return .noSpace(needed: ModelDownloads.spaceNeededForMissing(ModelDownloads.assets))
        case "failed": return .failed
        default: return nil
        }
    }
    #endif
}
