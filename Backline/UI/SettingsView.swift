import AppKit
import BacklineKit
import SwiftUI

/// Backline ▸ Settings…: General (the look, link sign-in, better parts, your songs, about, Reset) and Models.
/// The same rows as iOS Settings (3.7) in the Mac's own form: tabs instead of a pushed screen, and Help and
/// Show Welcome stay in the Help menu.
struct SettingsView: View {
    enum Tab: Hashable { case general, models }
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(showModels: { tab = .models })
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            ModelsView()
                .frame(width: 480)
                .fixedSize()
                .tabItem { Label("Extra parts", systemImage: "arrow.down.circle") }
                .tag(Tab.models)
        }
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("--settings-models") { tab = .models } }
        #endif
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    var showModels: () -> Void
    @State private var signedIn = YouTubeSignIn.isSignedIn
    @State private var storage: StorageUse?
    @State private var confirmReset = false
    @AppStorage(AppearanceMode.defaultsKey) private var raw = AppearanceMode.auto.rawValue

    /// The Models row's status, as iOS says it.
    static func modelStatus(progress: Double?, missing: Bool) -> String {
        if let p = progress { return "Downloading \(Int(p * 100))%" }
        return missing ? "Not downloaded" : "Ready"
    }

    var body: some View {
        Form {
            Section("Look") {
                Picker("Look", selection: Binding(
                    get: { AppearanceMode(rawValue: raw) ?? .auto },
                    set: { raw = $0.rawValue }
                )) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings.look")
            }

            if YouTubeSignIn.isEnabled {
                Section {
                    LabeledContent("Sign-in") {
                        Text(signedIn ? "Signed in ✓" : "Not signed in")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(signedIn ? Theme.success : .secondary)
                    }
                    HStack {
                        Spacer()
                        if signedIn {
                            Button("Sign Out") {
                                Task { await YouTubeSignIn.signOut(); signedIn = false }
                            }
                        } else {
                            Button("Sign In to Google…") { model.youTubeSignInSheet = true; NSApp.keyWindow?.close() }
                        }
                    }
                } header: { Text("Links") } footer: {
                    Text("Trouble getting a song from a link? Signing in to Google can help.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Extra parts") {
                    HStack(spacing: 10) {
                        Text(Self.modelStatus(progress: model.modelDownloadProgress, missing: !ModelDownloads.missing.isEmpty))
                            .font(.body.weight(.semibold))
                        Button("Show Extra Parts") { showModels() }
                            .accessibilityIdentifier("settings.models")
                    }
                }
            } header: { Text("Better parts") } footer: {
                Text(ModelsView.downloadLine(ModelDownloads.assets.reduce(0) { $0 + $1.bytes }) + " Cleaner parts, split drums.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Songs") { Text("\(model.library.count)") }
                LabeledContent("Storage") { Text(storage.map { StorageUse.format($0.total) } ?? "–") }
                HStack {
                    Spacer()
                    Button("Show Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.root.deletingLastPathComponent()])
                    }
                }
            } header: { Text("Songs") } footer: {
                // The total is everything Backline keeps on this Mac; this says where it goes.
                if let storage { Text(storage.detail).font(.callout).foregroundStyle(.secondary) }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                }
                HStack {
                    Link("Privacy policy", destination: BacklineSite.privacy)
                    Spacer()
                    Link("Support", destination: BacklineSite.support)
                    Spacer()
                    Button("Credits") {
                        if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            // Last row (R01c): deletes every song, part and download; Backline starts like new.
            if ResetBackline.isEnabled {
                Section {
                    HStack {
                        Spacer()
                        Button("Reset Backline…", role: .destructive) { confirmReset = true }
                            .disabled(model.isExporting || model.resetting)
                            .accessibilityIdentifier("settings.reset")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
        .alert("Reset Backline?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Task { await model.resetBackline() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every song, part and download. Backline starts like new.")
        }
        .task(id: model.library.count) {
            await YouTubeSignIn.refreshStatus()
            signedIn = YouTubeSignIn.isSignedIn
            storage = await AppModel.storageUse()
        }
    }
}
