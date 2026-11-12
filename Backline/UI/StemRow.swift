import BacklineKit
import SwiftUI

struct StemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout
    let kind: StemKind
    let index: Int
    /// Listed under "More parts": probably not in this song (U05). It still plays and stays controllable.
    var quiet = false
    @State private var hover = false
    /// The fader's value while it is being dragged (nil otherwise).
    @State private var dragVolume: Double?

    var body: some View {
        let on = model.isOn(kind)
        let audible = model.isAudible(kind)
        let soloed = model.settings.solo == kind
        let shown = dragVolume ?? model.settings.volume(kind)
        HStack(spacing: 14) {
            StemToggle(isOn: on, color: kind.color) { model.toggle(kind) }
                .help(on ? "Remove \(model.label(kind).lowercased())" : "Bring \(model.label(kind).lowercased()) back")
                .accessibilityLabel(model.label(kind))
                .accessibilityValue(on ? "Playing" : "Removed")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(layout == .compact ? model.shortLabel(kind) : model.label(kind))
                        .font(Typo.ui(14, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(on ? Theme.ink : Theme.muted)
                    if model.mode == .beats, kind == .other, model.musicCanOpen, !model.musicIsOpen {
                        Button { withAnimation(Motion.animation(.smooth(duration: 0.25))) { model.toggleMusicOpen() } } label: {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.primaryTint)
                        }
                        .buttonStyle(.plain)
                        .help("Show the parts in Music: guitars, keys and the rest")
                        .accessibilityLabel("Show the parts in Music")
                    }
                    Text("\(index + 1)")
                        .font(Typo.mono(9.5, .medium))
                        .foregroundStyle(Theme.muted.opacity(hover ? 0.9 : 0))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.muted.opacity(hover ? 0.4 : 0)))
                }
                Text(status(on: on, audible: audible))
                    .font(Typo.ui(11, .semibold))
                    .foregroundStyle(on ? Theme.muted : Theme.magenta)
                    .contentTransition(.opacity)
            }
            .frame(width: layout == .compact ? 110 : 130, alignment: .leading)

            if layout == .compact { Spacer(minLength: 0) } else {
            // Drawn by Metal with the playhead from the transport clock, so the row never re-renders while the
            // song plays (UIP-07).
            WaveformView(config: WaveformConfig(
                values: model.rowPeaks(kind), normalize: true,
                barColor: audible ? kind.color : Theme.inaudibleBar, playedColor: nil,
                barAlpha: audible ? 0.35 + 0.65 * shown / 100 : 0.5, minBarHeight: 2, barPitch: 4, gap: 2,
                duration: max(model.duration, 0.001), showPlayhead: true, playheadColor: Theme.ink.opacity(0.5),
                playheadWidth: 1, glow: 0, dark: Theme.isDark))
                .frame(height: model.stems.count <= 4 ? 48 : 36)
                // Part rows never seek (3.4): a stray tap on a part must not lose your place in the song.
                // Seeking lives on the Map, where it is one gesture and one engine seek.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            SoloButton(active: soloed) { model.toggleSolo(kind) }

            // A drag is heard at once but written once, on release (UIP-03); the number follows the drag.
            StemSlider(value: shown, tint: kind.color, enabled: audible,
                       onDrag: { v in
                           if v != dragVolume { dragVolume = v; model.previewVolume(kind, v) }
                       },
                       onCommit: { v in
                           dragVolume = nil
                           model.setVolume(kind, v)
                       })
                .frame(width: 110)
                .accessibilityLabel("\(model.label(kind)) volume")
            Text("\(Int(shown))")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 30, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Theme.elevated : Theme.elevated.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(hover ? 0.06 : 0))
        )
        .onHover { hover = $0 }
        .opacity(quiet ? 0.72 : 1)
        .motion(.smooth(duration: 0.2), value: on)
        .motion(.smooth(duration: 0.2), value: audible)
        .contextMenu {
            Button(on ? "Remove \(model.label(kind))" : "Bring Back \(model.label(kind))") { model.toggle(kind) }
            Button(soloed ? "Hear All Parts" : "Hear Only \(model.label(kind))") { model.toggleSolo(kind) }
            Divider()
            Button("Reset Volume") { model.setVolume(kind, 80) }
        }
    }

    func status(on: Bool, audible: Bool) -> String {
        if kind == .drums, let p = model.drumSplitProgress { return p < 0.01 ? "Splitting kit…" : "Splitting kit \(Int(p * 100))%" }
        if kind == .drums, model.mode == .beats, model.downloadingModel == DrumSeparator.modelName,
           let p = model.modelDownloadProgress { return "Getting the kit model · \(Int(p * 100))%" }
        if model.settings.solo == kind && !on { return "Alone · not saved" }
        if !on { return model.settings.guide && model.settings.solo == nil ? "Guide (quiet)" : "Removed" }
        if !audible { return "Off while S is on" }
        return "Playing"
    }
}

/// 36 × 20 pill toggle with a 16 px knob; the stem colour when on.
struct StemToggle: View {
    let isOn: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? color : Theme.toggleOff)
                Circle()
                    .fill(Theme.ink)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
            .frame(width: 36, height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .motion(.spring(response: 0.25, dampingFraction: 0.75), value: isOn)
    }
}

struct SoloButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text("S")
                .font(Typo.ui(11, .bold))
                .foregroundStyle(active ? Theme.bg : (hover ? Theme.ink2 : Theme.muted))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? Theme.warning : Theme.cardHover))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(active ? "Hear all parts again" : "Hear only this part")
        .accessibilityLabel("Hear only this part")
        .accessibilityAddTraits(active ? .isSelected : [])
        .motion(.easeOut(duration: 0.12), value: active)
    }
}

/// Thin tinted volume slider (0–100). A drag reports each new value to `onDrag` and the last one to `onCommit`;
/// a double-click resets to 80, and VoiceOver's adjustments commit at once.
struct StemSlider: View {
    let value: Double
    let tint: Color
    var enabled = true
    var onDrag: (Double) -> Void
    var onCommit: (Double) -> Void
    @State private var dragging = false
    @State private var hover = false
    /// The last step this drag reached, committed when it ends.
    @State private var dragged: Double?
    /// True while the button is down. SwiftUI puts it back when the gesture ends or the system cancels it, and a
    /// cancelled gesture never calls `onEnded`; so this is what commits a cancelled drag, which the engine was
    /// already playing (release review ios-ui-links#3).
    @GestureState private var held = false

    static func value(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return (Double(max(0, min(width, x)) / width) * 100).rounded()
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = w * value / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.toggleOff).frame(height: 4)
                Capsule().fill(enabled ? tint : Theme.muted).frame(width: max(4, x), height: 4)
                Circle()
                    .fill(Theme.ink)
                    .frame(width: dragging || hover ? 14 : 12, height: dragging || hover ? 14 : 12)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: min(max(0, x - 6), w - 12))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($held) { _, held, _ in held = true }
                .onChanged { v in
                    dragging = true
                    let nv = Self.value(atX: v.location.x, width: w)
                    dragged = nv
                    if nv != value { onDrag(nv) }
                }
                .onEnded { v in
                    dragged = Self.value(atX: v.location.x, width: w)
                    finishDrag()
                })
            .onChange(of: held) { _, down in if !down { finishDrag() } }
            .onTapGesture(count: 2) { onCommit(80) }
            .onHover { hover = $0 }
        }
        .frame(height: 20)
        .motion(.easeOut(duration: 0.1), value: dragging || hover)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { onCommit($0.rounded()) }), in: 0...100, step: 1)
        }
    }

    /// The button came up or the system cancelled the drag: the one write, once (whichever comes first).
    private func finishDrag() {
        dragging = false
        guard let v = dragged else { return }
        dragged = nil
        onCommit(v)
    }
}
