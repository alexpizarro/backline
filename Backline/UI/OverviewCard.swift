import BacklineKit
import SwiftUI

/// Section chips + mix-aware waveform with loop region, draggable loop edges and scrubbable playhead.
struct OverviewCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            SectionStrip()
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

    enum DragMode { case scrub, loopStart, loopEnd, newLoop(Double) }

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
                    } else if NSEvent.modifierFlags.contains(.option) {
                        dragMode = .newLoop(model.snapToBeat(startT))
                    } else {
                        dragMode = .scrub
                    }
                }
                switch dragMode {
                case .scrub: model.isScrubbing = true; model.seek(to: t)
                case .loopStart:
                    if let r = model.loopRange { model.setLoop(start: model.snapToBeat(min(t, r.upperBound - 0.5)), end: r.upperBound) }
                case .loopEnd:
                    if let r = model.loopRange { model.setLoop(start: r.lowerBound, end: model.snapToBeat(max(t, r.lowerBound + 0.5))) }
                case .newLoop(let a):
                    let b = model.snapToBeat(t)
                    if abs(b - a) > 0.5 { model.setLoop(start: min(a, b), end: max(a, b)) }
                case .none: break
                }
            }
            .onEnded { _ in
                if case .newLoop = dragMode, let r = model.loopRange { model.seek(to: r.lowerBound) }
                model.isScrubbing = false
                dragMode = nil
            }
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
