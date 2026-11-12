import SwiftUI

/// A placeholder that shimmers while the real thing is on its way (a link's title and picture before the download
/// knows them). Never a placeholder word: the shape says "coming". Still with Reduce Motion.
///
/// Ported from backline-ios Backline/UI/Skeleton.swift. iOS draws it over a dark photo; the Mac's Getting-the-song
/// screen is the plain canvas, so it rests on `sunken` and the sweep is the palette's `onPhoto` cream.
struct Skeleton<S: Shape>: View {
    var shape: S
    /// The resting fill; the highlight sweeps over it.
    var fill: Color = Theme.inset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        shape
            .fill(fill)
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Theme.tokens.onPhoto.opacity(Theme.isDark ? 0.18 : 0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: sweep ? g.size.width : -g.size.width * 0.6)
                    }
                    .clipShape(shape)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { sweep = true }
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

extension Skeleton where S == RoundedRectangle {
    init(cornerRadius: CGFloat, fill: Color = Theme.inset) {
        self.init(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), fill: fill)
    }
}
