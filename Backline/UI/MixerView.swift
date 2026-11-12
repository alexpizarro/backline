import BacklineKit
import SwiftUI

struct MixerView: View {
    @Environment(AppModel.self) private var model
    /// Settings ▸ Models ▸ Remind me in the player (V02): read here so the row comes and goes with it.
    @AppStorage(ExtraParts.remindKey) private var remindExtraParts = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rollback switch for the Stage light (no UI): `defaults write … stageLight -bool NO`.
    @AppStorage("stageLight") private var stageLightOn = true
    /// The split just ended on this song: its parts land row by row once (as on iOS).
    var landParts = false
    var onLanded: () -> Void = {}
    /// While the parts are held back for the screen's cross-fade after a split; `landing` is the second or so
    /// that they are landing.
    @State private var holdingRows: Bool
    @State private var landing = false
    /// The scroll hint (3.4): how far the parts can scroll, the pill's count while it shows, and whether the
    /// person has scrolled the parts themselves.
    @State private var overflow: CGFloat = 0
    @State private var hintCount: Int?
    @State private var userScrolled = false
    @State private var scroll = ScrollPosition(edge: .top)

    init(landParts: Bool = false, onLanded: @escaping () -> Void = {}) {
        self.landParts = landParts
        self.onLanded = onLanded
        _holdingRows = State(initialValue: landParts)
    }

    var body: some View {
        VStack(spacing: 0) {
            SongHeader()
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
            Group {
                switch model.mode {
                case .play: PlayingRow()
                case .dance: ListenForRow()
                case .beats: BarLoopRow()
                }
            }
            .padding(EdgeInsets(top: 0, leading: 24, bottom: 16, trailing: 24))
            .motion(.smooth(duration: 0.25), value: model.mode)
            OverviewCard()
                .padding(.horizontal, 24)
            ScrollView {
                VStack(spacing: 6) {
                    // The extra parts row (V01), above the first part, until the two free models are here.
                    // The row reads its own state (UIP-02), so a download's progress redraws that row, not this list.
                    if remindExtraParts { ExtraPartsSlot() }
                    // The kit parts land like tape the moment they arrive from the extra parts download; after a
                    // split every part lands.
                    let kitLanding = model.extraPartsLanding
                    ForEach(Array((holdingRows ? [] : mainRows).enumerated()), id: \.element) { i, k in
                        if model.mode == .beats, model.musicIsOpen, k == model.musicLeaves.first { MusicHeader() }
                        StemRow(kind: k, index: i)
                            .modifier(PartLanding(index: i, active: landing || (kitLanding && k.isDrumPart)))
                    }
                    if !quietRows.isEmpty {
                        MorePartsRow(count: quietRows.count)
                        if model.settings.moreOpen {
                            ForEach(Array(quietRows.enumerated()), id: \.element) { i, k in
                                StemRow(kind: k, index: mainRows.count + i, quiet: true)
                            }
                        }
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: CGFloat.self) { g in
                max(0, g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom - g.visibleRect.height)
            } action: { _, o in
                overflow = o
            }
            .onScrollPhaseChange { _, phase in
                // Only the person's own scrolling counts: the hint's peek is an animated scroll.
                if phase == .interacting || phase == .tracking {
                    userScrolled = true
                    if hintCount != nil { withAnimation(.easeOut(duration: 0.2)) { hintCount = nil } }
                }
            }
            .scrollPosition($scroll)
            .overlay(alignment: .bottom) {
                if let n = hintCount {
                    ScrollHintPill(hidden: n) { revealNextRow() }
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .task(id: model.song?.id) { await runScrollHint() }
            .background {
                // The Stage light (2.8) behind the parts, in the dark look only.
                if showsStageLight {
                    StageLight(engine: model.engine, config: stageLight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // The Deck's time row (3.4): elapsed left, remaining right, the big numeral while scrubbing.
            TimeRow()
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            TransportBar()
        }
        .overlay { CountInOverlay() }
        .onAppear { if landParts { startLanding() } }
    }

    /// One row and its spacing: how far a click on the hint scrolls, and how many rows the overflow hides.
    private var rowStep: CGFloat { (model.stems.count <= 4 ? 64 : 52) + 6 }

    /// 0.9 s after the player appears (1.6 s after a split, once the parts have landed): the pill and, without
    /// Reduce Motion, a 56 pt peek and back.
    private func runScrollHint() async {
        userScrolled = false
        hintCount = nil
        try? await Task.sleep(for: .milliseconds(landParts ? 1600 : 900))
        guard !Task.isCancelled, overflow > 8, !userScrolled, ScrollHintPolicy.mayShow else { return }
        ScrollHintPolicy.recordShown()
        let hidden = max(1, min(model.stems.count, Int((overflow / rowStep).rounded(.up))))
        withAnimation(.easeOut(duration: 0.25)) { hintCount = hidden }
        if !reduceMotion {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { scroll.scrollTo(y: min(56, overflow)) }
            try? await Task.sleep(for: .milliseconds(450 + 550))
            guard !Task.isCancelled, !userScrolled else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { scroll.scrollTo(y: 0) }
        }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) { hintCount = nil }
    }

    private func revealNextRow() {
        withAnimation(.easeOut(duration: 0.2)) { hintCount = nil }
        withAnimation(Motion.animation(.smooth(duration: 0.4))) { scroll.scrollTo(y: min(overflow, rowStep)) }
    }

    /// The end of a split: hold the rows for the cross-fade, then insert them so each lands 0.11 s after the one
    /// above, as the kit parts do. Reduce Motion fades them in.
    private func startLanding() {
        onLanded()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            landing = true
            withAnimation(.smooth(duration: 0.3)) { holdingRows = false }
            try? await Task.sleep(for: .milliseconds(1200))
            landing = false
        }
    }

    /// The Stage light shines only in the dark look; the light look keeps the plain canvas.
    private var showsStageLight: Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--no-stagelight") { return false }
        #endif
        return Theme.isDark && stageLightOn
    }

    /// One lamp per part in the main list, in its colour mixed 60 % toward the accent; dark when it is off.
    private var stageLight: StageLightConfig {
        let tracks = model.loadedTracks
        let lamps = model.rows.filter { !$0.quiet }.map { row in
            StageLightConfig.Lamp(color: StageLightConfig.mix(BacklineColors.stemColor(row.kind.hue, dark: true),
                                                              BacklineColors.dark.accent, 0.6),
                                  on: model.isAudible(row.kind),
                                  tracks: row.leaves.compactMap { tracks.firstIndex(of: $0) })
        }
        return StageLightConfig(lamps: lamps, live: !reduceMotion)
    }

    /// The main list, then "More parts" for the parts that are probably not in this song (U05).
    private var mainRows: [StemKind] { model.rows.filter { !$0.quiet }.map(\.kind) }
    private var quietRows: [StemKind] { model.rows.filter(\.quiet).map(\.kind) }
}

/// Large 1-2-3-4 during the count-in so it's readable from across the room with a guitar on.
struct CountInOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let beat = model.countInBeat
        let label = model.countInLabel
        let accent = beat == 1 && model.mode != .dance
        ZStack {
            if beat > 0 {
                Text("\(label)")
                    .font(Typo.ui(64, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 120)
                    .background(Circle().fill(accent ? Theme.magenta.opacity(0.9) : Theme.primary.opacity(0.92)))
                    .glassSurface(Circle(), fallback: .clear)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: (accent ? Theme.magenta : Theme.primary).opacity(0.5), radius: 30)
                    .id(beat)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityLabel("Count-in, \(label)")
            }
        }
        .motion(.spring(duration: 0.18), value: beat)
        .allowsHitTesting(false)
    }
}

// MARK: - Header

struct SongHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout

    var body: some View {
        HStack(spacing: 16) {
            ArtworkTile(image: model.artwork, cover: model.song.map { ($0.title, model.stems, $0.id) })
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(model.song?.title ?? "")
                        .font(Typo.ui(20, .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    // The cleaner pass in a capsule beside the title, so the line under it (artist, key, tempo)
                    // always shows in full (as on iOS, where it sits in the parts header).
                    if let p = model.hqProgress {
                        CleaningCapsule(fraction: p)
                            .help("Backline is splitting the song again with a sharper model. You can keep playing.")
                            .transition(.opacity)
                    } else if !model.heldBackPasses.isEmpty {
                        HeldBackCapsule()
                            .help("Backline stopped improving this song's parts after two tries. The song plays as it is.")
                            .transition(.opacity)
                    }
                }
                .motion(.smooth(duration: 0.25), value: model.hqProgress == nil)
                HStack(spacing: 10) {
                    if let artist = model.song?.artist { Text(artist).font(Typo.ui(13)) }
                    Text(metaLine).font(Typo.mono(12.5))
                    if model.mode == .dance { DanceStyleMenu() }
                    if model.bpm > 0 { TempoMenu() }
                    Text(model.song?.durationString ?? "").font(Typo.mono(12.5))
                }
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            ModeSwitch(compact: layout == .compact)
            Button { model.addSong() } label: {
                if layout == .compact {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                } else {
                    Text("Add a song…")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Add a song: a file, a link, or record from an app · ⌘O")
        }
    }

    var metaLine: String {
        guard let song = model.song else { return "" }
        return song.analysis.key ?? ""
    }
}

/// "Cleaning 42%" while the cleaner pass runs (ported from iOS `MixerView.swift`). "Cleaning…" with no figure until
/// the first chunk ends, so it never reads as a stuck 0%.
struct CleaningCapsule: View {
    let fraction: Double
    static func text(_ fraction: Double) -> String {
        fraction < 0.01 ? "Cleaning…" : "Cleaning \(Int(fraction * 100))%"
    }
    var body: some View {
        Text(Self.text(fraction))
            .font(Typo.ui(12, .semibold))
            .foregroundStyle(Theme.ink2)
            .contentTransition(.numericText())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(minHeight: 20)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.hairline3))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A pass that failed twice on this song (D20 d) isn't started again by itself: "Didn't finish · Try again"
/// where "Cleaning 42%" shows while one runs. The song plays as it is meanwhile. Ported from iOS `MixerView.swift`.
struct HeldBackCapsule: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button {
            model.retryHeldBack()
        } label: {
            HStack(spacing: 4) {
                Text("Didn't finish").foregroundStyle(Theme.ink2)
                Text("· Try again").foregroundStyle(Theme.primaryTint)
            }
            .font(Typo.ui(12, .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .frame(minHeight: 20)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.hairline3))
            .lineLimit(1)
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Improving this song's parts didn't finish. Try again")
        .accessibilityIdentifier("heldBack.tryAgain")
    }
}

/// The parts land, staggered, like tape pressed down (after a split, and the kit parts the moment they arrive
/// from the extra parts download); a cross-fade with Reduce Motion. Nothing else in the list ever moves.
/// Ported from iOS `MixerView.swift`.
private struct PartLanding: ViewModifier {
    let index: Int
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(active ? landing : .identity)
    }

    private var landing: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: Landed(scale: 1.035, angle: -1.2, drop: -8), identity: Landed(scale: 1, angle: 0, drop: 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.7).delay(Double(index) * 0.11)),
            removal: .opacity)
    }

    private struct Landed: ViewModifier {
        let scale: CGFloat
        let angle: Double
        let drop: CGFloat
        func body(content: Content) -> some View {
            content.scaleEffect(scale).rotationEffect(.degrees(angle)).offset(y: drop).opacity(drop == 0 ? 1 : 0)
        }
    }
}

struct ArtworkTile: View {
    let image: NSImage?
    var size: CGFloat = 56
    /// Title, parts and id for a `TapeCover` when the song has no artwork (as on iOS).
    var cover: (title: String, parts: [StemKind], id: String)?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .accessibilityHidden(true)
            } else if let cover {
                TapeCover(title: cover.title, parts: cover.parts, id: cover.id)
            } else {
                Canvas { ctx, sz in
                    ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(Theme.card))
                    var x: CGFloat = -sz.height
                    while x < sz.width {
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: sz.height))
                        p.addLine(to: CGPoint(x: x + sz.height, y: 0))
                        p.addLine(to: CGPoint(x: x + sz.height + 6, y: 0))
                        p.addLine(to: CGPoint(x: x + 6, y: sz.height))
                        ctx.fill(p, with: .color(Theme.cardHover))
                        x += 12
                    }
                }
                .overlay(Image(systemName: "music.note").font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(Theme.muted.opacity(0.7)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous).strokeBorder(Theme.hairline2))
    }
}

// MARK: - "I'm playing"

struct PlayingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 12) {
            Text("I'm playing")
                .font(Typo.ui(13, .semibold))
                .foregroundStyle(Theme.ink2)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.stems.filter { $0 != .other }) { k in
                        PlayingPill(kind: k, active: model.playingStem == k, ns: ns) { model.choosePlaying(k) }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: layout != .compact, vertical: false)
            Spacer(minLength: 0)
            GuideToggle()
            RoleChip()
            if layout == .wide {
                Text(model.settings.removed.isEmpty ? "Full band" : "\(model.settings.removed.count) removed")
                    .font(Typo.ui(12))
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                    .fixedSize()
            }
        }
        .motion(.smooth(duration: 0.22), value: model.settings.removed)
    }
}

struct PlayingPill: View {
    let kind: StemKind
    let active: Bool
    let ns: Namespace.ID
    var title: String?
    var helpText: String?
    var accessibility: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title ?? kind.shortName)
            }
            .font(Typo.ui(12.5, .semibold))
            .foregroundStyle(active ? Theme.magentaText : Theme.ink2)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background {
                if active {
                    Capsule().fill(Theme.magenta.opacity(0.16))
                        .overlay(Capsule().strokeBorder(Theme.magenta.opacity(0.6)))
                        .matchedGeometryEffect(id: "pill", in: ns)
                } else {
                    Capsule().fill(hover ? Theme.cardHover : Theme.card)
                        .overlay(Capsule().strokeBorder(Theme.hairline2))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(helpText ?? (active ? "Bring \(kind.name.lowercased()) back" : "Remove \(kind.name.lowercased()) so you can play it"))
        .accessibilityLabel(accessibility ?? "I'm playing \(kind.name)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// "108 BPM ▾" — pick half-time / as detected / double-time. Detection can land on either octave in
/// metal (double-kick vs half-time feel); this is the one-click fix.
struct TempoMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let detected = model.detectedBPM
        Menu {
            Section("Pick the one your foot taps") {
                Button { model.setTempoScale(0.5) } label: {
                    Label("\(Int((detected / 2).rounded())) · half-time", systemImage: model.settings.tempoScale == 0.5 ? "checkmark" : "")
                }
                Button { model.setTempoScale(1) } label: {
                    Label("\(Int(detected.rounded())) · Backline's guess", systemImage: model.settings.tempoScale == 1 ? "checkmark" : "")
                }
                Button { model.setTempoScale(2) } label: {
                    Label("\(Int((detected * 2).rounded())) · double-time", systemImage: model.settings.tempoScale == 2 ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Tempo \(Int(model.bpm.rounded()))")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Typo.mono(12.5))
            .foregroundStyle(model.settings.tempoScale == 1 ? (hover ? Theme.ink2 : Theme.muted) : Theme.primaryTint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.card : .clear))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help("The beat for the count-in and click. Change it if it feels twice or half as fast.")
    }
}

/// "Guide": your removed part plays quietly (−15 dB) so you can follow it while you learn.
struct GuideToggle: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let on = model.settings.guide
        let enabled = !model.settings.removed.isEmpty
        Button { model.settings.guide.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "ear.fill" : "ear")
                    .font(.system(size: 11, weight: .semibold))
                Text("Guide").font(Typo.ui(12.5, .semibold))
            }
            .foregroundStyle(on ? Theme.primaryTint : (hover ? Theme.ink2 : Theme.muted))
            .padding(.vertical, 6).padding(.horizontal, 11)
            .background(Capsule().fill(on ? Theme.primary.opacity(0.18) : (hover ? Theme.card : .clear)))
            .overlay(Capsule().strokeBorder(on ? Theme.primary.opacity(0.55) : Theme.hairline2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
        .help("Hear your part quietly so you can follow along · G")
        .accessibilityLabel("Guide")
        .accessibilityValue(on ? "On" : "Off")
        .motion(.easeOut(duration: 0.15), value: on)
    }
}

// MARK: - Practice modes

/// Play · Dance · Beats. One switch re-dresses the screen for who is practising.
struct ModeSwitch: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PracticeMode.allCases) { m in
                let on = model.mode == m
                Button { withAnimation(Motion.animation(.smooth(duration: 0.25))) { model.setMode(m) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.symbol).font(.system(size: 11, weight: .semibold))
                        if !compact { Text(m.title).font(Typo.ui(12.5, .semibold)) }
                    }
                    .foregroundStyle(on ? Theme.ink : Theme.muted)
                    .padding(.vertical, 6).padding(.horizontal, compact ? 9 : 12)
                    .background {
                        if on {
                            Capsule().fill(Theme.primary.opacity(0.32))
                                .overlay(Capsule().strokeBorder(Theme.primary.opacity(0.7)))
                                .matchedGeometryEffect(id: "mode", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Self.help(m))
                .accessibilityLabel("\(m.title) mode")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.hairline2))
        .fixedSize()
    }

    static func help(_ m: PracticeMode) -> String {
        switch m {
        case .play: "Play: turn off your part and play along · ⌘1"
        case .dance: "Dance: hear one instrument and see the counts · ⌘2"
        case .beats: "Beats: the singer is off, and loops snap to bars · ⌘3"
        }
    }
}

/// Dance: "Listen for" brings one part forward (the rest plays quietly) to learn musicality.
struct ListenForRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 12) {
            Text("Listen for")
                .font(Typo.ui(13, .semibold))
                .foregroundStyle(Theme.ink2)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.danceListenParts) { k in
                        let name = model.label(k)
                        PlayingPill(kind: k, active: model.settings.spotlight == k, ns: ns, title: name,
                                    helpText: model.settings.spotlight == k ? "Hear the whole band again" : "Hear the \(name.lowercased()) up front",
                                    accessibility: "Listen for \(name)") { model.toggleSpotlight(k) }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: layout != .compact, vertical: false)
            Spacer(minLength: 0)
            if layout == .wide {
                Text(model.settings.spotlight.map { "\(model.label($0)) up front" } ?? "Whole band")
                    .font(Typo.ui(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
            }
        }
        .motion(.smooth(duration: 0.22), value: model.settings.spotlight)
    }
}

/// Beats: one tap loops 1, 2, 4 or 8 bars, starting on the bar line you're in.
struct BarLoopRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 12) {
            Text("Loop")
                .font(Typo.ui(13, .semibold))
                .foregroundStyle(Theme.ink2)
            HStack(spacing: 6) {
                ForEach([1, 2, 4, 8], id: \.self) { n in
                    BarChip(bars: n, active: model.loopBarCount == n, ns: ns) { model.loopBars(n) }
                }
            }
            .fixedSize()
            Spacer(minLength: 0)
            GuideToggle()
        }
        .motion(.smooth(duration: 0.22), value: model.loopBarCount)
    }
}

struct BarChip: View {
    let bars: Int
    let active: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(bars == 1 ? "1 bar" : "\(bars) bars")
                .font(Typo.ui(12.5, .semibold))
                .foregroundStyle(active ? Theme.magentaText : Theme.ink2)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background {
                    if active {
                        Capsule().fill(Theme.magenta.opacity(0.16))
                            .overlay(Capsule().strokeBorder(Theme.magenta.opacity(0.6)))
                            .matchedGeometryEffect(id: "bars", in: ns)
                    } else {
                        Capsule().fill(hover ? Theme.cardHover : Theme.card)
                            .overlay(Capsule().strokeBorder(Theme.hairline2))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(active ? "Stop the loop" : "Loop \(bars == 1 ? "this bar" : "\(bars) bars from this bar"). It starts right on the beat.")
        .accessibilityLabel("Loop \(bars) \(bars == 1 ? "bar" : "bars")")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// "Bachata ▾": the dance style sets the part names and the tempo dancers count.
struct DanceStyleMenu: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(DanceStyle.allCases) { s in
                Button { model.setDanceStyle(s) } label: {
                    Label(s.title, systemImage: model.danceStyle == s ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.danceStyle.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(Typo.ui(12.5, .semibold))
            .foregroundStyle(hover ? Theme.ink : Theme.primaryTint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.card : .clear))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help("The dance style. It sets the part names and the counting speed.")
    }
}

/// Beats: the open Music group's heading. Click it to fold the parts back into one Music row.
struct MusicHeader: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        Button { withAnimation(Motion.animation(.smooth(duration: 0.25))) { model.toggleMusicOpen() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                Text("Music").font(Typo.ui(12.5, .semibold))
                Text("· click to put the parts back together").font(Typo.ui(11.5)).foregroundStyle(Theme.muted)
                Spacer()
            }
            .foregroundStyle(hover ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Put the Music parts back together")
    }
}

/// "More parts · 2 / Quiet in this song": the parts the level gate thinks are not really in the song.
/// Closed by default; they still play at their normal level.
struct MorePartsRow: View {
    @Environment(AppModel.self) private var model
    let count: Int
    @State private var hover = false

    var body: some View {
        let open = model.settings.moreOpen
        Button { withAnimation(Motion.animation(.smooth(duration: 0.25))) { model.updateSettings { $0.moreOpen.toggle() } } } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .frame(width: 16)
                Text("More parts · \(count)").font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.ink2)
                Text("· quiet in this song").font(Typo.ui(11.5)).foregroundStyle(Theme.muted)
                Spacer()
            }
            .foregroundStyle(hover ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.elevated.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(open ? "Hide the parts that are quiet in this song" : "Show the parts that are quiet in this song")
        .accessibilityLabel(open ? "Hide the \(count) quiet parts" : "Show the \(count) quiet parts")
    }
}
