import BacklineKit
import SwiftUI

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.layoutWidth) private var layout
    @State private var trainerPopover = false

    var body: some View {
        @Bindable var model = model
        Group {
            if layout == .compact {
                bar(spacing: 10, level: 3)
            } else {
                ViewThatFits(in: .horizontal) {
                    bar(spacing: 22, level: 0)
                    bar(spacing: 16, level: 1)
                    bar(spacing: 14, level: 2)
                    bar(spacing: 10, level: 3)
                }
            }
        }
        .padding(.horizontal, layout == .compact ? 14 : 24)
        .frame(height: 68)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    @ViewBuilder
    /// level 0: everything labelled · 1: short Export · 2: icon toggles, no Speed/Pitch words ·
    /// 3: minimal (narrow windows).
    func bar(spacing: CGFloat, level: Int) -> some View {
        @Bindable var model = model
        let compact = level >= 3
        let iconToggles = level >= 2
        let shortExport = level >= 1
        HStack(spacing: spacing) {
            PlayButton(isPlaying: model.isPlaying, countInBeat: model.countInBeat) { model.togglePlay() }

            HStack(spacing: 0) {
                Text(formatTime(model.position)).foregroundStyle(Theme.ink)
                if !compact { Text(" / \(formatTime(model.duration))").foregroundStyle(Theme.muted) }
            }
            .font(Typo.mono(13))
            .frame(width: compact ? 42 : 96, alignment: .leading)

            if !compact { Rectangle().fill(Theme.hairline2).frame(width: 1, height: 28) }

            LoopChip(compact: iconToggles)
            ABButton(compact: compact)

            HStack(spacing: 8) {
                if !iconToggles { Text("Speed").font(Typo.ui(12.5)).foregroundStyle(Theme.muted).fixedSize() }
                Stepper3(value: "\(model.settings.trainer.enabled && model.settings.loopEnabled ? model.liveSpeed : model.settings.speed)%",
                         highlighted: model.settings.speed != 100 || (model.settings.trainer.enabled && model.settings.loopEnabled),
                         down: { model.stepSpeed(-1) }, up: { model.stepSpeed(1) },
                         reset: { model.settings.trainer.enabled = false; model.settings.speed = 100 },
                         canDown: model.settings.speed > 50, canUp: model.settings.speed < 150)
                    .help("Slow down or speed up without changing pitch · ⌘← ⌘→")
                TrainerButton(active: model.settings.trainer.enabled) { trainerPopover.toggle() }
                    .popover(isPresented: $trainerPopover, arrowEdge: .top) { TrainerPopover() }
            }

            HStack(spacing: 8) {
                if iconToggles {
                    Image(systemName: "tuningfork").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                } else {
                    Text("Pitch").font(Typo.ui(12.5)).foregroundStyle(Theme.muted).fixedSize()
                }
                Stepper3(value: formatPitch(model.settings.pitch, compact: true),
                         highlighted: model.settings.pitch != 0,
                         down: { model.stepPitch(-1) }, up: { model.stepPitch(1) },
                         reset: { model.settings.pitch = 0 },
                         canDown: model.settings.pitch > -12, canUp: model.settings.pitch < 12)
                    .help("Pitch: \(formatPitch(model.settings.pitch)). Move it up or down one fret at a time · ⌘↑ ⌘↓")
            }

            CountInCheckbox(isOn: $model.settings.countIn, compact: iconToggles)
            ClickToggle(isOn: $model.settings.click, compact: iconToggles)

            Spacer(minLength: 0)

            Button {
                model.openExport()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                    if !compact { Text(shortExport ? "Save" : "Save backing track") }
                }
                .fixedSize()
            }
            .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)))
            .help("Save what you hear as a song file · ⌘E")
        }
    }
}

/// 42 px violet play button with Liquid Glass sheen; shows the count-in beat while counting.
struct PlayButton: View {
    let isPlaying: Bool
    let countInBeat: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if countInBeat > 0 {
                    Text("\(countInBeat)")
                        .font(Typo.ui(17, .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: isPlaying ? 0 : 1.5)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 42, height: 42)
            .background {
                // Solid base (always visible) with a Liquid Glass sheen on top.
                Circle().fill(LinearGradient(colors: [hover ? Theme.primaryHover : Theme.primary,
                                                      (hover ? Theme.primaryHover : Theme.primary).opacity(0.85)],
                                             startPoint: .top, endPoint: .bottom))
            }
            .modifier(PlayGlass())
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.03)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: Theme.primary.opacity(isPlaying ? 0.55 : 0.3), radius: isPlaying ? 12 : 6)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: countInBeat)
        .animation(.easeOut(duration: 0.15), value: hover)
        .help(isPlaying ? "Pause · Space" : "Play · Space")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct LoopChip: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var hover = false

    var body: some View {
        let on = model.settings.loopEnabled
        Button { model.toggleLoop() } label: {
            HStack(spacing: 8) {
                Image(systemName: "repeat").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(on ? Theme.magentaText : Theme.muted)
                if !compact {
                    Text("Loop").font(Typo.ui(12.5, .semibold))
                        .foregroundStyle(on ? Theme.magentaText : Theme.ink2)
                }
                Text(rangeText).font(Typo.mono(compact ? 11 : 11.5)).foregroundStyle(Theme.ink2).fixedSize()
                if on && model.settings.trainer.enabled {
                    Text("×\(model.loopPasses + 1)").font(Typo.mono(10.5)).foregroundStyle(Theme.magentaText.opacity(0.8))
                        .contentTransition(.numericText())
                }
            }
            .padding(.vertical, compact ? 5 : 7)
            .padding(.horizontal, compact ? 9 : 11)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? Theme.magenta.opacity(0.14) : (hover ? Theme.cardHover : Theme.card)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(on ? Theme.magenta.opacity(0.5) : Theme.hairline2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Loop a part · L. Click a part above, or hold Option and drag on the wave.")
        .animation(.easeOut(duration: 0.15), value: on)
    }

    var rangeText: String {
        if let a = model.loopCaptureA { return "\(formatTime(a))–…" }
        guard let r = model.loopRange else { return "–:––" }
        return "\(formatTime(r.lowerBound))–\(formatTime(r.upperBound))"
    }
}

/// Segmented − / value / + control.
struct Stepper3: View {
    let value: String
    var highlighted = false
    let down: () -> Void
    let up: () -> Void
    var reset: (() -> Void)?
    var canDown = true
    var canUp = true

    var body: some View {
        HStack(spacing: 0) {
            StepperHalf(symbol: "−", enabled: canDown, action: down)
            Rectangle().fill(Theme.hairline2).frame(width: 1)
            Text(value)
                .font(Typo.mono(12.5))
                .foregroundStyle(highlighted ? Theme.primaryTint : Theme.ink)
                .frame(width: 50)
                .contentTransition(.numericText())
                .contentShape(Rectangle())
                .onTapGesture { if NSEvent.modifierFlags.contains(.option) { reset?() } }
                .contextMenu { if let reset { Button("Reset", action: reset) } }
                .help("Option-click to reset")
            Rectangle().fill(Theme.hairline2).frame(width: 1)
            StepperHalf(symbol: "+", enabled: canUp, action: up)
        }
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline2))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.snappy(duration: 0.2), value: value)
    }
}

struct StepperHalf: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(Typo.ui(14, .bold))
                .foregroundStyle(enabled ? Theme.ink2 : Theme.muted.opacity(0.5))
                .frame(width: 30, height: 28)
                .background(hover && enabled ? Theme.cardHover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .buttonRepeatBehavior(.enabled)
    }
}

struct CountInCheckbox: View {
    @Binding var isOn: Bool
    var compact = false
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Theme.primary : .clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? Theme.primary : Color.white.opacity(0.25))
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 16, height: 16)
                if compact {
                    Text("1-4").font(Typo.mono(11, .semibold)).foregroundStyle(Theme.ink2).fixedSize()
                } else {
                    Text("Count-in").font(Typo.ui(12.5)).foregroundStyle(Theme.ink2).fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.2), value: isOn)
        .help("Four clicks before the music starts · K")
        .accessibilityLabel("Count-in")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct TrainerButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.primaryTint : (hover ? Theme.ink2 : Theme.muted))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.primary.opacity(0.2) : (hover ? Theme.cardHover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Speed trainer: starts slow, then speeds up each time the loop repeats")
    }
}

struct TrainerPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { model.settings.trainer.enabled }, set: { on in
                model.settings.trainer.enabled = on
                if on && !model.settings.loopEnabled { model.toggleLoop() }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed trainer").font(Typo.ui(14, .bold)).foregroundStyle(Theme.ink)
                    Text("Starts slow, speeds up as the loop repeats.").font(Typo.ui(12)).foregroundStyle(Theme.muted)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.primary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Start at").foregroundStyle(Theme.muted)
                    Stepper3(value: "\(model.settings.trainer.from)%",
                             down: { model.settings.trainer.from = max(50, model.settings.trainer.from - 5) },
                             up: { model.settings.trainer.from = min(model.settings.trainer.to, model.settings.trainer.from + 5) })
                }
                GridRow {
                    Text("Go up by").foregroundStyle(Theme.muted)
                    Stepper3(value: "\(model.settings.trainer.step)%",
                             down: { model.settings.trainer.step = max(1, model.settings.trainer.step - 1) },
                             up: { model.settings.trainer.step = min(20, model.settings.trainer.step + 1) })
                }
                GridRow {
                    Text("Every").foregroundStyle(Theme.muted)
                    Stepper3(value: model.settings.trainer.every == 1 ? "loop" : "\(model.settings.trainer.every) loops",
                             down: { model.settings.trainer.every = max(1, model.settings.trainer.every - 1) },
                             up: { model.settings.trainer.every = min(8, model.settings.trainer.every + 1) })
                }
                GridRow {
                    Text("Stop at").foregroundStyle(Theme.muted)
                    Stepper3(value: "\(model.settings.trainer.to)%",
                             down: { model.settings.trainer.to = max(model.settings.trainer.from, model.settings.trainer.to - 5) },
                             up: { model.settings.trainer.to = min(150, model.settings.trainer.to + 5) })
                }
            }
            .font(Typo.ui(12.5))
            .disabled(!model.settings.trainer.enabled)
            .opacity(model.settings.trainer.enabled ? 1 : 0.5)
        }
        .padding(18)
        .frame(width: 290)
    }
}

private struct PlayGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency || GlassSurfaceOverride.forceSolid { content }
        else if #available(macOS 26.0, *) { content.glassEffect(.clear.interactive(), in: Circle()) }
        else { content }
    }
}

/// Set A → Set B → Clear, always labelled with what the next press does.
struct ABButton: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var hover = false

    var body: some View {
        let state = model.abState
        Button { model.abPress() } label: {
            Group {
                switch state {
                case .setA: Text(compact ? "A" : "Set A")
                case .setB: Text(compact ? "B" : "Set B")
                case .clear: Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
            }
            .font(Typo.ui(12.5, .semibold))
            .foregroundStyle(state == .setB ? Theme.magentaText : (hover ? Theme.ink : Theme.ink2))
            .frame(minWidth: compact ? 28 : 52, minHeight: 28)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(state == .setB ? Theme.magenta.opacity(0.18) : (hover ? Theme.cardHover : Theme.card)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(state == .setB ? Theme.magenta.opacity(0.55) : Theme.hairline2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help(state))
        .accessibilityLabel(help(state))
        .animation(.easeOut(duration: 0.15), value: state == .setB)
    }

    func help(_ s: AppModel.ABState) -> String {
        switch s {
        case .setA: "Mark where the loop starts · A or foot pedal"
        case .setB: "Mark where the loop ends · A"
        case .clear: "Stop the loop · A"
        }
    }
}

/// Metronome on the song's beat grid while it plays.
struct ClickToggle: View {
    @Binding var isOn: Bool
    var compact = false
    @State private var hover = false
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "metronome.fill").font(.system(size: 11, weight: .semibold))
                if !compact { Text("Click").font(Typo.ui(12.5, .semibold)) }
            }
            .foregroundStyle(isOn ? Theme.primaryTint : (hover ? Theme.ink2 : Theme.muted))
            .padding(.vertical, 6).padding(.horizontal, compact ? 8 : 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isOn ? Theme.primary.opacity(0.18) : (hover ? Theme.cardHover : Theme.card)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isOn ? Theme.primary.opacity(0.55) : Theme.hairline2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Metronome that follows the song, at any speed · C")
        .accessibilityLabel("Click track")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
