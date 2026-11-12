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
    @State private var confirmDelete = false

    /// What the screen says (as iOS's `FailureView.content`): a split that failed, a link that failed (signing in
    /// can help unless already signed in or offline), a link that needs signing in, or a song on a music service
    /// whose recording wasn't found.
    struct Content: Equatable {
        enum Action: Equatable { case tryAgain, anotherSong, signIn, notNow, recordInstead, openAgain, deleteSong }
        var symbol: String
        var caution: Bool
        var title: String
        var line: String
        var primary: Action
        var secondary: Action
        var help: HelpTopic
    }

    static func content(message: String, fromLink: Bool, canSignIn: Bool) -> Content {
        // A song in the Library that didn't open (D7): it is kept; open it again or delete it.
        if message == AppModel.openFailureMessage || message == AppModel.openMemoryMessage {
            return Content(symbol: "exclamationmark.triangle.fill", caution: false, title: "Couldn't open it", line: message,
                           primary: .openAgain, secondary: .deleteSong, help: .troubleshooting)
        }
        guard fromLink else {
            return Content(symbol: "exclamationmark.triangle.fill", caution: false, title: "Couldn't split it", line: message,
                           primary: .tryAgain, secondary: .anotherSong, help: .troubleshooting)
        }
        if message == YouTubeExtractor.networkMessage {
            return Content(symbol: "wifi.exclamationmark", caution: false, title: "Couldn't get it", line: message,
                           primary: .tryAgain, secondary: .notNow, help: .troubleshooting)
        }
        // A link to a song on a music service whose recording wasn't found (S04): nothing to sign in to and
        // nothing to retry, so it offers recording the song instead, and the line says how (the title already says
        // it wasn't found). The Mac records from a microphone or an audio interface.
        if message == SpotifyImport.noMatchMessage {
            return Content(symbol: "magnifyingglass", caution: false, title: "Couldn't find it",
                           line: "Record it while it plays.",
                           primary: .recordInstead, secondary: .notNow, help: .youtube)
        }
        // A share page instead of the file (L7): Try again would fetch the same page, so it offers another link.
        if message == FileLinkDownload.webPageMessage {
            return Content(symbol: "exclamationmark.triangle.fill", caution: false, title: "Couldn't get it", line: message,
                           primary: .anotherSong, secondary: .notNow, help: .troubleshooting)
        }
        let needsSignIn = message == YouTubeImport.signInMessage
        // Sign-in only helps when YouTube asked for it or sent nothing back; a known reason (too long, a live
        // stream, unavailable, no sound) is shown as it is.
        guard canSignIn, needsSignIn || message == YouTubeExtractor.genericMessage else {
            return Content(symbol: "exclamationmark.triangle.fill", caution: false, title: "Couldn't get it", line: message,
                           primary: .tryAgain, secondary: .recordInstead, help: .troubleshooting)
        }
        return Content(symbol: "person.crop.circle.badge.questionmark", caution: true,
                       title: needsSignIn ? "Sign in to get this one" : "Couldn't get it",
                       line: "Signing in to Google can help.", primary: .signIn, secondary: .notNow, help: .youtubeSignIn)
    }

    var body: some View {
        // Google sign-in can only help a YouTube link; a file, Vimeo or music-service link that failed offers
        // Try again or Record instead.
        let fromLink = (model.lastYouTube != nil || model.lastLink != nil) && model.lastImportURL == nil
        let c = Self.content(message: message, fromLink: fromLink,
                             canSignIn: model.lastYouTube != nil && YouTubeSignIn.isEnabled && !YouTubeSignIn.isSignedIn)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: c.symbol)
                    .foregroundStyle(c.caution ? Theme.primaryTint : Theme.danger)
                Text(c.title)
                    .font(Typo.ui(22, .bold)).foregroundStyle(Theme.ink)
            }
            Text(c.line)
                .font(Typo.ui(14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(Self.title(c.primary)) { perform(c.primary) }.buttonStyle(PrimaryButtonStyle())
                Button(Self.title(c.secondary)) { perform(c.secondary) }.buttonStyle(SecondaryButtonStyle())
                HelpButton(topic: c.help)
            }
        }
        .frame(width: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Delete “\(model.openFailure?.title ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteFailedSong() }
        } message: {
            Text("Your original file stays safe.")
        }
    }

    static func title(_ a: Content.Action) -> String {
        switch a {
        case .tryAgain: "Try again"
        case .anotherSong: "Add a different song…"
        case .signIn: "Sign in"
        case .notNow: "Not now"
        case .recordInstead: "Record instead…"
        case .openAgain: "Try again"
        case .deleteSong: "Delete song"
        }
    }

    private func perform(_ a: Content.Action) {
        switch a {
        case .tryAgain: model.retryImport()
        case .anotherSong: model.addSongSheet = true
        case .signIn: model.youTubeSignInSheet = true
        case .notNow: model.dismissFailure()
        case .recordInstead: model.recordSheet = true
        case .openAgain: model.retryOpen()
        case .deleteSong: confirmDelete = true
        }
    }
}

/// The same three ways to add a song everywhere in the app: the empty screen and the Add Song sheet
/// (the "+" buttons and ⌘O). A file, a link, or record (from another app or a microphone).
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
                    Label("Record a song…", systemImage: "record.circle")
                }
                .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)))
                .help("Record a song while it plays in another app, or with a microphone")
            }
            Text("MP3 · WAV · AIFF · M4A · FLAC")
                .font(Typo.mono(11))
                .foregroundStyle(Theme.muted)
            if YouTubeImport.isEnabled { LinkField() }
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
            Text("Drop a file or a link here, or pick one below.")
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
    }
}

/// "Paste a song or video link": any web link (a song on a music service, a video, a music file), checked as you
/// type; Return or the arrow opens it, and the import decides what it can get from it (as on iOS).
struct LinkField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var notALink = false
    @FocusState private var focused: Bool

    var body: some View {
        let link = Self.link(in: text)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("…or paste a song or video link", text: $text)
                    .textFieldStyle(.plain)
                    .font(Typo.ui(13))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { open(link) }
                Button { open(link) } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(link != nil ? Theme.primaryTint : Theme.muted.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(link == nil)
                .help("Split this song")
                .accessibilityLabel("Split this song")
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(width: 380)
            .overlay(alignment: .trailing) { HelpButton(topic: .youtube).offset(x: 40) }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bg.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Theme.primaryTint.opacity(0.7) : Theme.hairline2))
            if notALink {
                Text("Not a link.").font(Typo.ui(11.5)).foregroundStyle(Theme.danger)
            } else {
                Text("Use music you have the rights to.")
                    .font(Typo.ui(10.5)).foregroundStyle(Theme.muted.opacity(0.8))
            }
        }
        .padding(.top, 4)
        .onChange(of: text) { notALink = false }
        .onTapGesture {}   // keep clicks in the field from opening the file panel
    }

    private func open(_ link: String?) {
        guard let link else { notALink = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty; return }
        focused = false
        model.addSongSheet = false
        if !model.openText(link) { model.showToast(.init(text: "Can't get a song from this link.", isError: true)) }
    }

    /// The pasted text as a web link: a YouTube link anywhere in it, or an http(s) address with a real host
    /// ("vimeo.com/…" without a scheme counts). The same rule as iOS's `LinkField.link(in:)`.
    nonisolated static func link(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if YouTubeImport.find(in: t) != nil { return t }
        // Sharing from a music service copies a sentence with the link inside it (S01).
        if SpotifyRef.find(in: t) != nil { return t }
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        for candidate in [t, "https://" + t] {
            if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") {
                return url.absoluteString
            }
            if t.contains("://") { break }
        }
        return nil
    }
}
