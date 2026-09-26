import BacklineKit
import SwiftUI

struct StemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout
    let kind: StemKind
    let index: Int
    @State private var hover = false

    var body: some View {
        let on = model.isOn(kind)
        let audible = model.isAudible(kind)
        let soloed = model.settings.solo == kind
        let vol = model.settings.volume(kind)
        HStack(spacing: 14) {
            StemToggle(isOn: on, color: kind.color) { model.toggle(kind) }
                .help(on ? "Remove \(kind.name.lowercased())" : "Bring \(kind.name.lowercased()) back")
                .accessibilityLabel(kind.name)
                .accessibilityValue(on ? "Playing" : "Removed")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(layout == .compact ? kind.shortName : kind.name)
                        .font(Typo.ui(14, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(on ? Theme.ink : Theme.muted)
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
            StemWaveform(peaks: model.song?.peaks(for: kind) ?? [], color: kind.color, audible: audible, volume: vol)
                .frame(height: model.stems.count <= 4 ? 48 : 36)
                .overlay {
                    GeometryReader { g in
                        Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1)
                            .offset(x: g.size.width * model.position / max(model.duration, 0.001))
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    GeometryReader { g in
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { p in
                                model.seek(to: Double(max(0, min(g.size.width, p.x)) / g.size.width) * model.duration)
                            }
                    }
                }

            }

            SoloButton(active: soloed) { model.toggleSolo(kind) }

            StemSlider(value: Binding(get: { vol }, set: { model.setVolume(kind, $0) }), tint: kind.color, enabled: audible)
                .frame(width: 110)
                .accessibilityLabel("\(kind.name) volume")
            Text("\(Int(vol))")
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
        .animation(.smooth(duration: 0.2), value: on)
        .animation(.smooth(duration: 0.2), value: audible)
        .contextMenu {
            Button(on ? "Remove \(kind.name)" : "Bring Back \(kind.name)") { model.toggle(kind) }
            Button(soloed ? "Hear All Parts" : "Hear Only \(kind.name)") { model.toggleSolo(kind) }
            Divider()
            Button("Reset Volume") { model.setVolume(kind, 80) }
        }
    }

    func status(on: Bool, audible: Bool) -> String {
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
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isOn)
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
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

/// Thin tinted volume slider (0–100).
struct StemSlider: View {
    @Binding var value: Double
    let tint: Color
    var enabled = true
    @State private var dragging = false
    @State private var hover = false

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
                .onChanged { v in dragging = true; value = (max(0, min(w, v.location.x)) / w * 100).rounded() }
                .onEnded { _ in dragging = false })
            .onTapGesture(count: 2) { value = 80 }
            .onHover { hover = $0 }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.1), value: dragging || hover)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...100, step: 1)
        }
    }
}

struct StemWaveform: View {
    let peaks: [Float]
    let color: Color
    let audible: Bool
    let volume: Double

    var body: some View {
        GeometryReader { g in
            let count = max(20, Int(g.size.width / 4))
            let bars = normalised(Peaks.resample(peaks, to: count))
            Canvas { ctx, size in
                let gap: CGFloat = 2
                let w = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                var path = Path()
                for (i, v) in bars.enumerated() {
                    let h = max(2, CGFloat(v) * size.height)
                    path.addRoundedRect(in: CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h),
                                        cornerSize: CGSize(width: 1, height: 1))
                }
                ctx.fill(path, with: .color(audible ? color : Theme.inaudibleBar))
            }
            .opacity(audible ? 0.35 + 0.65 * volume / 100 : 0.5)
            .drawingGroup()
        }
    }

    /// Per-stem normalisation with a gentle curve so quiet stems are still readable.
    func normalised(_ b: [Float]) -> [Float] {
        let m = max(b.max() ?? 1, 1e-6)
        return b.map { pow($0 / m, 0.8) }
    }
}
