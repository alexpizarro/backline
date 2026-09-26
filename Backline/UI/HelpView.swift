import AppKit
import BacklineKit
import SwiftUI

/// Help ▸ Backline Help (⌘?): short, picture-led guides written for someone with no Mac know-how.
/// Opens on a specific topic from the "?" buttons around the app.
struct HelpView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(HelpContent.pages, id: \.topic) { page in
                        HelpTopicRow(page: page, selected: (model.helpTopic ?? .start) == page.topic) {
                            model.helpTopic = page.topic
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            .frame(width: 230)
            .background(Theme.chrome)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }

            HelpPageView(page: HelpContent.page(model.helpTopic ?? .start))
                .id(model.helpTopic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

private struct HelpTopicRow: View {
    let page: HelpPage
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.primaryTint : Theme.muted)
                    .frame(width: 20)
                Text(page.title)
                    .font(Typo.ui(13.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.primary.opacity(0.2) : (hover ? Theme.cardHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct HelpPageView: View {
    @Environment(AppModel.self) private var model
    let page: HelpPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.primaryTint)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.primary.opacity(0.18)))
                    Text(page.title).font(Typo.ui(26, .bold)).foregroundStyle(Theme.ink)
                }
                Text(page.intro).font(Typo.ui(16)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(page.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(i + 1)")
                                .font(Typo.ui(14, .bold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Theme.primary))
                            Image(systemName: step.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Theme.ink2)
                                .frame(width: 26, height: 28)
                            Text(step.text).font(Typo.ui(15)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                    }
                }

                if let tip = page.tip {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(Theme.warning)
                        Text(tip).font(Typo.ui(14)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline2))
                }

                actions
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .background(Theme.bg)
    }

    /// Buttons that do the thing the page talks about — so nobody has to hunt for it.
    @ViewBuilder private var actions: some View {
        switch page.topic {
        case .youtubeSignIn where YouTubeSignIn.isEnabled:
            Button("Sign in to YouTube") { model.youTubeSignInSheet = true; closeHelp() }
                .buttonStyle(PrimaryButtonStyle())
        case .record:
            Button("Record from an app…") { model.recordSheet = true; closeHelp() }
                .buttonStyle(PrimaryButtonStyle())
        case .addSong:
            Button("Add a song…") { closeHelp(); model.addSong() }
                .buttonStyle(PrimaryButtonStyle())
        case .miniPlayer:
            Button("Open the small player") { closeHelp(); model.toggleMiniPlayer() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.song == nil)
        case .remove:
            Button("Show my split songs in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.root]) }
                .buttonStyle(SecondaryButtonStyle())
        default:
            EmptyView()
        }
    }

    private func closeHelp() {
        NSApp.windows.first { $0.identifier?.rawValue == "help" || $0.title == "Backline Help" }?.close()
        model.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Small round "?" that opens Help on the matching page.
struct HelpButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let topic: HelpTopic
    @State private var hover = false

    var body: some View {
        Button {
            model.helpTopic = topic
            openWindow(id: "help")
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hover ? Theme.ink : Theme.ink2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hover ? Theme.cardHover : Theme.card))
                .overlay(Circle().strokeBorder(Theme.hairline2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Show help")
        .accessibilityLabel("Help")
    }
}
