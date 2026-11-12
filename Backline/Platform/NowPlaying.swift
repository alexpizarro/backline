import AppKit
import BacklineKit
import MediaPlayer

/// Now Playing in Control Center and the menu bar, the keyboard's play/pause key and AirPods (WP6). Next and
/// Previous move one bar, which is what a double-press on AirPods or a Bluetooth foot switch should do in a
/// practice session.
///
/// Ported from backline-ios Backline/Platform/NowPlaying.swift: no Live Activity on the Mac, `NSImage` for the
/// artwork, and the song's tape cover when it has no picture, as on iOS.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()
    private weak var model: AppModel?
    private var artworkKey: String?
    private var cachedArtwork: MPMediaItemArtwork?

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        Self.registerCommands(MPRemoteCommandCenter.shared())
        refresh()
    }

    /// Handlers may be called off the main thread: hop to it, answer "success" immediately. The closures are
    /// made in a nonisolated function, or they inherit main-actor isolation and trap when MediaPlayer calls them
    /// on its own queue.
    nonisolated private static func registerCommands(_ c: MPRemoteCommandCenter) {
        c.playCommand.addTarget { _ in dispatch { $0.play() } }
        c.pauseCommand.addTarget { _ in dispatch { $0.pause() } }
        c.togglePlayPauseCommand.addTarget { _ in dispatch { $0.togglePlay() } }
        c.nextTrackCommand.addTarget { _ in dispatch { $0.nudge(bars: 1) } }
        c.previousTrackCommand.addTarget { _ in dispatch { $0.nudge(bars: -1) } }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            return dispatch { $0.seek(to: t) }
        }
        for cmd in [c.skipForwardCommand, c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand,
                    c.changePlaybackRateCommand] { cmd.isEnabled = false }
    }

    nonisolated private static func dispatch(_ body: @escaping @MainActor @Sendable (AppModel) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in
            guard let model = NowPlaying.shared.model, model.song != nil else { return }
            body(model)
        }
        return .success
    }

    /// Call whenever the song, play state, speed or a settled seek changes.
    func refresh() {
        let center = MPNowPlayingInfoCenter.default()
        guard let model, let song = model.song else {
            if center.nowPlayingInfo != nil { center.nowPlayingInfo = nil }
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyPlaybackDuration: song.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.position,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying ? Double(model.settings.speed) / 100 : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(model.settings.speed) / 100,
        ]
        if let artist = song.artist { info[MPMediaItemPropertyArtist] = artist }
        if let art = artwork(for: song, image: model.artwork, parts: model.stems) { info[MPMediaItemPropertyArtwork] = art }
        center.nowPlayingInfo = info
        center.playbackState = model.isPlaying ? .playing : .paused
    }

    /// The song's own picture, or its tape cover rendered once (3.5), so Now Playing never shows a blank square
    /// or a generic icon.
    private func artwork(for song: SongRecord, image: NSImage?, parts: [StemKind]) -> MPMediaItemArtwork? {
        // Keyed on whether the real picture is here, so artwork that arrives later replaces the tape cover.
        let key = song.id + (image == nil ? "#tape" : "")
        if artworkKey == key { return cachedArtwork }
        artworkKey = key
        guard let picture = image ?? TapeCover.image(title: song.title, parts: parts, id: song.id) ?? NSApp?.applicationIconImage else {
            cachedArtwork = nil
            return nil
        }
        cachedArtwork = Self.makeArtwork(picture)
        return cachedArtwork
    }

    /// MediaPlayer asks for the image on its own queue when it publishes Now Playing info. A closure written in
    /// this main-actor class would trap there (it did, on an iPhone 15 Pro), so it is made in a nonisolated function.
    nonisolated static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        nonisolated(unsafe) let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
