import BacklineKit
import SwiftUI

struct AnalyzingView: View {
    @Environment(AppModel.self) private var model

    static let steps = ["Reading the song", "Pulling out the vocals", "Pulling out drums and bass",
                        "Pulling out the guitars", "Pulling out keys and the rest", "Finishing up"]

    var body: some View {
        let p = model.importProgress
        // A link's audio on its way; or a large file still being fingerprinted (UIP-08), which says "Getting the
        // song" too but has none of a link's words.
        let getting = model.downloadingFromYouTube
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                art(known: !model.importTitle.isEmpty)
                VStack(alignment: .leading, spacing: 6) {
                    Text(getting || model.preparingFile ? "Getting the song" : "Splitting the song into parts")
                        .font(Typo.ui(13))
                        .foregroundStyle(Theme.muted)
                    // Never a placeholder word: a shimmering bar until the link has said what the song is called.
                    if model.importTitle.isEmpty {
                        Skeleton(cornerRadius: 5).frame(width: 220, height: 22).padding(.vertical, 3)
                    } else {
                        Text(model.importTitle)
                            .font(Typo.ui(22, .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                    if getting, !model.importArtist.isEmpty {
                        Text(model.importArtist)
                            .font(Typo.ui(14))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    } else if getting, model.importTitle.isEmpty {
                        Skeleton(cornerRadius: 4).frame(width: 120, height: 12).padding(.vertical, 2)
                    }
                }
            }
            .animation(.smooth(duration: 0.25), value: model.importTitle.isEmpty)
            .animation(.smooth(duration: 0.25), value: model.importArtwork != nil)
            VStack(spacing: 8) {
                ProgressTrack(fraction: p.fraction)
                HStack {
                    Text("\(Int(p.fraction * 100))%")
                    Spacer()
                    Text(Self.eta(p, getting: getting, finding: model.spotify.finding, anotherWay: model.tryingAnotherWay,
                                  wait: model.linkWait.stage, stillTrying: model.linkWait.stillTrying,
                                  serviceMinutes: model.linkWait.serviceMinutes) ?? "")
                        .contentTransition(.numericText(countsDown: true))
                }
                .font(Typo.mono(12))
                .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                if getting {
                    if model.spotify.finding {
                        StepRow(label: "Finding the song", state: .current)
                        StepRow(label: "Downloading the audio", state: .pending)
                    } else {
                        StepRow(label: "Downloading the audio", state: .current)
                    }
                    StepRow(label: "Splitting the song into parts", state: .pending)
                } else {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, label in
                        StepRow(label: label, state: i < p.phase ? .done : (i == p.phase ? .current : .pending))
                    }
                }
            }
            HStack(spacing: 8) {
                Label(getting ? "Only the audio is downloaded. Nothing is uploaded."
                              : "Runs on your Mac. Nothing is uploaded.", systemImage: "lock.fill")
                    .labelStyle(FootnoteLabelStyle())
                Spacer()
                // A recording Backline matched on its own: the way out if it picked the wrong one (S04).
                if !model.spotify.finding, let matched = model.spotify.matched, !matched.result.others().isEmpty {
                    Button("Wrong song?") { model.showOtherSpotifyCandidates() }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Shows the other recordings Backline found")
                        .accessibilityIdentifier("spotify.wrongSong")
                }
                // The long wait (L2): a way out that still gets the song, one click away.
                if Self.offersRecording(getting: getting, fraction: p.fraction, stillTrying: model.linkWait.stillTrying,
                                        anotherWay: model.tryingAnotherWay) {
                    Button("Record instead") {
                        model.cancelImport()
                        model.recordSheet = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("import.recordInstead")
                    .transition(.opacity)
                }
                Button("Cancel") { model.cancelImport() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: p.phase)
    }

    /// 56 pt, as on iOS's splitting screen: the song's picture (a video's thumbnail, a music service's cover),
    /// a tape cover once the title is known, or a shimmering square while a link hasn't said yet.
    @ViewBuilder private func art(known: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let image = model.importArtwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.hairline))
            } else if known {
                TapeCover(title: model.importTitle, parts: [], id: model.importTitle)
                    .frame(width: 56, height: 56)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.hairline))
            } else {
                Skeleton(shape: shape).frame(width: 56, height: 56)
            }
        }
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    /// The line under the bar. While getting the song from a link: "Connecting…" ("Waiting for the video…" while an
    /// ad slot runs out), then "Downloading…"; a link to a song on a music service says "Finding the song…" first
    /// (S04). After 15 s with nothing arriving, "Still trying. This can take a minute." (L2). While the song service
    /// gets a song this Mac couldn't, "Trying another way…", with its minutes once there is one, then "Downloading…"
    /// as its audio arrives. While splitting: nothing until there is an honest estimate (the steps vary too much by
    /// Mac before that), then "about N seconds left".
    static func eta(_ p: ImportProgress, getting: Bool, finding: Bool = false, anotherWay: Bool = false,
                    wait: YouTubeExtractor.Stage = .connecting, stillTrying: Bool = false, serviceMinutes: Int = 0) -> String? {
        if anotherWay {
            if p.fraction > 0 { return "Downloading…" }
            return serviceMinutes > 0 ? "Trying another way · \(serviceMinutes) min" : "Trying another way…"
        }
        if getting, p.fraction > 0 { return "Downloading…" }
        if getting, stillTrying { return "Still trying. This can take a minute." }
        if finding { return "Finding the song…" }
        if getting { return wait == .waitingForVideo ? "Waiting for the video…" : "Connecting…" }
        guard let s = p.secondsRemaining, s.isFinite, p.fraction > 0.06 else { return nil }
        return "about \(max(1, Int(s.rounded(.up)))) seconds left"
    }

    /// Record instead sits beside Cancel while the song service works, and once 15 s have gone by with nothing
    /// arriving from the link (L2).
    static func offersRecording(getting: Bool, fraction: Double, stillTrying: Bool, anotherWay: Bool) -> Bool {
        getting && (anotherWay || (stillTrying && fraction == 0))
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
