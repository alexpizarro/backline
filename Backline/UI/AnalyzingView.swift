import BacklineKit
import SwiftUI

struct AnalyzingView: View {
    @Environment(AppModel.self) private var model

    static let steps = ["Reading the song", "Pulling out the vocals", "Pulling out drums and bass",
                        "Pulling out the guitars", "Pulling out keys and the rest", "Finishing up"]

    var body: some View {
        let p = model.importProgress
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.downloadingFromYouTube ? "Getting the audio from YouTube" : "Splitting the song into parts")
                    .font(Typo.ui(13))
                    .foregroundStyle(Theme.muted)
                Text(model.importTitle)
                    .font(Typo.ui(22, .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            VStack(spacing: 8) {
                ProgressTrack(fraction: p.fraction)
                HStack {
                    Text("\(Int(p.fraction * 100))%")
                    Spacer()
                    Text(etaString(p))
                        .contentTransition(.numericText(countsDown: true))
                }
                .font(Typo.mono(12))
                .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                if model.downloadingFromYouTube {
                    StepRow(label: "Downloading the audio", state: .current)
                    StepRow(label: "Splitting the song into parts", state: .pending)
                } else {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, label in
                        StepRow(label: label, state: i < p.phase ? .done : (i == p.phase ? .current : .pending))
                    }
                }
            }
            HStack {
                Label(model.downloadingFromYouTube ? "Only the audio is downloaded. Nothing is uploaded."
                                                   : "Runs on your Mac. Nothing is uploaded.", systemImage: "lock.fill")
                    .labelStyle(FootnoteLabelStyle())
                Spacer()
                Button("Cancel") { model.cancelImport() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: p.phase)
    }

    func etaString(_ p: ImportProgress) -> String {
        if model.downloadingFromYouTube { return p.fraction > 0 ? "downloading…" : "contacting YouTube…" }
        guard let s = p.secondsRemaining, p.fraction > 0.06 else { return "working out the time…" }
        return "about \(max(1, Int(s.rounded(.up)))) seconds left"
    }
}

struct FootnoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
        .font(Typo.ui(12))
        .foregroundStyle(Theme.muted)
    }
}

struct ProgressTrack: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.card)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.primary, Theme.primaryHover], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * fraction))
                    .overlay(alignment: .trailing) {
                        Circle().fill(Theme.primaryTint).frame(width: 6, height: 6).blur(radius: 3).opacity(fraction < 1 ? 1 : 0)
                    }
                    .animation(.smooth(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 6)
    }
}

struct StepRow: View {
    enum State { case pending, current, done }
    let label: String
    let state: State
    @SwiftUI.State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if state == .current {
                    Circle().fill(Theme.primary.opacity(0.4)).frame(width: 16, height: 16)
                        .scaleEffect(pulse ? 1 : 0.5).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                }
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            .frame(width: 8, height: 8)
            Text(state == .done ? "\(label) — done" : label)
                .font(Typo.ui(14))
                .foregroundStyle(state == .pending ? Theme.muted : Theme.ink)
        }
        .onAppear { pulse = true }
    }

    var dot: Color {
        switch state {
        case .pending: Theme.toggleOff
        case .current: Theme.primary
        case .done: Theme.success
        }
    }
}
