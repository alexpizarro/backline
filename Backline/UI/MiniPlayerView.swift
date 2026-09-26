import AppKit
import BacklineKit
import SwiftUI

/// Compact always-on-top practice remote: transport, loop, speed, pitch and the "I'm playing" choice,
/// so Backline can sit in a corner while tabs, YouTube or a DAW take the screen.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    var onExpand: () -> Void = {}

    var body: some View {
        Group {
            if model.song != nil {
                player
            } else {
                emptyState
            }
        }
        .padding(12)
        .frame(width: 440)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(count: 2, perform: onExpand)
        // Dark tinted Liquid Glass: refracts whatever is behind the floating window but keeps the
        // Backline palette legible over light web pages and tab viewers.
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: Theme.bg.opacity(0.78), fallback: Theme.chrome)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list").foregroundStyle(Theme.primaryTint)
            Text("Open a song in Backline").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink2)
            Spacer()
            expandButton
        }
        .frame(height: 44)
    }

    private var player: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ArtworkTile(image: model.artwork, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.song?.title ?? "")
                        .font(Typo.ui(13, .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        Text(formatTime(model.position)).foregroundStyle(Theme.ink2)
                        Text(" / \(formatTime(model.duration))").foregroundStyle(Theme.muted)
                    }
                    .font(Typo.mono(11))
                }
                Spacer(minLength: 6)
                PlayButton(isPlaying: model.isPlaying, countInBeat: model.countInBeat) { model.togglePlay() }
                    .scaleEffect(0.86)
                expandButton
            }

            MiniWaveform()
                .frame(height: 30)

            HStack(spacing: 8) {
                LoopChip(compact: true)
                ABButton(compact: true)
                MiniStepper(label: "\(model.settings.trainer.enabled && model.settings.loopEnabled ? model.liveSpeed : model.settings.speed)%",
                            symbol: "tortoise", highlighted: model.settings.speed != 100,
                            down: { model.stepSpeed(-1) }, up: { model.stepSpeed(1) })
                    .help("Speed · ⌘← ⌘→")
                MiniStepper(label: formatPitch(model.settings.pitch), symbol: "tuningfork",
                            highlighted: model.settings.pitch != 0,
                            down: { model.stepPitch(-1) }, up: { model.stepPitch(1) })
                    .help("Pitch · ⌘↓ ⌘↑")
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                Text("I'm playing").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.muted)
                ForEach(model.stems.filter { $0 != .other && $0 != .keys }) { k in
                    let active = model.playingStem == k
                    Button { model.choosePlaying(k) } label: {
                        Text(k.shortName)
                            .font(Typo.ui(11, .semibold))
                            .foregroundStyle(active ? Theme.magentaText : Theme.ink2)
                            .padding(.vertical, 4).padding(.horizontal, 9)
                            .background(Capsule().fill(active ? Theme.magenta.opacity(0.18) : Color.white.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(active ? Theme.magenta.opacity(0.6) : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Back to the full window · ⌘⇧M")
    }
}

struct MiniStepper: View {
    let label: String
    let symbol: String
    var highlighted = false
    let down: () -> Void
    let up: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: down) { Text("−").frame(width: 22, height: 24) }.buttonStyle(.plain)
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                Text(label).font(Typo.mono(11.5)).foregroundStyle(highlighted ? Theme.primaryTint : Theme.ink)
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 56)
            Button(action: up) { Text("+").frame(width: 22, height: 24) }.buttonStyle(.plain)
        }
        .font(Typo.ui(13, .bold))
        .foregroundStyle(Theme.ink2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .buttonRepeatBehavior(.enabled)
    }
}

/// Mix waveform with loop region and playhead; click or drag to seek.
struct MiniWaveform: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dur = max(model.duration, 0.001)
            ZStack(alignment: .leading) {
                if model.settings.loopEnabled, let r = model.loopRange {
                    Rectangle().fill(Theme.magenta.opacity(0.14))
                        .frame(width: max(2, w * (r.upperBound - r.lowerBound) / dur))
                        .offset(x: w * r.lowerBound / dur)
                }
                WaveformBars(bars: model.mixBars(count: max(20, Int(w / 3))), progress: model.position / dur, minHeight: 2)
                Rectangle().fill(Theme.ink).frame(width: 2).shadow(color: .white.opacity(0.5), radius: 2)
                    .offset(x: w * model.position / dur - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in model.isScrubbing = true; model.seek(to: Double(max(0, min(w, v.location.x)) / w) * dur) }
                .onEnded { _ in model.isScrubbing = false })
        }
    }
}
