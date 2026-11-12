import BacklineKit
import SwiftUI

/// Section chips + mix-aware waveform with loop region, draggable loop edges and scrubbable playhead.
struct OverviewCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Group {
                switch model.mode {
                case .play: SectionStrip()
                case .dance, .beats: CountStrip()
                }
            }
            .frame(height: 22)
            OverviewWaveform()
                .frame(height: 70)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}

struct SectionStrip: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SongAnalysis.Section.ID?
    @State private var draft = ""

    var body: some View {
        GeometryReader { geo in
            let sections = model.sections
            let current = model.currentLoopSection
            // Each chip sits exactly over its section on the Map, at any zoom (U07: they share `mapWindow`).
            ZStack(alignment: .topLeading) {
                ForEach(model.mapWindow.tapeFrames(sections.map { $0.start...$0.end }, width: geo.size.width), id: \.index) { f in
                    let s = sections[f.index]
                    let x = f.x, w = f.width
                    let active = current?.id == s.id || (current.map { abs($0.start - s.start) < 0.01 } ?? false)
                    SectionChip(section: s, active: active, isEditing: editing == s.id, draft: $draft,
                                onTap: { model.loopSection(s) },
                                onRename: { editing = s.id; draft = s.label },
                                onCommit: { model.renameSection(s, to: draft); editing = nil })
                        .frame(width: max(0, w - 2), height: geo.size.height)
                        .offset(x: x)
                }
            }
        }
    }
}

struct SectionChip: View {
    let section: SongAnalysis.Section
    let active: Bool
    let isEditing: Bool
    @Binding var draft: String
    let onTap: () -> Void
    let onRename: () -> Void
    let onCommit: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    /// "Section 3" → "3", "Chorus" → "Ch", "Solo 2" → "S2".
    var shortLabel: String {
        let parts = section.label.split(separator: " ")
        if parts.first == "Section", parts.count == 2 { return String(parts[1]) }
        let head = String(section.label.prefix(parts.count > 1 ? 1 : 2))
        return parts.count > 1 ? head + parts.last! : head
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(active ? Theme.magenta.opacity(0.2) : (hover ? Theme.cardHover : Theme.card))
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typo.ui(11, .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 7)
                    .focused($focused)
                    .onSubmit(onCommit)
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, f in if !f { onCommit() } }
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(section.label)
                    Text(shortLabel)
                    Text("")
                }
                .font(Typo.ui(11, .semibold))
                .foregroundStyle(active ? Theme.magentaText : Theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 7)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onRename)
        .onTapGesture(count: 1, perform: onTap)
        .onHover { hover = $0 }
        .help("Loop \(section.label) · double-click to rename")
        .motion(.easeOut(duration: 0.15), value: active)
    }
}

/// The big waveform (the Map). The pointer's gestures are AppKit's (`MapView`), and the playhead and played colour
/// come from the transport clock on the GPU, so this view never re-renders while the song plays or while the
/// pointer scrubs (UIP-07). The hover readout is the only SwiftUI state that moves, and only under a still mouse.
struct OverviewWaveform: View {
    @Environment(AppModel.self) private var model
    @State private var hover: Hover?

    struct Hover: Equatable { var time: Double; var x: CGFloat }

    var body: some View {
        let dur = max(model.duration, 0.001)
        let loop = model.settings.loopEnabled ? model.loopRange : nil
        let visible = model.mapWindow
        MapRepresentable(
            config: WaveformConfig(
                // The stored envelope's full resolution, so a zoomed view stays sharp.
                values: model.mixBars(count: 1600), normalize: false,
                barColor: Theme.tokens.waveIdle, playedColor: Theme.tokens.wavePlayed,
                minBarHeight: 3, barPitch: 4, gap: 2, verticalInset: 6,
                loop: loop, loopFill: Theme.tokens.loopFill, loopEdge: Theme.tokens.loopEdge,
                showLoopHandles: model.settings.loopEnabled,
                grid: model.gridLines, gridColor: Theme.ink, gridAlpha: model.mode == .dance ? 0.10 : 0.07,
                duration: dur, showPlayhead: true, playheadColor: Theme.tokens.playhead, playheadWidth: 2.5, glow: 0.5,
                litColor: Theme.tokens.waveLit, playheadKnob: true, glowFollowsLevel: true, dark: Theme.isDark),
            duration: dur, loopRange: loop, visible: visible, plainDragDrawsLoop: model.mode == .beats, model: model,
            onHover: { t, x in
                let next = t.map { Hover(time: $0, x: x) }
                if next != hover { hover = next }
            })
        .overlay(alignment: .topLeading) {
            // Hover time readout.
            if let hover {
                GeometryReader { g in
                    Rectangle().fill(Theme.ink.opacity(0.18)).frame(width: 1, height: g.size.height)
                        .offset(x: hover.x)
                    Text(formatTime(hover.time))
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.cardHover))
                        .offset(x: min(max(0, hover.x - 18), g.size.width - 40), y: -2)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Zoomed: a thin bar shows which part of the song is on screen.
            if visible.isZoomed {
                GeometryReader { g in
                    Capsule().fill(Theme.ink3)
                        .frame(width: max(10, g.size.width * visible.length / visible.duration), height: 2)
                        .offset(x: g.size.width * visible.start / visible.duration, y: g.size.height - 3)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .help(model.mode == .beats ? "Drag to loop bars · click to jump · pinch to zoom"
              : "Click to jump · drag to move through the song · Option-drag to loop · pinch to zoom")
        .accessibilityElement()
        .accessibilityLabel("Song overview")
        .accessibilityValue("\(model.timeText.elapsed) of \(formatTime(model.duration))")
        .accessibilityAdjustableAction { dir in
            model.nudge(bars: dir == .increment ? 1 : -1)
        }
        .accessibilityActions {
            if model.playheadSection != nil {
                Button("Loop this section") { model.toggleSectionLoop() }
            }
            if visible.isZoomed {
                Button("Show the whole song") { model.mapWindow = .whole(model.duration) }
            }
        }
    }
}

/// Dance counts 1 to 8, Beats counts the 4 beats of a bar. Nothing moves until the person has tapped on
/// the 1 (a wrong machine guess was confusing): until then the strip is one clear button.
struct CountStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.countsConfirmed { counts } else { tapPrompt }
    }

    private var tapPrompt: some View {
        HStack(spacing: 10) {
            Button { model.setOneHere() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 11, weight: .bold))
                    Text("Tap on the 1").font(Typo.ui(12, .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(Capsule().fill(Theme.magenta))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Play the song. Click this (or press O) when you hear the 1. Then the counts start.")
            .accessibilityLabel("Tap on the 1")
            Text(model.isPlaying ? "Click it when you hear the 1, or press O" : "Play the song, then click it on the 1")
                .font(Typo.ui(11.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var counts: some View {
        // Published only when the count or the bar changes (UIP-11), not at the transport's 30 Hz.
        let beat = model.playheadBeat
        let current = beat.count
        let n = model.countsPerCycle
        return HStack(spacing: 4) {
            if model.mode == .beats, let bar = beat.bar {
                Text("Bar \(bar)")
                    .font(Typo.mono(11, .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 58, alignment: .leading)
                    .contentTransition(.numericText())
            }
            ForEach(1...n, id: \.self) { i in
                let on = current == i
                Text("\(i)")
                    .font(Typo.mono(12, .semibold))
                    .foregroundStyle(on ? .white : (i == 1 ? Theme.magentaText : Theme.muted))
                    .frame(width: 26, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? (i == 1 ? Theme.magenta : Theme.primary) : Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline2))
                    .motion(.easeOut(duration: 0.08), value: on)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Set the 1 here  O") { model.setOneHere() }
                if model.mode == .dance { Button("Move the 1 by 4 counts") { model.moveOne(by: 4) } }
                Divider()
                Button("Clear the 1") { model.clearOne() }
            } label: {
                Label("The 1", systemImage: "hand.tap")
                    .labelStyle(.titleAndIcon)
                    .font(Typo.ui(11.5, .semibold))
            } primaryAction: {
                model.setOneHere()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.primaryTint)
            .fixedSize()
            .help("Click to set the 1 again where you are now (or press O). Hold for more.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(current.map { "Count \($0)" } ?? "Counts")
    }
}
