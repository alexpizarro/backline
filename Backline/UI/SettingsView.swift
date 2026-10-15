import AppKit
import BacklineKit
import SwiftUI

/// Backline ▸ Settings… — deliberately tiny: YouTube sign-in and where the songs are kept.
/// Everything Backline needs is built in; there is nothing to add or install.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var signedIn = YouTubeSignIn.isSignedIn

    private var modelStatus: String {
        if let p = model.modelDownloadProgress { return "Getting them · \(Int(p * 100))%" }
        let missing = ModelDownloads.missing.count
        return missing == 0 ? "Ready" : "Next time Backline is online"
    }

    var body: some View {
        Form {
            if YouTubeSignIn.isEnabled {
                Section {
                    LabeledContent("YouTube") {
                        Text(signedIn ? "Signed in" : "Not signed in").font(.body.weight(.semibold))
                    }
                    Text("You only need this if YouTube asks you to sign in. Backline never sees your password.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        if signedIn {
                            Button("Sign Out of YouTube") {
                                Task { await YouTubeSignIn.signOut(); signedIn = false }
                            }
                        } else {
                            Button("Sign In to YouTube…") { model.youTubeSignInSheet = true; NSApp.keyWindow?.close() }
                        }
                    }
                } header: {
                    Text("YouTube")
                }
            }

            Section("Sharper parts") {
                LabeledContent("Extra models") { Text(modelStatus).font(.body.weight(.semibold)) }
                Text("Backline gets two extra models from the internet, one time (about 550 MB). One makes the parts of new songs cleaner. The other splits the drums into kick, snare and hi-hats.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("My songs") {
                LabeledContent("Songs") { Text("\(model.library.count)") }
                HStack {
                    Spacer()
                    Button("Show Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.root.deletingLastPathComponent()])
                    }
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                }
                HStack {
                    Spacer()
                    Button("Credits") {
                        if let url = Bundle.main.url(forResource: "Credits", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .task { await YouTubeSignIn.refreshStatus(); signedIn = YouTubeSignIn.isSignedIn }
    }
}
