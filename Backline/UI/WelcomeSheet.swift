import BacklineKit
import SwiftUI

/// First launch only: "What do you play?", then three simple cards for that choice, then straight
/// into the app. Help ▸ Show Welcome Again brings it back. The choice can be changed anytime at the top.
struct WelcomeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var page = 0

    private static let addSong = (symbol: "music.note", title: "Add a song",
                                  text: "Drag a music file onto Backline. Or paste a song or video link. Backline splits the song into parts.")

    private var cards: [(symbol: String, title: String, text: String)] {
        switch model.appMode {
        case .play: [
            Self.addSong,
            ("guitars", "Turn off your part",
             "Pick the part you play, like Lead guitar. Backline turns it off, and the band keeps playing."),
            ("repeat", "Practice the hard parts",
             "Click a part of the song to play it over and over. Slow it down until it feels easy."),
        ]
        case .dance: [
            Self.addSong,
            ("figure.dance", "Hear one part",
             "Pick a part under Listen for, like Bass. It plays loud, and the rest of the band plays soft."),
            ("hand.tap", "Tap on the 1",
             "Tap when you hear the 1. Then Backline counts to 8 for you. Loop an eight and slow it down."),
        ]
        case .beats: [
            Self.addSong,
            ("music.mic", "The beat is yours",
             "Backline turns the singer off. Now you can rap or sing over the beat."),
            ("repeat", "Loop a few bars",
             "Click 1, 2, 4 or 8 bars. The loop starts right on the beat, every time."),
        ]
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            Text("Welcome to Backline").font(Typo.ui(15, .semibold)).foregroundStyle(Theme.muted)
            if page == 0 { chooser } else { card(cards[page - 1]) }
            HStack(spacing: 8) {
                ForEach(0...cards.count, id: \.self) { i in
                    Circle().fill(i == page ? Theme.primaryTint : Theme.hairline2).frame(width: 8, height: 8)
                }
            }
            HStack {
                Button("Show me more") {
                    finish()
                    model.helpTopic = model.appMode == .dance ? .dance : (model.appMode == .beats ? .beats : .start)
                    openWindow(id: "help")
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(page < cards.count ? "Next" : "Let's go") {
                    if page < cards.count { withAnimation(.smooth) { page += 1 } } else { finish() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 520)
        .background(Theme.card)
        .animation(.smooth, value: page)
    }

    private var chooser: some View {
        VStack(spacing: 18) {
            Text("What do you play?").font(Typo.ui(24, .bold)).foregroundStyle(Theme.ink)
            HStack(spacing: 12) {
                choice(.play, "An instrument")
                choice(.dance, "Bachata or salsa")
                choice(.beats, "Rap or sing")
            }
            Text("You can change this anytime at the top of the window.")
                .font(Typo.ui(13)).foregroundStyle(Theme.muted)
        }
    }

    private func choice(_ m: PracticeMode, _ text: String) -> some View {
        let on = model.appMode == m
        return Button {
            model.setMode(m)
            withAnimation(.smooth) { page = 1 }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: m.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(on ? Theme.ink : Theme.primaryTint)
                    .frame(width: 58, height: 58)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(on ? Theme.primary : Theme.primary.opacity(0.18)))
                Text(m.title).font(Typo.ui(15, .bold)).foregroundStyle(Theme.ink)
                Text(text).font(Typo.ui(12)).foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 140, height: 160)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? Theme.primary.opacity(0.8) : Theme.hairline2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.title): \(text)")
    }

    private func card(_ c: (symbol: String, title: String, text: String)) -> some View {
        VStack(spacing: 22) {
            Image(systemName: c.symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.primaryTint)
                .frame(width: 92, height: 92)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.primary.opacity(0.18)))
                .contentTransition(.symbolEffect(.replace))
            Text(c.title).font(Typo.ui(24, .bold)).foregroundStyle(Theme.ink)
            Text(c.text).font(Typo.ui(15)).foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "welcomeSeen")
        model.showWelcome = false
        dismiss()
    }
}
