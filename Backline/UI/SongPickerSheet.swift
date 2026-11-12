import BacklineKit
import SwiftUI

// The three sheets of a link to a song on a music service (S04), in the Mac's own form: the iOS versions
// (`Backline/UI/SongPickerSheet.swift` there) are bottom sheets with detents; these are window sheets with a
// header, a list that scrolls when it's long, and Escape for Cancel. The words are the same.

/// "Pick a song": the tracks an album or playlist link lists, one click each. One song at a time, as
/// everywhere else in Backline. Cancel or Escape is the same as Cancel on the Getting-the-song screen.
struct SongPickerSheet: View {
    @Environment(AppModel.self) private var model
    let list: SpotifyTrackList

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(title: "Pick a song", under: list.name) { model.dismissSpotifySheet() }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.tracks.enumerated()), id: \.offset) { index, row in
                        SongRowButton(title: row.title, under: row.artist, length: row.seconds,
                                      identifier: "spotify.pick.row") {
                            model.pickSpotifyTrack(row)
                        }
                        if index < list.tracks.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 20)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.card)
        .accessibilityIdentifier("spotify.pick")
    }
}

/// "Is this the song?": a recording 3 to 8 s away from the song's own length. Backline never guesses, so it
/// shows what it found beside what it was looking for and lets the person decide.
struct SongAskSheet: View {
    @Environment(AppModel.self) private var model
    let ask: SpotifyFlow.Ask

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(title: "Is this the song?") { model.dismissSpotifySheet() }
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ask.choice.candidate.title)
                        .font(Typo.ui(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ask.choice.candidate.by)
                        .font(Typo.ui(13))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(formatTime(ask.choice.candidate.seconds ?? 0)) · your song is \(formatTime(ask.song.seconds))")
                        .font(Typo.mono(12))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline3))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("spotify.ask.found")
                HStack(spacing: 8) {
                    Spacer()
                    Button("Not this") { answer { model.refuseSpotifyCandidate(ask) } }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("spotify.ask.not")
                    Button("Use it") { answer { model.useSpotifyCandidate(ask.choice, from: ask.result) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("spotify.ask.use")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 440)
        .background(Theme.card)
        .accessibilityIdentifier("spotify.ask")
    }

    /// The sheet goes first (clearing the state closes it), then the next screen or sheet comes.
    private func answer(_ action: @escaping @MainActor () -> Void) {
        model.spotify.ask = nil
        model.afterSheet(action)
    }
}

/// "Wrong song?" and "Not this": the other recordings that passed the title and artist rules, plus "None of
/// these". At most three, closest length first.
struct SongOtherTakesSheet: View {
    @Environment(AppModel.self) private var model
    let others: SpotifyFlow.Others

    var body: some View {
        VStack(spacing: 0) {
            SongSheetHeader(title: "Pick a song") { model.dismissSpotifySheet() }
            VStack(spacing: 0) {
                ForEach(Array(others.choices.enumerated()), id: \.offset) { index, scored in
                    SongRowButton(title: scored.candidate.title, under: scored.candidate.by,
                                  length: scored.candidate.seconds ?? 0, identifier: "spotify.others.row") {
                        answer { model.useSpotifyCandidate(scored) }
                    }
                    if index < others.choices.count - 1 {
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 20)
                    }
                }
            }
            HStack {
                Spacer()
                Button("None of these") { answer { model.noSpotifyMatch() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("spotify.others.none")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .frame(width: 460)
        .background(Theme.card)
        .accessibilityIdentifier("spotify.others")
    }

    private func answer(_ action: @escaping @MainActor () -> Void) {
        model.spotify.others = nil
        model.afterSheet(action)
    }
}

/// The title (and what it is from, for a list), and Cancel, which Escape presses too.
private struct SongSheetHeader: View {
    let title: String
    var under: String? = nil
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.ui(17, .bold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let under, !under.isEmpty {
                    Text(under)
                        .font(Typo.ui(12.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Cancel") { onCancel() }
                .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("spotify.cancel")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

/// One clickable row: the song, who it is by under it, and how long it is on the right.
private struct SongRowButton: View {
    let title: String
    let under: String
    let length: Double
    let identifier: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typo.ui(14, .semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !under.isEmpty {
                        Text(under)
                            .font(Typo.ui(12.5))
                            .foregroundStyle(Theme.ink2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(formatTime(length))
                    .font(Typo.mono(12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Theme.cardHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .pointerCursor()
        .accessibilityIdentifier(identifier)
        .accessibilityLabel([title, under, formatTime(length)].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// The three sheets, attached once to the root view. A sheet closed by anything other than one of its own
/// buttons is Cancel: nobody chose. A button of ours clears the state first, so by the time the binding's
/// write arrives there is nothing left to cancel.
struct SpotifyPresentations: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.spotify.picker },
                                 set: { if $0 == nil, model.spotify.picker != nil { model.dismissSpotifySheet() } })) { picker in
                SongPickerSheet(list: picker.list)
            }
            .sheet(item: Binding(get: { model.spotify.ask },
                                 set: { if $0 == nil, model.spotify.ask != nil { model.dismissSpotifySheet() } })) { ask in
                SongAskSheet(ask: ask)
            }
            .sheet(item: Binding(get: { model.spotify.others },
                                 set: { if $0 == nil, model.spotify.others != nil { model.dismissSpotifySheet() } })) { others in
                SongOtherTakesSheet(others: others)
            }
    }
}
