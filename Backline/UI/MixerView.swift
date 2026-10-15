import BacklineKit
import SwiftUI

struct MixerView: View {
    @Environment(AppModel.self) private var model

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
            .animation(.smooth(duration: 0.25), value: model.mode)
            OverviewCard()
                .padding(.horizontal, 24)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(model.stems.enumerated()), id: \.element) { i, k in
                        if model.mode == .beats, model.musicIsOpen, k == model.musicLeaves.first { MusicHeader() }
                        StemRow(kind: k, index: i)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
            }
            .scrollIndicators(.never)
            TransportBar()
        }
        .overlay { CountInOverlay() }
    }
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
        .animation(.spring(duration: 0.18), value: beat)
        .allowsHitTesting(false)
    }
}

// MARK: - Header

struct SongHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout

    var body: some View {
        HStack(spacing: 16) {
            ArtworkTile(image: model.artwork)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.song?.title ?? "")
                    .font(Typo.ui(20, .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let artist = model.song?.artist { Text(artist).font(Typo.ui(13)) }
                    Text(metaLine).font(Typo.mono(12.5))
                    if model.mode == .dance { DanceStyleMenu() }
                    if model.bpm > 0 { TempoMenu() }
                    Text(model.song?.durationString ?? "").font(Typo.mono(12.5))
                    if model.hqProgress == nil, model.downloadingModel == CleanerPartsJob.modelName, model.song?.separator == nil,
                       let p = model.modelDownloadProgress {
                        Text("Getting the sharper model · \(Int(p * 100))%")
                            .font(Typo.ui(12))
                            .foregroundStyle(Theme.muted)
                            .help("A one-time download. Then Backline makes the parts of new songs cleaner.")
                    }
                    if let p = model.hqProgress {
                        Text("Making the parts cleaner · \(Int(p * 100))%")
                            .font(Typo.ui(12))
                            .foregroundStyle(Theme.primaryTint)
                            .contentTransition(.numericText())
                            .help("Backline is splitting the song again with a sharper model. You can keep playing.")
                    }
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
            .help("Add a song: a file, a YouTube link, or record from an app · ⌘O")
        }
    }

    var metaLine: String {
        guard let song = model.song else { return "" }
        return song.analysis.key ?? ""
    }
}

struct ArtworkTile: View {
    let image: NSImage?
    var size: CGFloat = 56
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
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
            if layout == .wide {
                Text(model.settings.removed.isEmpty ? "Full band" : "\(model.settings.removed.count) removed")
                    .font(Typo.ui(12))
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                    .fixedSize()
            }
        }
        .animation(.smooth(duration: 0.22), value: model.settings.removed)
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
        .animation(.easeOut(duration: 0.15), value: on)
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
                Button { withAnimation(.smooth(duration: 0.25)) { model.setMode(m) } } label: {
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
        .animation(.smooth(duration: 0.22), value: model.settings.spotlight)
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
        .animation(.smooth(duration: 0.22), value: model.loopBarCount)
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
        Button { withAnimation(.smooth(duration: 0.25)) { model.toggleMusicOpen() } } label: {
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
