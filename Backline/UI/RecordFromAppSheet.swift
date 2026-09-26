import AppKit
import BacklineKit
import SwiftUI

/// "Record from an app…": capture the song as it plays in another app on this Mac (process tap,
/// System Audio Recording permission), then split it like a dropped file. Real time only — no downloading.
@MainActor @Observable
final class RecordFromAppModel {
    enum Phase: Equatable {
        case picking
        case starting
        case waitingForSound
        case recording
        case cantHear
        case tooQuiet
        case failed(String)
    }
    var phase: Phase = .picking
    var sources: [AudioSource] = []
    var selection: AudioSource.ID?
    var stats = CaptureStats()
    var elapsed: Double = 0
    private var capture: TapCapture?
    private var poll: Task<Void, Never>?
    private var refresher: Task<Void, Never>?
    private var startedAt = Date()
    static let silenceAutoStop = 6.0
    static let maxSeconds = 20.0 * 60
    var onFinished: (URL, String) -> Void = { _, _ in }

    var selectedSource: AudioSource? { sources.first { $0.id == selection } }

    func begin() {
        refresh()
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase == .picking else { continue }
                self.refresh()
            }
        }
    }

    func refresh() {
        let list = (try? AudioSourceCatalog.sources(includeIdle: true, appsOnly: true)) ?? []
        sources = list.filter { $0.appBundleID != Bundle.main.bundleIdentifier && $0.isUserApp }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        if selection == nil || !sources.contains(where: { $0.id == selection }) {
            selection = sources.first(where: \.isPlaying)?.id ?? sources.first?.id
        }
    }

    func start() {
        guard let src = selectedSource else { return }
        phase = .starting
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backline/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("recording-\(UUID().uuidString).wav")
        startedAt = Date()
        poll = Task { [weak self] in
            do {
                // Off the main actor: starting IO can block while the permission prompt is showing.
                let cap = try await TapCapture.start(.app(src), writingTo: url)
                guard let self else { cap.stop(); return }
                self.capture = cap
                self.phase = .waitingForSound
                self.startedAt = Date()
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(66))
                    self.stats = cap.stats
                    self.elapsed = self.stats.seconds
                    if self.stats.firstSoundAt != nil, self.phase == .waitingForSound { self.phase = .recording }
                    // Permission denied or protected audio: the app is playing but we only get zeros.
                    if !self.stats.everNonZero, Date().timeIntervalSince(self.startedAt) > 5,
                       AudioSourceCatalog.isPlaying(src) { self.phase = .cantHear }
                    if self.stats.firstSoundAt == nil, self.stats.everNonZero, self.stats.seconds > 10,
                       self.stats.loudestPeakDB < -30 { self.phase = .tooQuiet }
                    if let last = self.stats.lastSoundAt, self.stats.seconds - last > Self.silenceAutoStop { self.stop(); return }
                    if self.stats.seconds > Self.maxSeconds { self.stop(); return }
                    // Output device vanished (e.g. Bluetooth profile switch): keep what we have.
                    if self.stats.ioCycles > 0, Date().timeIntervalSince(self.startedAt) > 3,
                       self.stats.seconds > 1, cap.isStalled { self.stop(); return }
                }
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops and hands the trimmed recording to the import pipeline.
    func stop() {
        poll?.cancel()
        guard let cap = capture else { return }
        let final = cap.stop()
        capture = nil
        guard let first = final.firstSoundAt, let last = final.lastSoundAt, last - first > 5 else {
            try? FileManager.default.removeItem(at: cap.url)
            phase = final.everNonZero ? .tooQuiet : .cantHear
            return
        }
        let title = "Recording – " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let trimmed = Self.trim(cap.url, from: max(0, first - 0.5), to: last + 1)
        onFinished(trimmed ?? cap.url, title)
    }

    func cancel() {
        poll?.cancel()
        refresher?.cancel()
        if let cap = capture {
            cap.stop()
            try? FileManager.default.removeItem(at: cap.url)
        }
        capture = nil
    }

    /// Trims leading/trailing silence into a new file next to the original (which is removed).
    static func trim(_ url: URL, from a: Double, to b: Double) -> URL? {
        guard let audio = try? AudioDecoder.decode(url) else { return nil }
        let sr = audio.sampleRate
        let s = max(0, Int(a * sr)), e = min(audio.frameCount, Int(b * sr))
        guard e > s else { return nil }
        let out = StereoAudio(left: Array(audio.left[s..<e]), right: Array(audio.right[s..<e]), sampleRate: sr)
        let dst = url.deletingPathExtension().appendingPathExtension("caf")
        do {
            try SongStore.shared.writeStem(out, to: dst)
            try? FileManager.default.removeItem(at: url)
            return dst
        } catch { return nil }
    }
}

struct RecordFromAppSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rec = RecordFromAppModel()

    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record a song playing on your Mac")
                .font(Typo.ui(16, .bold)).foregroundStyle(Theme.ink)
            content
            Text("For practice only. Only record music you're allowed to use. Recordings stay on your Mac.")
                .font(Typo.ui(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                HelpButton(topic: .record)
                Spacer()
                Button("Cancel") { rec.cancel(); dismiss() }
                    .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)))
                    .keyboardShortcut(.cancelAction)
                primaryButton
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Theme.card)
        .preferredColorScheme(.dark)
        .onAppear {
            rec.onFinished = { url, title in
                dismiss()
                app.importTitleOverride = title
                app.open(url)
            }
            rec.begin()
        }
        .onDisappear { rec.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch rec.phase {
        case .picking:
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Choose the app that's playing  2. Press Record  3. Play the song from the start")
                    .font(Typo.ui(12.5)).foregroundStyle(Theme.ink2)
                if rec.sources.isEmpty {
                    Text("No apps are making sound. Start the song in your browser or music app, then come back.")
                        .font(Typo.ui(12.5)).foregroundStyle(Theme.muted)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(rec.sources) { s in
                                SourceRow(source: s, selected: rec.selection == s.id) { rec.selection = s.id }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        case .starting:
            Label("Waiting for permission to hear \(rec.selectedSource?.name ?? "the app")…", systemImage: "lock.shield")
                .font(Typo.ui(13)).foregroundStyle(Theme.ink2)
        case .waitingForSound, .recording:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.danger).frame(width: 10, height: 10)
                        .opacity(rec.phase == .recording ? 1 : 0.4)
                    Text(rec.phase == .recording ? "Recording from \(rec.selectedSource?.name ?? "app")"
                                                 : "Now press play from the start of the song")
                        .font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink)
                }
                Text(formatTime(rec.elapsed)).font(Typo.mono(28, .semibold)).foregroundStyle(Theme.ink)
                LevelMeter(db: rec.stats.peakDB)
                Text("Stops by itself after \(Int(RecordFromAppModel.silenceAutoStop)) seconds of quiet.")
                    .font(Typo.ui(11.5)).foregroundStyle(Theme.muted)
            }
        case .cantHear:
            VStack(alignment: .leading, spacing: 8) {
                Label("Backline can't hear \(rec.selectedSource?.name ?? "that app").", systemImage: "speaker.slash")
                    .font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Text("Click Open Privacy Settings and turn on Backline. Then try again. Some music apps block recording.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacyURL) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .tooQuiet:
            Label("That was very quiet. Turn the volume up in the other app and try again.", systemImage: "speaker.wave.1")
                .font(Typo.ui(13)).foregroundStyle(Theme.ink2)
        case .failed(let m):
            Label("Couldn't start recording. \(m)", systemImage: "exclamationmark.triangle")
                .font(Typo.ui(13)).foregroundStyle(Theme.danger)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch rec.phase {
        case .picking:
            Button("Record") { rec.start() }
                .buttonStyle(PrimaryButtonStyle(padding: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)))
                .keyboardShortcut(.defaultAction)
                .disabled(rec.selection == nil)
        case .waitingForSound, .recording:
            Button("Stop & Split") { rec.stop() }
                .buttonStyle(PrimaryButtonStyle(padding: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)))
                .keyboardShortcut(.defaultAction)
                .disabled(rec.phase == .waitingForSound)
        case .cantHear, .tooQuiet, .failed:
            Button("Try Again") { rec.phase = .picking; rec.refresh() }
                .buttonStyle(PrimaryButtonStyle(padding: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)))
        case .starting:
            EmptyView()
        }
    }
}

private struct SourceRow: View {
    let source: AudioSource
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let path = source.appPath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "app").frame(width: 22, height: 22)
                }
                Text(source.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if source.isPlaying {
                    Text("Playing").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.success)
                }
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.primaryTint) }
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.cardHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LevelMeter: View {
    let db: Float
    var body: some View {
        GeometryReader { g in
            let f = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.card)
                Capsule().fill(LinearGradient(colors: [Theme.success, Theme.warning, Theme.danger], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * f))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.066), value: db)
    }
}
