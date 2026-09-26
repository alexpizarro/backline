import BacklineKit
import SwiftUI

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false
    @State private var dropTarget = false
    @State private var bob = false

    var body: some View {
        let active = hover || dropTarget
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.primary.opacity(active ? 0.28 : 0.18))
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.primaryTint)
                    .offset(y: dropTarget ? 3 : (bob ? 1.5 : -1.5))
            }
            .frame(width: 52, height: 52)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: bob)

            Text("Drop a song here")
                .font(Typo.ui(20, .bold))
                .foregroundStyle(Theme.ink)
            Text("Backline splits it into parts, so you can turn off your part.")
                .font(Typo.ui(14))
                .foregroundStyle(Theme.muted)
            AddSongChoices()
                .padding(.top, 6)
            if model.dropRejected {
                Text("Backline can't open this file type.")
                    .font(Typo.ui(12.5, .semibold))
                    .foregroundStyle(Theme.danger)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 560, height: YouTubeImport.isEnabled ? 400 : 340)
        .overlay(alignment: .topTrailing) { HelpButton(topic: .addSong).padding(12) }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(active ? Theme.elevated : Theme.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(active ? Theme.primaryTint : Theme.primaryTint.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: active ? [] : [6, 5]))
        )
        .shadow(color: Theme.primary.opacity(dropTarget ? 0.35 : 0), radius: 30)
        .scaleEffect(dropTarget ? 1.015 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { model.addSong() }
        .onHover { hover = $0 }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTarget) { providers in
            loadDropped(providers, model: model)
            return true
        }
        .animation(.smooth(duration: 0.18), value: active)
        .animation(.smooth(duration: 0.2), value: model.dropRejected)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { bob = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop a song here, or choose a file")
        .accessibilityAddTraits(.isButton)
    }
}

struct FailureView: View {
    @Environment(AppModel.self) private var model
    let message: String
    var body: some View {
        let needsSignIn = YouTubeSignIn.isEnabled && message == YouTubeImport.signInMessage
        let fromYouTube = model.lastYouTube != nil && model.lastImportURL == nil
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: needsSignIn ? "person.crop.circle.badge.questionmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(needsSignIn ? Theme.primaryTint : Theme.danger)
                Text(needsSignIn ? "YouTube wants you to sign in" : (fromYouTube ? "That didn't work" : "Couldn't split this song"))
                    .font(Typo.ui(22, .bold)).foregroundStyle(Theme.ink)
            }
            Text(needsSignIn
                 ? "Some videos only play for people who are signed in. Sign in once, and Backline will try again."
                 : message)
                .font(Typo.ui(14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if needsSignIn {
                    Button("Sign in to YouTube") { model.youTubeSignInSheet = true }.buttonStyle(PrimaryButtonStyle())
                    Button("Record it instead…") { model.recordSheet = true }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Try again") { model.retryImport() }.buttonStyle(PrimaryButtonStyle())
                    Button("Add a different song…") { model.addSongSheet = true }.buttonStyle(SecondaryButtonStyle())
                }
                HelpButton(topic: needsSignIn ? .youtubeSignIn : .troubleshooting)
            }
        }
        .frame(width: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The same three ways to add a song everywhere in the app: the empty screen and the Add Song sheet
/// (the "+" buttons and ⌘O). File, YouTube link, or record from another app.
struct AddSongChoices: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Button("Choose file…") { model.addSongSheet = false; model.openPanel() }
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    model.addSongSheet = false
                    model.recordSheet = true
                } label: {
                    Label("Record from an app…", systemImage: "record.circle")
                }
                .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)))
                .help("Record a song while it plays in your browser or music app")
            }
            Text("MP3 · WAV · AIFF · M4A · FLAC")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.muted)
            if YouTubeImport.isEnabled { YouTubeLinkField() }
        }
    }
}

/// "+" / Add song / ⌘O while a song is open: the same choices as the start screen, in a sheet.
/// Dropping a file or a link onto the sheet works too.
struct AddSongSheet: View {
    @Environment(AppModel.self) private var model
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HelpButton(topic: .addSong)
                Spacer()
                Button("Cancel") { model.addSongSheet = false }
                    .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)))
                    .keyboardShortcut(.cancelAction)
            }
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.primaryTint)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.primary.opacity(0.18)))
            Text("Add a song").font(Typo.ui(20, .bold)).foregroundStyle(Theme.ink)
            Text("Drop a file or a YouTube link here, or pick one below.")
                .font(Typo.ui(14)).foregroundStyle(Theme.muted)
            AddSongChoices()
                .padding(.top, 4)
            if model.dropRejected {
                Text("Backline can't open this file type.")
                    .font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.danger)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 28, bottom: 28, trailing: 28))
        .frame(width: 520)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 0).strokeBorder(dropTarget ? Theme.primaryTint : .clear, lineWidth: 2))
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTarget) { providers in
            model.addSongSheet = false
            loadDropped(providers, model: model)
            return true
        }
        .preferredColorScheme(.dark)
    }
}

/// "Paste a YouTube link" field: validates as you type, Return or the arrow opens it.
struct YouTubeLinkField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let video = YouTubeImport.parse(text)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("…or paste a YouTube link", text: $text)
                    .textFieldStyle(.plain)
                    .font(Typo.ui(13))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { if let video { model.addSongSheet = false; model.openYouTube(video) } }
                Button {
                    if let video { model.addSongSheet = false; model.openYouTube(video) }
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(video != nil ? Theme.primaryTint : Theme.muted.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(video == nil)
                .help("Split this song")
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(width: 380)
            .overlay(alignment: .trailing) { HelpButton(topic: .youtube).offset(x: 40) }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bg.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Theme.primaryTint.opacity(0.7) : Theme.hairline2))
            if !text.isEmpty && video == nil {
                Text("That isn't a YouTube video link.").font(Typo.ui(11.5)).foregroundStyle(Theme.danger)
            } else {
                Text("Only use music you're allowed to use. Getting songs from YouTube may break YouTube's rules.")
                    .font(Typo.ui(10.5)).foregroundStyle(Theme.muted.opacity(0.8))
            }
        }
        .padding(.top, 4)
        .onTapGesture {}   // keep taps in the field from opening the file panel
    }
}
