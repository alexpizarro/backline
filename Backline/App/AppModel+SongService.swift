import BacklineKit
import Foundation
import SwiftUI

// Ported from iOS `Backline/App/AppModel+SongService.swift` (paritymac WP2, decision D11). The Mac has no
// full-screen player to expand and no screen to keep awake; everything else is the same.

extension AppModel {
    /// After this Mac couldn't get a song from a link: the song service, when it is on and could help (owner,
    /// 6 November 2026). Nil when it doesn't apply (it's off, the song is too long, the Mac is offline) or it failed
    /// too, so the caller shows the Mac's own failure. "Trying another way…" while it works; Cancel stops it.
    func songServiceRescue(after error: Error?, ask: SongService.Ask, expectedSeconds: Double?,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> SongService.Song? {
        guard SongService.isEnabled, ask.isUsable else { return nil }
        if let error {
            if error is CancellationError { throw error }
            if let failure = error as? YouTubeImport.Failure, case .tooLong = failure { return nil }
            // Offline: the service can't be reached either.
            if error.localizedDescription == YouTubeExtractor.networkMessage { return nil }
        }
        tryingAnotherWay = true
        linkWait.serviceBegan()
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        defer {
            tryingAnotherWay = false
            linkWait.serviceEnded()
        }
        #if DEBUG
        if let mode = SongServiceStub.mode {
            try await Task.sleep(for: .seconds(4))   // long enough for the harness to see "Trying another way…"
            if isCancelled() { throw CancellationError() }
            print("[harness] song-service-stub \(mode)")
            return nil
        }
        #endif
        guard let config = SongService.config else { return nil }
        do {
            // The service's audio fills the bar as it arrives (L2).
            return try await SongService.fetch(ask, expectedSeconds: expectedSeconds, config: config,
                                               into: ImportStaging.downloadsDirectory, progress: { [weak self] p in
                Task { @MainActor in self?.importProgress = ImportProgress(phase: 0, fraction: p, secondsRemaining: nil) }
            }, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.note("song service: no song (\(error))")
            return nil
        }
    }

    /// Nothing on YouTube passed the rules, the person turned every recording down, or the search itself failed (L3):
    /// the song service may know the song by its name. Its audio is used only when its length is within 8 s of the
    /// song's; otherwise, or when the service is off, `otherwise` ("Couldn't find this song." unless the search
    /// failed).
    func rescueSpotifyOrFail(otherwise: String = SpotifyImport.noMatchMessage) {
        guard let song = spotify.song, SongService.isEnabled else {
            failSpotify(otherwise)
            return
        }
        // Longer than this Mac takes: the import would refuse it, so the service isn't asked (it's billed).
        guard song.seconds <= DeviceLimits.maxSongSeconds + 1 else {
            failSpotify(DeviceLimits.tooLongMessage())
            return
        }
        let generation = spotify.generation
        let epoch = ResetBackline.epoch
        let stop = spotify.renewCancel()
        spotify.finding = false
        spotify.ask = nil
        spotify.others = nil
        spotify.owning = true
        downloadingFromYouTube = true
        // "None of these" after "Wrong song?" comes from a sheet over the player or the start screen: the screen that
        // says "Trying another way…" and has Cancel comes back, as when the link was first opened.
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        spotify.run { [weak self] in
            guard let self else { return }
            do {
                let rescued = try await self.songServiceRescue(after: nil, ask: SongService.Ask(artist: song.artist, title: song.title),
                                                               expectedSeconds: song.seconds,
                                                               isCancelled: { stop() || !ResetBackline.isCurrent(epoch) })
                guard self.spotify.generation == generation, ResetBackline.isCurrent(epoch) else { return }
                guard let rescued else {
                    self.failSpotify(otherwise)
                    return
                }
                self.spotify.settle()
                self.downloadingFromYouTube = false
                self.importTitle = song.title
                self.importTitleOverride = song.title
                self.importArtistOverride = song.artist
                self.importSourceOverride = self.spotify.sourceName ?? "spotify:\(song.id ?? "")"
                self.continueImport(rescued.file)
            } catch {
                guard self.spotify.generation == generation, ResetBackline.isCurrent(epoch) else { return }
                self.cancelSpotifyIfRunning()
            }
        }
    }
}
