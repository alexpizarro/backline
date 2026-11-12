import AppKit
import BacklineKit
import CoreAudio
import SwiftUI

/// "Record from an app": capture the song as it plays in another app on this Mac (process tap,
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

/// Record: a song playing in another app on this Mac (process tap), or the sound in the room through a
/// microphone or an audio interface (`MicRecorder`, ported from iOS). Either way the take is split like a
/// dropped file.
struct RecordFromAppSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case app, microphone
        var id: String { rawValue }
        var title: String { self == .app ? "Another app" : "Microphone" }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rec = RecordFromAppModel()
    @State private var mic = MicRecorder()
    @State private var confirmDiscard = false
    /// The choice used last time (a convenience; the sheet works the same without it).
    @AppStorage("recordSource") private var sourceRaw = Source.app.rawValue

    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    private var source: Source { Source(rawValue: sourceRaw) ?? .app }
    private var busy: Bool {
        mic.isBusy || [.starting, .waitingForSound, .recording].contains(rec.phase)
    }
    /// A take is being recorded or saved: Quit asks first (`AppDelegate.quitQuestion`).
    private var recording: Bool { mic.isBusy || rec.phase == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record a song")
                .font(Typo.ui(16, .bold)).foregroundStyle(Theme.ink)
            Picker("Record from", selection: Binding(get: { source }, set: { switchTo($0) })) {
                ForEach(Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(busy)
            Group {
                switch source {
                case .app: content
                case .microphone: MicrophonePanel(mic: mic)
                }
            }
            .frame(minHeight: 150, alignment: .top)
            Text("For practice only. Only record music you're allowed to use. Recordings stay on your Mac.")
                .font(Typo.ui(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                HelpButton(topic: .record)
                Spacer()
                Button("Cancel") {
                    if mic.isRecording { confirmDiscard = true } else { close() }
                }
                .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)))
                .keyboardShortcut(.cancelAction)
                switch source {
                case .app: primaryButton
                case .microphone: micButtons
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.card)
        .confirmationDialog("Throw this recording away?", isPresented: $confirmDiscard) {
            Button("Throw Away", role: .destructive) { close() }
            Button("Keep Recording", role: .cancel) {}
        }
        .onAppear {
            // One import at a time (ios-import#3): refused before anything is recorded, never after. A link that
            // "Record instead" has just cancelled is on its way out, not another song.
            if app.importUnderWay, !app.importCancelled {
                app.showToast(.init(text: "Still splitting another song."))
                dismiss()
                return
            }
            rec.onFinished = { url, title in finish(url, title) }
            mic.onFinished = { url, title in finish(url, title) }
            switch source {
            case .app: rec.begin()
            case .microphone: mic.begin()
            }
        }
        .onChange(of: recording, initial: true) { _, now in app.recordingUnderWay = now }
        .onDisappear { app.recordingUnderWay = false; rec.cancel(); mic.cancel() }
    }

    private func switchTo(_ new: Source) {
        guard new != source, !busy else { return }
        sourceRaw = new.rawValue
        switch new {
        case .app: mic.cancel(); rec.begin()
        case .microphone: rec.cancel(); mic.begin()
        }
    }

    private func finish(_ url: URL, _ title: String) {
        dismiss()
        app.importTitleOverride = title
        app.openTake(url)
    }

    private func close() {
        rec.cancel()
        mic.cancel()
        dismiss()
    }

    private static let buttonPadding = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    @ViewBuilder private var micButtons: some View {
        switch (mic.permission, mic.phase) {
        case (.undetermined, _):
            Button("Allow Microphone") { Task { await mic.requestPermission() } }
                .buttonStyle(PrimaryButtonStyle(padding: Self.buttonPadding))
                .keyboardShortcut(.defaultAction)
        case (.denied, _):
            Button("Try Again") { mic.cancel(); mic.begin() }
                .buttonStyle(PrimaryButtonStyle(padding: Self.buttonPadding))
        case (_, .recording):
            Button("Stop & Split") { Task { await mic.stopAndFinish() } }
                .buttonStyle(PrimaryButtonStyle(padding: Self.buttonPadding))
                .keyboardShortcut(.defaultAction)
        case (_, .interrupted):
            Button("Use What I Have") { Task { await mic.stopAndFinish() } }
                .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)))
            Button("Resume") { mic.resume() }
                .buttonStyle(PrimaryButtonStyle(padding: Self.buttonPadding))
                .keyboardShortcut(.defaultAction)
        case (_, .failed):
            Button("Try Again") { mic.reset() }
                .buttonStyle(PrimaryButtonStyle(padding: Self.buttonPadding))
                .keyboardShortcut(.defaultAction)
        case (_, .finishing), (_, .finished):
            EmptyView()
        default:
            Button("Record") { mic.startRecording() }
                .buttonStyle(PrimaryButtonStyle(padding: Self.buttonPadding))
                .keyboardShortcut(.defaultAction)
                .disabled(mic.phase != .monitoring)
        }
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

/// The Microphone choice: which input, its level, the time, and how the take is going.
private struct MicrophonePanel: View {
    let mic: MicRecorder

    var body: some View {
        switch (mic.permission, mic.phase) {
        case (.denied, _):
            VStack(alignment: .leading, spacing: 8) {
                Label("Backline can't use the microphone.", systemImage: "mic.slash")
                    .font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Text("Click Open Privacy Settings and turn on Backline. Then click Try Again.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { MicRecorder.openSettings() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case (.undetermined, _):
            VStack(alignment: .leading, spacing: 8) {
                Label("Record a band, a speaker or a rehearsal", systemImage: "mic")
                    .font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Text("Use your Mac's microphone, a USB microphone or an audio interface. Backline only listens while this window is open.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        case (_, .failed(let failure)):
            failureView(failure)
        default:
            recorder
        }
    }

    private var recorder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Input", selection: Binding(get: { mic.selectedInputID ?? kAudioObjectUnknown },
                                               set: { mic.selectInput($0 == kAudioObjectUnknown ? nil : $0) })) {
                Text("Same as your Mac").tag(kAudioObjectUnknown)
                ForEach(mic.inputs) { input in
                    Text(input.channels > 2 ? "\(input.name) · \(input.channels) inputs" : input.name).tag(input.id)
                }
            }
            .font(Typo.ui(12.5))
            .disabled(mic.isBusy)

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: mic.isStereo ? "waveform.badge.mic" : "mic.fill").font(.system(size: 11, weight: .semibold))
                    Text(mic.inputName + (mic.isStereo ? " · Stereo" : "")).font(Typo.ui(12, .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if mic.isRecording {
                        Text("REC").font(Typo.mono(11, .bold)).foregroundStyle(Theme.danger)
                    }
                }
                .foregroundStyle(Theme.ink3)
                LEDMeter(peakDB: mic.peakDB, active: mic.phase == .monitoring || mic.phase == .recording)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline3))

            HStack(alignment: .firstTextBaseline) {
                Text(formatTime(mic.elapsed)).font(Typo.mono(28, .semibold))
                    .foregroundStyle(mic.isRecording ? Theme.ink : Theme.ink3)
                    .accessibilityLabel("Time recorded")
                Spacer()
                if mic.isRecording { Text("Max 20 min.").font(Typo.ui(11.5)).foregroundStyle(Theme.muted) }
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        Group {
            switch mic.phase {
            case .recording:
                switch mic.quality {
                case .waitingForSound: StatusLine(tone: .live, text: "Recording. Start the song.")
                case .good: StatusLine(tone: .live, text: "Recording")
                case .faint: StatusLine(tone: .warning, text: "A bit quiet. Move closer or turn the input up.")
                case .tooQuiet: StatusLine(tone: .warning, text: "Too quiet. Turn it up.")
                case .silent: StatusLine(tone: .warning, text: "No sound. Is the right input picked?")
                }
            case .interrupted:
                StatusLine(tone: .warning, text: "The input went away. Plug it back in and click Resume.")
            case .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Trimming…").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink2)
                }
            case .finished:
                StatusLine(tone: .good, text: "Done")
            default:
                StatusLine(tone: .idle, text: "Click Record, then start the song.")
            }
        }
        .animation(.smooth(duration: 0.2), value: mic.quality)
        .animation(.smooth(duration: 0.2), value: mic.phase)
    }

    @ViewBuilder private func failureView(_ failure: MicRecorder.Failure) -> some View {
        switch failure {
        case .nothingHeard:
            failureLabel("No music heard.", "Get closer and record at least 10 s.", symbol: "speaker.slash")
        case .noInput:
            failureLabel("No microphone found.", "Plug one in, or pick another input.", symbol: "mic.slash")
        case .engine(let message):
            failureLabel("Couldn't record.", message, symbol: "exclamationmark.triangle")
        }
    }

    private func failureLabel(_ title: String, _ message: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink)
            Text(message).font(Typo.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
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
