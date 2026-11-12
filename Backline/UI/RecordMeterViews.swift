import SwiftUI

/// Drives the meter drawing. Not observable on purpose: it is advanced from inside the `Canvas` once per
/// display frame, so SwiftUI never re-evaluates a view body for it.
///
/// Port of backline-ios `App/Recording/RecordMeterViews.swift` (the meter and the status line; the Mac keeps
/// its own buttons and time readout in the Record sheet).
@MainActor
final class MeterDrawingState {
    var ballistics = MeterBallistics()
    /// Latest peak, 0…1.
    var target: Float = 0
    private var lastFrame: Double = 0

    func feed(fraction: Float) { target = fraction }

    /// Advances the meter's rise, fall and peak hold to `now`.
    func step(now: Double, active: Bool) {
        if lastFrame == 0 { lastFrame = now }
        let dt = min(0.1, now - lastFrame)
        lastFrame = now
        ballistics.advance(toward: active ? target : 0, dt: dt, now: now)
    }

    func clear() {
        ballistics.reset()
        target = 0
    }
}

/// A desk LED meter: 24 segments from −60 to 0 dB, `ok` up to −12, `caution` to −3, `live` above, off
/// segments `raised`, and the peak held for a moment. Smooth at the display's refresh rate; the level only
/// has to be fed at about 15 Hz. Draw it on a `surface` panel so the off segments show in both looks.
struct LEDMeter: View {
    let peakDB: Float
    var active: Bool

    static let segments = 24

    @State private var state = MeterDrawingState()

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: nil, paused: !active && state.ballistics.value < 0.002)) { timeline in
                Canvas { ctx, size in
                    state.step(now: timeline.date.timeIntervalSinceReferenceDate, active: active)
                    draw(&ctx, size: size)
                }
            }
            .frame(height: 18)
            // Each label sits where its level lights: −40 a third of the way, −20 two thirds.
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    Text("-60")
                    Text("-40").fixedSize().position(x: g.size.width / 3, y: g.size.height / 2)
                    Text("-20").fixedSize().position(x: g.size.width * 2 / 3, y: g.size.height / 2)
                    Text("0 dB").frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 14)
            .font(Typo.mono(10.5))
            .foregroundStyle(Theme.ink3)
            .accessibilityHidden(true)
        }
        .onChange(of: peakDB, initial: true) { _, db in state.feed(fraction: AudioLevel.meterFraction(db: db)) }
        .onChange(of: active) { _, on in if !on { state.clear() } }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(active && peakDB > AudioLevel.floorDB ? "\(Int(peakDB)) decibels" : "Silent")
    }

    /// The colour a segment lights in: its top edge in dB decides.
    static func colour(segment i: Int) -> Color {
        let top = -60 + 60 * Float(i + 1) / Float(segments)
        if top > -3 { return Theme.tokens.live }
        if top > -12 { return Theme.tokens.caution }
        return Theme.tokens.ok
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let n = Self.segments
        let gap: CGFloat = 3
        let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let level = state.ballistics.value
        let hold = min(n - 1, Int(state.ballistics.hold * Float(n)))
        for i in 0..<n {
            // A segment lights once the level passes its middle.
            let lit = level >= (Float(i) + 0.5) / Float(n) || (i == hold && state.ballistics.hold > 0.02)
            let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(lit ? Self.colour(segment: i) : Theme.tokens.raised))
        }
    }
}

/// One status line: a coloured dot (pulsing while it is "live") and a few words.
struct StatusLine: View {
    enum Tone { case idle, live, warning, good }
    let tone: Tone
    let text: String
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            // The repeating animation reaches the opacity only: applied to the whole dot it also moved it
            // in from where the sheet first laid it out.
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .animation(tone == .live && !reduceMotion ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil) {
                    $0.opacity(tone == .live && pulse && !reduceMotion ? 0.35 : 1)
                }
            Text(text)
                .font(Typo.ui(13, .semibold))
                .foregroundStyle(tone == .warning ? Theme.tokens.caution : Theme.ink2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .idle: Theme.ink3
        case .live: Theme.tokens.live
        case .warning: Theme.tokens.caution
        case .good: Theme.tokens.ok
        }
    }
}
