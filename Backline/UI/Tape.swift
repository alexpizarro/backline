import AppKit
import BacklineKit
import SwiftUI

// Ported from backline-ios Backline/UI/Tape.swift and Backline/UI/Grain.swift (mac-finish). The shapes, seeds and
// proportions are the same; the colours come from the Mac palette (`Theme`), and the cover's image is an `NSImage`.
// The Mac's small chip tapes ("YOU", "FREE") stay `TapeTag`: this file is the torn marker tape of the covers.

/// Gaffer tape, the one custom glyph (design plan 2.6). Everything is seeded by its text or id, so a label tears
/// and tilts the same way on every launch.
enum Tape {
    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// The tilt of a label, in degrees.
    static func angle(_ seed: UInt64) -> Double { [-1.2, 0.8, -0.6, 1.5][Int(seed % 4)] }
}

extension Typo {
    static let tapeFamily = "Permanent Marker"
    /// Marker on tape (never below 13 pt).
    static func tape(_ size: CGFloat) -> Font { .custom(tapeFamily, size: max(13, size)) }
}

/// SplitMix64: a tiny deterministic generator for the tears.
private nonisolated struct SeededRandom {
    var state: UInt64
    mutating func unit() -> CGFloat {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(1 << 53)
    }
}

/// A strip of tape: straight long edges and six torn teeth at each end.
struct TapeShape: Shape {
    var seed: UInt64

    func path(in r: CGRect) -> Path {
        var rng = SeededRandom(state: seed)
        let depth = min(6, r.height * 0.16)
        let teeth = 6
        var p = Path()
        p.move(to: CGPoint(x: r.minX + depth * rng.unit(), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - depth * rng.unit(), y: r.minY))
        for i in 1...teeth {
            let y = r.minY + r.height * CGFloat(i) / CGFloat(teeth)
            let inward = i % 2 == 1 ? 0.55 + 0.45 * rng.unit() : 0.25 * rng.unit()
            p.addLine(to: CGPoint(x: r.maxX - depth * inward, y: y))
        }
        p.addLine(to: CGPoint(x: r.minX + depth * rng.unit(), y: r.maxY))
        for i in (0..<teeth).reversed() {
            let y = r.minY + r.height * CGFloat(i) / CGFloat(teeth)
            let inward = i % 2 == 1 ? 0.55 + 0.45 * rng.unit() : 0.25 * rng.unit()
            p.addLine(to: CGPoint(x: r.minX + depth * inward, y: y))
        }
        p.closeSubpath()
        return p
    }
}

/// Film grain (design plan 2.9): the 128 px `grain-tile`, tiled and blended over what is below.
struct GrainOverlay: View {
    var opacity: Double = 0.04

    var body: some View {
        Image("grain-tile")
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Marker on tape: `console` is gaffer (or masking tape on paper), `amber` marks the one active thing.
struct TapeLabel: View {
    enum Style { case console, amber }

    let text: String
    var style: Style = .console
    var size: CGFloat = 15
    /// Shorter ends, for tape inside a chip.
    var tight = false

    init(_ text: String, style: Style = .console, size: CGFloat = 15, tight: Bool = false) {
        self.text = text
        self.style = style
        self.size = size
        self.tight = tight
    }

    var body: some View {
        let seed = Tape.hash(text)
        let shape = TapeShape(seed: seed)
        Text(text.uppercased())
            .font(Typo.tape(size))
            .foregroundStyle(style == .amber ? Theme.tokens.onAccent : Theme.tokens.tapeInk)
            .lineLimit(1)
            .padding(.horizontal, size * (tight ? 0.55 : 0.9))
            .padding(.vertical, size * 0.32)
            .background {
                shape.fill(style == .amber ? Theme.primary : Theme.tokens.tapeFill)
                    .overlay { GrainOverlay(opacity: 0.08).clipShape(shape) }
            }
            .rotationEffect(.degrees(Tape.angle(seed)))
            .accessibilityElement()
            .accessibilityLabel(text)
    }
}

/// The cover of a song without artwork: a `raised` square, two diagonal stripes in two of its part colours, and
/// the first word of the title on tape. Drawn at 120 pt and scaled, so the 20 pt stripes and the label keep their
/// proportions at every size.
struct TapeCover: View {
    let title: String
    let parts: [StemKind]
    let id: String

    private static let design: CGFloat = 120

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            art
                .frame(width: Self.design, height: Self.design)
                .scaleEffect(side / Self.design)
                .frame(width: g.size.width, height: g.size.height)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var art: some View {
        let seed = Tape.hash(id)
        let (a, b) = Self.colours(parts, seed: seed)
        return ZStack {
            Theme.card
            Group {
                Rectangle().fill(a.color).frame(width: 220, height: 20).offset(y: -18)
                Rectangle().fill(b.color).frame(width: 220, height: 20).offset(y: 18)
            }
            .rotationEffect(.degrees(-35))
            if let word = Self.word(title) {
                // Decoration: the title is written beside the cover already.
                TapeLabel(word, size: 13)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
    }

    /// Two different part colours, picked by the id.
    static func colours(_ parts: [StemKind], seed: UInt64) -> (StemKind, StemKind) {
        let pool = parts.count >= 2 ? parts : [.vocals, .bass]
        let i = Int(seed % UInt64(pool.count))
        let j = (i + 1 + Int((seed >> 8) % UInt64(pool.count - 1))) % pool.count
        return (pool[i], pool[j])
    }

    /// The first word of the title, eight characters at most.
    static func word(_ title: String) -> String? {
        title.split(whereSeparator: { $0.isWhitespace }).first.map { String($0.prefix(8)) }
    }

    /// A 600 × 600 image of the cover for Now Playing (always the stage look), as on iOS.
    static func image(title: String, parts: [StemKind], id: String) -> NSImage? {
        let renderer = ImageRenderer(content: TapeCover(title: title, parts: parts, id: id)
            .frame(width: 600, height: 600)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        return renderer.nsImage
    }
}
