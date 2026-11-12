import SwiftUI

/// The extra parts row (V01, iOS `docs/design/extra-parts-row/mockup.html`): a dimmed, dashed row at the top
/// of the parts list, until the two free models are downloaded. It is never read as a part (a dashed outline
/// instead of a colour switch, no waveform, no fader) and it has one button, where a part's controls would
/// be. Clicking the row shows what the two models are before anything is fetched (nothing downloads without
/// a click next to the size).
///
/// What each state says is `AppModel.extraPartsOffer`; this file only draws it. Ported from iOS
/// `UI/ExtraPartsRow.swift`, with the Mac's pointer hover in place of the phone's large-type layout.
/// Where the row goes in the parts list. It asks for the row's state itself, so what the row observes
/// (the download's progress, the waiting flag) redraws this slot and never the whole list (UIP-02).
struct ExtraPartsSlot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let offer = model.extraPartsOffer {
            ExtraPartsRow(offer: offer)
                .padding(.bottom, 4)
                .transition(.opacity)
        }
    }
}

struct ExtraPartsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the details are showing (click the row).
    @State private var open = false
    @State private var hover = false
    /// The FREE tape sticks on the first time only (2.7).
    @AppStorage(ExtraParts.tapeKey) private var tapeStuck = false
    let offer: ExtraPartsOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            topLine
            metaLine
            if open { details }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 58, alignment: .top)
        .background(background)
        .overlay(alignment: .topLeading) { if showsTape { tape } }
        .contentShape(Rectangle())
        .onTapGesture { toggleDetails() }
        .onHover { hover = $0 }
        .help(canOpen ? (open ? "Hide what the two models are" : "Show what the two models are") : "")
        .animation(.smooth(duration: 0.25), value: open)
        .modifier(ExtraPartsAccessibility(offer: offer, open: open, onDetails: toggleDetails))
        .task { stickTape() }
    }

    // MARK: Lines

    private var topLine: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(offer.title)
                .font(Typo.ui(14, .semibold))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            button
        }
    }

    private var metaLine: some View {
        HStack(spacing: 10) {
            if case .noSpace = offer.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            }
            Text(line)
                .font(Typo.mono(11.5))
                .foregroundStyle(isCaution ? Theme.warning : Theme.ink3)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            if progress != nil || showsEmptyTrack { DottedProgress(fraction: progress) } else { Spacer(minLength: 0) }
        }
        .padding(.leading, 33)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(offer.details, id: \.title) { d in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(d.title).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink)
                        Text(d.size).font(Typo.mono(11.5)).foregroundStyle(Theme.ink3)
                    }
                    Text(d.line)
                        .font(Typo.ui(12.5))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Two free AI models. Downloads once.")
                .font(Typo.ui(12.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 9)
        .padding(.leading, 33)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 33)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The button

    private var buttonTitle: String? {
        switch offer.state {
        case .offer: "Download"
        case .failed: "Try Again"
        case .downloading: "Cancel"
        case .splitting, .noSpace: nil
        }
    }

    private var buttonIdentifier: String {
        switch offer.state {
        case .offer: "extra-parts.download"
        case .failed: "extra-parts.retry"
        case .downloading: "extra-parts.cancel"
        case .splitting, .noSpace: "extra-parts.none"
        }
    }

    @ViewBuilder private var button: some View {
        if let title = buttonTitle {
            if case .downloading = offer.state {
                Button(title) { act() }
                    .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)))
                    .accessibilityIdentifier(buttonIdentifier)
            } else {
                Button(title) { act() }
                    .buttonStyle(PrimaryButtonStyle(padding: EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14)))
                    .help("A one-time free download of \(offer.size)")
                    .accessibilityIdentifier(buttonIdentifier)
            }
        }
    }

    private func act() {
        switch offer.state {
        case .offer, .failed: model.downloadExtraParts()
        case .downloading: model.cancelModelDownloads()
        case .splitting, .noSpace: break
        }
    }

    // MARK: Words

    private var line: String {
        switch offer.state {
        case .offer: offer.offerLine
        case .downloading(let f, let left): Self.downloadingLine(fraction: f, secondsLeft: left)
        case .splitting(let f): Self.splittingLine(fraction: f)
        case .noSpace(let needed): AppModel.extraPartsSpaceLine(needed: needed)
        case .failed: "Download didn't finish"
        }
    }

    /// "Downloading · 38% · about 3 min left"; the time is left out until the rate has settled.
    nonisolated static func downloadingLine(fraction: Double, secondsLeft: Double?) -> String {
        var out = "Downloading · \(Int((fraction * 100).rounded()))%"
        if let secondsLeft {
            let minutes = minutesLeft(secondsLeft)
            out += minutes == 1 ? " · about 1 minute left" : " · about \(minutes) min left"
        }
        return out
    }

    /// Whole minutes left, never 0.
    nonisolated static func minutesLeft(_ seconds: Double) -> Int { max(1, Int((seconds / 60).rounded())) }

    /// An empty track beside the words while something is about to move (a split with no figure yet; a Mac
    /// has no Wi-Fi wait). Never on the offer, a failure or a lack of space: nothing is under way there.
    private var showsEmptyTrack: Bool {
        if case .splitting(nil) = offer.state { return true }
        return false
    }

    /// "Splitting this song's drums · 40%", or without a figure while the split has none yet.
    nonisolated static func splittingLine(fraction: Double?) -> String {
        guard let fraction else { return "Splitting this song's drums…" }
        return "Splitting this song's drums · \(Int((fraction * 100).rounded()))%"
    }

    private var progress: Double? {
        switch offer.state {
        case .downloading(let f, _): f
        case .splitting(let f): f
        default: nil
        }
    }

    private var isCaution: Bool { if case .noSpace = offer.state { return true }; return false }

    // MARK: Chrome

    /// The dashed outline: what tells people at a glance this is not one of their parts.
    private var background: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hover && canOpen ? Theme.card.opacity(0.6) : Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline3, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }

    /// The FREE tape, only while nothing has been said yes to yet.
    private var showsTape: Bool { offer.state == .offer }

    private var tape: some View {
        TapeTag(text: "FREE")
            .fixedSize()
            .offset(x: 18, y: -8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .modifier(TapeStick(animated: !tapeStuck && !reduceMotion))
    }

    private func stickTape() {
        #if DEBUG
        if CommandLine.arguments.contains("--extra-parts-open") { open = true }      // the details, for a shot
        #endif
        guard offer.state == .offer, !tapeStuck else { return }
        // Written straight away: the tape lands once per install, not once per song.
        tapeStuck = true
    }

    private var canOpen: Bool { offer.state == .offer || offer.state == .failed }

    private func toggleDetails() {
        guard canOpen else { return }
        open.toggle()
    }
}

/// The tape sticks on like the YOU tape (2.7), and only the first time. A plain appearance with Reduce
/// Motion: the plan allows the tape one moment, and nothing moves after it.
private struct TapeStick: ViewModifier {
    let animated: Bool
    @State private var landed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(animated && !landed ? 1.15 : 1)
            .rotationEffect(.degrees(animated && !landed ? -4 : 0))
            .opacity(animated && !landed ? 0 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: landed)
            .task { if animated { landed = true } }
    }
}

/// The whole row as one element for VoiceOver: what you'd hear, whether it is downloaded, and what it
/// costs, spelled out, with the button's job as its action. Never a part, and never a switch. The button
/// stays an element of its own, because clicking the row and clicking the button do different things (the
/// row shows the details; the button downloads).
struct ExtraPartsAccessibility: ViewModifier {
    let offer: ExtraPartsOffer
    let open: Bool
    let onDetails: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("extra-parts")
            .accessibilityLabel(Self.label(offer))
            .accessibilityValue(open ? "open" : "")
            .accessibilityHint(hint)
            .accessibilityAction(named: "Show what you'd hear") { onDetails() }
    }

    private var hint: String {
        switch offer.state {
        case .offer, .failed: "Shows what the two models are"
        default: ""
        }
    }

    /// "Hear the kick, snare and hi-hats separately. Not downloaded. Free, 550 megabytes."
    nonisolated static func label(_ offer: ExtraPartsOffer) -> String {
        // The non-breaking hyphen is for the eye; VoiceOver gets the ordinary one.
        let title = offer.title.replacingOccurrences(of: "\u{2011}", with: "-")
        let spoken = offer.size.replacingOccurrences(of: " MB", with: " megabytes")
        switch offer.state {
        case .offer:
            return "\(title). Not downloaded. Free, \(spoken)."
        case .downloading(let f, let left):
            let time = left.map { s -> String in
                let minutes = ExtraPartsRow.minutesLeft(s)
                return minutes == 1 ? ", about 1 minute left" : ", about \(minutes) minutes left"
            } ?? ""
            return "\(title). Downloading, \(Int((f * 100).rounded())) per cent\(time)."
        case .splitting(let f):
            let pc = f.map { ", \(Int(($0 * 100).rounded())) per cent" } ?? ""
            return "\(title). Downloaded. Splitting this song's drums\(pc)."
        case .noSpace(let needed):
            let words = AppModel.extraPartsSpaceLine(needed: needed)
                .replacingOccurrences(of: " GB ", with: " gigabytes ")
            return "\(title). Not downloaded. \(words)."
        case .failed:
            return "\(title). Not downloaded. Download didn't finish."
        }
    }
}

/// The row's thin progress track: dots, with the part that is done filled in. Decoration: the line beside
/// it says the figure in words.
private struct DottedProgress: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    ForEach(0..<max(1, Int(g.size.width / 7)), id: \.self) { _ in
                        Circle().fill(Theme.inaudibleBar).frame(width: 3, height: 3)
                    }
                }
                .frame(width: g.size.width, alignment: .leading)
                if let fraction {
                    Capsule()
                        .fill(Theme.primary)
                        .frame(width: max(3, g.size.width * min(1, max(0, fraction))), height: 4)
                }
            }
            .frame(width: g.size.width, height: 4, alignment: .leading)
        }
        .frame(height: 4)
        .frame(minWidth: 20)
        .accessibilityHidden(true)
    }
}
