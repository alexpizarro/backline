import BacklineKit
import SwiftUI

/// The Deck's time row (design plan 3.4): elapsed left, remaining right. While a finger drags the Map,
/// the elapsed time becomes the big amber numeral so it reads from a step back.
struct TimeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // `timeText` changes once a second, not with every tick of the playhead (UIP-11).
        let time = model.timeText
        HStack(alignment: .firstTextBaseline) {
            if model.showsScrubTime {
                Text(time.elapsed).font(Typo.mono(20, .bold)).foregroundStyle(Theme.primaryTint)
            } else {
                Text(time.elapsed).font(Typo.mono(11.5)).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 8)
            Text("\u{2212}" + time.remaining)
                .font(Typo.mono(11.5))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(time.elapsed) of \(formatTime(model.duration))")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The Deck's Loop button (3.4): a click toggles the mode's default loop (Play: the section; Dance: 8
/// counts; Beats: 4 bars) and the menu picks another length.
///
/// The Mac's `LoopChip` in the transport bar already offers every length for every mode, so this is kept
/// for the Deck layout in M10 but not added to the bar as well: two loop controls side by side is noise.
struct LoopButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.settings.loopEnabled
        Menu {
            loopChoices
        } label: {
            Image(systemName: "repeat")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Theme.primaryTint : Theme.ink2)
                .frame(width: 34, height: 34)
                .background(Circle().fill(on ? Theme.tokens.accentSoft : Theme.tokens.raised))
                .overlay(Circle().strokeBorder(on ? Theme.tokens.accentEdge : Theme.tokens.stroke))
                .contentShape(Circle())
        } primaryAction: {
            model.toggleDefaultLoop()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Loop")
        .accessibilityValue(on ? rangeText : "Off")
        .help(on ? "Loop on: \(rangeText)" : "Loop this part of the song · L")
    }

    @ViewBuilder private var loopChoices: some View {
        switch model.mode {
        case .play:
            Button { model.toggleSectionLoop() } label: { Label("This section", systemImage: "rectangle.split.3x1") }
            ForEach(Array(model.sections.enumerated()), id: \.offset) { _, s in
                Button(s.label) { model.loopSection(s) }
            }
        case .dance:
            ForEach([8, 16, 32], id: \.self) { n in
                Button("\(n) counts") { model.loopCounts(n) }
            }
        case .beats:
            ForEach([1, 2, 4, 8], id: \.self) { n in
                Button(n == 1 ? "1 bar" : "\(n) bars") { model.loopBars(n) }
            }
        }
        if model.settings.loopEnabled {
            Divider()
            Button { model.updateSettings { $0.loopEnabled = false } } label: { Label("Stop loop", systemImage: "stop") }
        }
    }

    var rangeText: String {
        guard let r = model.loopRange else { return model.mode == .dance ? "8 counts" : "–:––" }
        if model.mode == .dance, let n = model.loopCountLength { return "\(n) counts" }
        if model.mode == .beats, let n = model.loopBarCount { return n == 1 ? "1 bar" : "\(n) bars" }
        return "\(formatTime(r.lowerBound))–\(formatTime(r.upperBound))"
    }
}
