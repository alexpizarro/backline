import BacklineKit
import SwiftUI

struct MixerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SongHeader()
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
            PlayingRow()
                .padding(EdgeInsets(top: 0, leading: 24, bottom: 16, trailing: 24))
            OverviewCard()
                .padding(.horizontal, 24)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(model.stems.enumerated()), id: \.element) { i, k in
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
        ZStack {
            if beat > 0 {
                Text("\(beat)")
                    .font(Typo.ui(64, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 120)
                    .background(Circle().fill(beat == 1 ? Theme.magenta.opacity(0.9) : Theme.primary.opacity(0.92)))
                    .glassSurface(Circle(), fallback: .clear)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: (beat == 1 ? Theme.magenta : Theme.primary).opacity(0.5), radius: 30)
                    .id(beat)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityLabel("Count-in, beat \(beat) of 4")
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
                    if model.bpm > 0 { TempoMenu() }
                    Text(model.song?.durationString ?? "").font(Typo.mono(12.5))
                }
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
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
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(kind.shortName)
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
        .help(active ? "Bring \(kind.name.lowercased()) back" : "Remove \(kind.name.lowercased()) so you can play it")
        .accessibilityLabel("I'm playing \(kind.name)")
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
