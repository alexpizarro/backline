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
            let dur = max(model.duration, 0.001)
            let current = model.currentLoopSection
            ZStack(alignment: .topLeading) {
                ForEach(model.sections) { s in
                    let x = geo.size.width * s.start / dur
                    let w = geo.size.width * (s.end - s.start) / dur
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
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

struct OverviewWaveform: View {
    @Environment(AppModel.self) private var model
    @State private var dragMode: DragMode?
    @State private var hoverX: CGFloat?

    enum DragMode { case scrub, loopStart, loopEnd, newLoop(Double), barPending(Double) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let dur = max(model.duration, 0.001)
            let bars = model.mixBars(count: max(20, Int(width / 4)))
            ZStack(alignment: .topLeading) {
                // Loop region
                if model.settings.loopEnabled, let r = model.loopRange {
                    let x0 = width * r.lowerBound / dur, x1 = width * r.upperBound / dur
                    Rectangle()
                        .fill(Theme.magenta.opacity(0.10))
                        .overlay(alignment: .leading) { LoopHandle() }
                        .overlay(alignment: .trailing) { LoopHandle() }
                        .frame(width: max(2, x1 - x0), height: geo.size.height + 8)
                        .offset(x: x0, y: -4)
                        .transition(.opacity)
                }
                GridLines(times: model.gridLines, duration: dur, emphasise: model.mode == .dance)
                    .allowsHitTesting(false)
                WaveformBars(bars: bars, progress: model.position / dur)
                    .animation(.smooth(duration: 0.25), value: bars)
                // Hover time readout
                if let hx = hoverX, dragMode == nil {
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: geo.size.height)
                        .offset(x: hx)
                    Text(formatTime(Double(hx / width) * dur))
                        .font(Typo.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.cardHover))
                        .offset(x: min(max(0, hx - 18), width - 40), y: -2)
                        .allowsHitTesting(false)
                }
                // Playhead
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: 2, height: geo.size.height + 12)
                    .shadow(color: .white.opacity(0.5), radius: 3)
                    .offset(x: width * model.position / dur - 1, y: -6)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width, dur: dur))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended: hoverX = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Song overview")
        .accessibilityValue("\(formatTime(model.position)) of \(formatTime(model.duration))")
        .accessibilityAdjustableAction { dir in
            model.nudge(bars: dir == .increment ? 1 : -1)
        }
    }

    func dragGesture(width: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let t = Double(max(0, min(width, v.location.x)) / width) * dur
                if dragMode == nil {
                    let startT = Double(max(0, min(width, v.startLocation.x)) / width) * dur
                    let tol = Double(8 / width) * dur
                    if model.settings.loopEnabled, let r = model.loopRange, abs(startT - r.lowerBound) < tol {
                        dragMode = .loopStart
                    } else if model.settings.loopEnabled, let r = model.loopRange, abs(startT - r.upperBound) < tol {
                        dragMode = .loopEnd
                    } else if model.mode == .beats {
                        dragMode = .barPending(startT)
                    } else if NSEvent.modifierFlags.contains(.option) {
                        dragMode = .newLoop(model.snapToBeat(startT))
                    } else {
                        dragMode = .scrub
                    }
                }
                switch dragMode {
                case .scrub: model.isScrubbing = true; model.seek(to: t)
                case .loopStart:
                    if let r = model.loopRange { model.setLoop(start: snap(min(t, r.upperBound - 0.5)), end: r.upperBound) }
                case .loopEnd:
                    if let r = model.loopRange { model.setLoop(start: r.lowerBound, end: snap(max(t, r.lowerBound + 0.5))) }
                case .barPending(let start):
                    // Beats: a real drag (not a click) becomes a loop from bar line to bar line.
                    if abs(v.location.x - v.startLocation.x) > 6 {
                        dragMode = .newLoop(model.snapToBarLine(start))
                    }
                case .newLoop(let a):
                    let b = snap(t)
                    if abs(b - a) > 0.5 { model.setLoop(start: min(a, b), end: max(a, b)) }
                case .none: break
                }
            }
            .onEnded { v in
                if case .barPending = dragMode {
                    model.seek(to: Double(max(0, min(width, v.location.x)) / width) * dur)
                }
                if case .newLoop = dragMode, let r = model.loopRange { model.seek(to: r.lowerBound) }
                model.isScrubbing = false
                dragMode = nil
            }
    }
}

extension OverviewWaveform {
    /// Loop edges snap to bar lines in Beats and to beats elsewhere.
    func snap(_ t: Double) -> Double { model.mode == .beats ? model.snapToBarLine(t) : model.snapToBeat(t) }
}

/// Thin lines on the waveform: every eight (Dance) or every bar (Beats).
struct GridLines: View {
    let times: [Double]
    let duration: Double
    var emphasise = false

    var body: some View {
        Canvas { ctx, size in
            guard !times.isEmpty, duration > 0 else { return }
            // Keep at least 5 px between lines: skip some when zoomed out.
            let minGap: CGFloat = 5
            var lastX: CGFloat = -.infinity
            var path = Path()
            for t in times {
                let x = size.width * t / duration
                guard x - lastX >= minGap else { continue }
                path.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
                lastX = x
            }
            ctx.fill(path, with: .color(Color.white.opacity(emphasise ? 0.10 : 0.07)))
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
        let current = model.currentCount
        let n = model.countsPerCycle
        return HStack(spacing: 4) {
            if model.mode == .beats, let bar = model.currentBar {
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
                    .animation(.easeOut(duration: 0.08), value: on)
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

struct LoopHandle: View {
    @State private var hover = false
    var body: some View {
        Rectangle()
            .fill(Theme.magenta)
            .frame(width: hover ? 3 : 1.5)
            .overlay {
                Capsule().fill(Theme.magenta).frame(width: 6, height: 14).opacity(hover ? 1 : 0)
            }
            .frame(width: 12)
            .contentShape(Rectangle())
            .onHover { h in
                hover = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Bars 2 px apart, radius 1; played portion in violet.
struct WaveformBars: View, Animatable {
    var bars: [Float]
    var progress: Double
    var played = Theme.primaryHover
    var unplayed = Theme.muted.opacity(0.45)
    var minHeight: CGFloat = 3

    var body: some View {
        Canvas { ctx, size in
            guard !bars.isEmpty else { return }
            let gap: CGFloat = 2
            let w = max(1, (size.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
            let cut = size.width * progress
            var playedPath = Path(), restPath = Path()
            for (i, v) in bars.enumerated() {
                let x = CGFloat(i) * (w + gap)
                let h = max(minHeight, CGFloat(v) * size.height)
                let r = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                let p = Path(roundedRect: r, cornerRadius: min(1, w / 2))
                if x + w / 2 < cut { playedPath.addPath(p) } else { restPath.addPath(p) }
            }
            ctx.fill(restPath, with: .color(unplayed))
            ctx.fill(playedPath, with: .color(played))
        }
        .drawingGroup()
    }
}
