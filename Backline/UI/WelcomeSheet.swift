import BacklineKit
import SwiftUI

/// First launch only: three simple cards, then straight into the app. Help ▸ Show Welcome Again brings it back.
struct WelcomeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var page = 0

    private let cards: [(symbol: String, title: String, text: String)] = [
        ("music.note", "Add a song",
         "Drag a music file onto Backline. Or paste a YouTube link. Backline splits the song into parts."),
        ("guitars", "Turn off your part",
         "Pick the part you play, like Lead guitar. Backline turns it off, and the band keeps playing."),
        ("repeat", "Practice the hard parts",
         "Click a part of the song to play it over and over. Slow it down until it feels easy."),
    ]

    var body: some View {
        let card = cards[page]
        VStack(spacing: 22) {
            Text("Welcome to Backline").font(Typo.ui(15, .semibold)).foregroundStyle(Theme.muted)
            Image(systemName: card.symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.primaryTint)
                .frame(width: 92, height: 92)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.primary.opacity(0.18)))
                .contentTransition(.symbolEffect(.replace))
            Text(card.title).font(Typo.ui(24, .bold)).foregroundStyle(Theme.ink)
            Text(card.text).font(Typo.ui(15)).foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360)
            HStack(spacing: 8) {
                ForEach(cards.indices, id: \.self) { i in
                    Circle().fill(i == page ? Theme.primaryTint : Theme.hairline2).frame(width: 8, height: 8)
                }
            }
            HStack {
                Button("Show me more") {
                    finish()
                    model.helpTopic = .start
                    openWindow(id: "help")
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(page < cards.count - 1 ? "Next" : "Let's play") {
                    if page < cards.count - 1 { withAnimation(.smooth) { page += 1 } } else { finish() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 460)
        .background(Theme.card)
        .preferredColorScheme(.dark)
        .animation(.smooth, value: page)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "welcomeSeen")
        model.showWelcome = false
        dismiss()
    }
}
