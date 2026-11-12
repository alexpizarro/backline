import AppKit
import BacklineKit
import SwiftUI

/// Links: everything that turns a pasted or dropped link into an import (paritymac WP2, WP9). The music-service
/// flow is `AppModel+Spotify.swift` and the last resort `AppModel+SongService.swift`, as on iOS.
extension AppModel {
    /// Pasted / dropped YouTube link → download the audio → normal import. `metadata` is given when
    /// the song's own title, artist, cover and source came from somewhere else (a link to a song on a music
    /// service): the screens and the saved song then keep those, not the video's.
    func openYouTube(_ video: YouTubeImport.Video, metadata: ImportMetadata? = nil) {
        guard !resetting else { return }
        guard YouTubeImport.isEnabled else { return }
        // "Already in the library?" waits for the Library's launch read (UIP-05).
        guard libraryLoaded else {
            Task { [weak self] in
                await self?.libraryReady()
                self?.openYouTube(video, metadata: metadata)
            }
            return
        }
        lastYouTube = video
        // The music-service link stays the thing to try again; any other link is forgotten.
        if metadata == nil { lastLink = nil }
        lastImportURL = nil
        // Already in the library? Reopen instantly.
        if let existing = library.first(where: { $0.sourceName == "youtube:\(video.id)" }) {
            // A music-service link's lookup that found a song already here ends with it (it kept this set).
            downloadingFromYouTube = false
            select(existing)
            return
        }
        persistCurrent()
        stopPlayback()
        pauseBackgroundWork()
        importTitle = metadata?.title ?? ""
        importArtist = metadata?.artist ?? ""
        importArtwork = nil
        if let data = metadata?.artwork {
            // Decoded small, off the main thread (UIP-10).
            Task { [weak self] in
                let image = await Self.artworkImage(data)
                guard let self, self.lastYouTube?.id == video.id, self.importArtwork == nil else { return }
                self.importArtwork = image
            }
        }
        importArtworkOverride = metadata?.artwork
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        downloadingFromYouTube = true
        let cancel = CancelBox()
        cancelBox = cancel
        let epoch = ResetBackline.epoch
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        importTask = Task { [weak self] in
            do {
                let progress: @Sendable (Double) -> Void = { p in
                    Task { @MainActor in self?.importProgress = ImportProgress(phase: 0, fraction: p, secondsRemaining: nil) }
                }
                let isCancelled: @Sendable () -> Bool = { cancel.value || !ResetBackline.isCurrent(epoch) }
                // The title is known as soon as YouTube answers: show it, and the video's picture, while the
                // audio downloads (links L8). The song's own details win when a music-service link gave them.
                let onMetadata: @Sendable (String?, String?) -> Void = { title, author in
                    Task { @MainActor in
                        guard let self, ResetBackline.isCurrent(epoch), self.cancelBox === cancel, self.downloadingFromYouTube,
                              metadata == nil else { return }
                        if let title { self.importTitle = title }
                        self.importArtist = author ?? ""
                        if self.importArtwork == nil {
                            Task { @MainActor [weak self] in
                                guard let data = await YouTubeImport.thumbnail(for: video.id), let self,
                                      self.cancelBox === cancel, self.downloadingFromYouTube else { return }
                                self.importArtworkOverride = data
                                self.importArtwork = await Self.artworkImage(data)
                            }
                        }
                    }
                }
                var result: (file: URL, title: String?, uploader: String?)?
                do {
                    result = try await self?.downloadYouTube(video, onMetadata: onMetadata, onStage: { stage in
                        Task { @MainActor in self?.linkWait.stage = stage }
                    }, progress: progress, isCancelled: isCancelled)
                } catch {
                    // This Mac couldn't get it: the song service may (the owner's server, a last resort, D11), by this
                    // one video's link and whatever the song's name is known to be.
                    guard let self, self.cancelBox === cancel, !isCancelled() else { throw error }
                    let ask = SongService.Ask(artist: metadata?.artist, title: metadata?.title,
                                              reference: "https://www.youtube.com/watch?v=\(video.id)")
                    guard let song = try await self.songServiceRescue(after: error, ask: ask, expectedSeconds: nil,
                                                                      isCancelled: isCancelled) else { throw error }
                    result = (song.file, song.title, song.artist)
                }
                // Finished just as it was cancelled or replaced. The file stays: a link pasted again may be the
                // same video, writing to the same name.
                if isCancelled() { throw CancellationError() }
                guard let self, let result, self.cancelBox === cancel else { return }
                self.downloadingFromYouTube = false
                if let t = metadata?.title ?? result.title { self.importTitle = t }
                self.importTitleOverride = metadata?.title ?? result.title
                self.importArtistOverride = metadata?.artist ?? result.uploader
                self.importSourceOverride = metadata?.source ?? "youtube:\(video.id)"
                self.continueImport(result.file)
            } catch {
                // An import that was cancelled, or that a newer one replaced, ends quietly: a link pasted again
                // straight after Cancel must not be covered by the old download's ending (links L8).
                guard let self, ResetBackline.isCurrent(epoch), self.cancelBox === cancel else { return }
                self.downloadingFromYouTube = false
                if error is CancellationError || cancel.value {
                    withAnimation(.smooth) { self.screen = self.song == nil ? .empty : .mixer }
                } else {
                    withAnimation(.smooth) { self.screen = .failed(error.localizedDescription) }
                }
            }
        }
    }

    #if DEBUG
    /// Tests stand in for the download (links L8): the stub reports the title and ends when it likes.
    static var youTubeDownloadForTesting: ((YouTubeImport.Video, @escaping @Sendable (String?, String?) -> Void,
                                            @escaping @Sendable () -> Bool) async throws -> (file: URL, title: String?, uploader: String?))?
    #endif

    /// One video's audio onto disk: the Swift engine shared with iOS (`YouTubeImport`, `Backline/App/YouTube/`),
    /// or yt-dlp in a build made with `BACKLINE_YTDLP=1` (D10, one release only). A signed-in session's cookies
    /// are read from the sign-in store for this one download and never kept.
    private func downloadYouTube(_ video: YouTubeImport.Video, onMetadata: @escaping @Sendable (String?, String?) -> Void,
                                 onStage: @escaping @Sendable (YouTubeExtractor.Stage) -> Void,
                                 progress: @escaping @Sendable (Double) -> Void,
                                 isCancelled: @escaping @Sendable () -> Bool) async throws -> (file: URL, title: String?, uploader: String?) {
        #if DEBUG
        if let stub = Self.youTubeDownloadForTesting { return try await stub(video, onMetadata, isCancelled) }
        #endif
        #if BACKLINE_YTDLP
        let cookieFile = YouTubeSignIn.isEnabled && YouTubeSignIn.isSignedIn ? await YouTubeSignIn.writeCookieFile() : nil
        do {
            let r = try await YTDLPImport.download(video, cookieFile: cookieFile, progress: progress, isCancelled: isCancelled)
            if let cookieFile { await YouTubeSignIn.finish(cookieFile: cookieFile) }
            onMetadata(r.title, r.uploader)
            return (r.file, r.title, r.uploader)
        } catch {
            if let cookieFile { await YouTubeSignIn.finish(cookieFile: cookieFile) }
            // Sent cookies but YouTube still wants a sign-in: the session expired.
            if cookieFile != nil, case YouTubeImport.Failure.needsSignIn = error { await YouTubeSignIn.sessionExpired() }
            throw error
        }
        #else
        let cookies = YouTubeSignIn.isEnabled && YouTubeSignIn.isSignedIn ? await YouTubeSignIn.cookies() : []
        do {
            let r = try await YouTubeImport.download(video, cookies: cookies, onMetadata: onMetadata, onStage: onStage, progress: progress,
                                                     isCancelled: isCancelled)
            return (r.file, r.title, r.uploader)
        } catch {
            // Already signed in and YouTube still says no (age limit, members only): signing in again won't
            // help, so point at recording instead of looping on the sign-in window (as iOS does).
            if !cookies.isEmpty, case YouTubeImport.Failure.needsSignIn = error {
                throw YouTubeImport.Failure.failed("Can't get this one. Record it instead.")
            }
            throw error
        }
        #endif
    }

    /// Opens whatever was pasted, dropped or chosen from the menu: a music or video file link, a YouTube or Vimeo
    /// link, or a link to a song, album or playlist on a music service. Returns false for anything else (the caller
    /// says "Can't get a song from this link.").
    func openText(_ text: String) -> Bool {
        guard !resetting else { return false }
        guard let link = WebLink.classify(text) else { return false }
        // One import at a time (ios-import#3): handled, by saying so.
        guard !refuseAnotherImport() else { return true }
        // A link that launched the app: its "already in the library?" lookup waits for the Library (UIP-05).
        guard libraryLoaded else {
            Task { [weak self] in
                await self?.libraryReady()
                _ = self?.openText(text)
            }
            return true
        }
        switch link {
        case .youTube(let v) where YouTubeImport.isEnabled: openYouTube(v); return true
        case .spotify(let ref) where SpotifyImport.isEnabled: openSpotify(ref); return true
        case .file(let url): openFileLink(url); return true
        case .vimeo(let id, let hash):
            openVimeo(id: id, hash: hash, page: text.split(whereSeparator: \.isWhitespace).lazy.compactMap { WebLink.webURL(String($0)) }
                .first { WebLink.vimeo($0) == link })
            return true
        default: return false
        }
    }

    /// A Vimeo link → the audio rendition → the normal import, with the video's title, channel and picture.
    func openVimeo(id: String, hash: String?, page: URL? = nil) {
        guard !resetting else { return }
        guard libraryLoaded else {
            Task { [weak self] in
                await self?.libraryReady()
                self?.openVimeo(id: id, hash: hash, page: page)
            }
            return
        }
        lastYouTube = nil
        lastLink = .vimeo(id: id, hash: hash)
        lastImportURL = nil
        if let existing = library.first(where: { $0.sourceName == "vimeo:\(id)" }) {
            select(existing)
            return
        }
        persistCurrent()
        stopPlayback()
        pauseBackgroundWork()
        importTitle = ""
        importArtist = ""
        importArtwork = nil
        importArtworkOverride = nil
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        downloadingFromYouTube = true
        let cancel = CancelBox()
        cancelBox = cancel
        let epoch = ResetBackline.epoch
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        importTask = Task { [weak self] in
            let isCancelled: @Sendable () -> Bool = { cancel.value || !ResetBackline.isCurrent(epoch) }
            do {
                let result = try await VimeoExtractor.fetch(id: id, hash: hash, link: page, into: ImportStaging.downloadsDirectory,
                                                            onMetadata: { title, author, thumbnail in
                    Task { @MainActor in
                        guard let self, ResetBackline.isCurrent(epoch), self.cancelBox === cancel else { return }
                        if let title { self.importTitle = title }
                        self.importArtist = author ?? ""
                        guard let thumbnail else { return }
                        Task { @MainActor [weak self] in
                            guard let data = await VimeoExtractor.thumbnail(thumbnail), let self, self.cancelBox === cancel,
                                  self.lastLink == .vimeo(id: id, hash: hash) else { return }
                            self.importArtworkOverride = data
                            self.importArtwork = await Self.artworkImage(data)
                        }
                    }
                }, progress: { p in
                    Task { @MainActor in self?.importProgress = ImportProgress(phase: 0, fraction: p, secondsRemaining: nil) }
                }, isCancelled: isCancelled)
                if isCancelled() { throw CancellationError() }
                guard let self, self.cancelBox === cancel else { return }
                self.downloadingFromYouTube = false
                if let t = result.title { self.importTitle = t }
                self.importTitleOverride = result.title
                self.importArtistOverride = result.author
                self.importSourceOverride = "vimeo:\(id)"
                self.continueImport(result.file)
            } catch {
                self?.endLinkDownload(error, cancel: cancel, epoch: epoch)
            }
        }
    }

    /// A link to a music or video file → one download → the normal import, on the "Getting the song" screen.
    func openFileLink(_ url: URL) {
        guard !resetting else { return }
        lastYouTube = nil
        lastLink = .file(url)
        lastImportURL = nil
        persistCurrent()
        stopPlayback()
        pauseBackgroundWork()
        importTitle = ImportStaging.displayName(for: url)
        importArtist = ""
        importArtwork = nil
        importArtworkOverride = nil
        importProgress = ImportProgress(phase: 0, fraction: 0, secondsRemaining: nil)
        downloadingFromYouTube = true
        let cancel = CancelBox()
        cancelBox = cancel
        let epoch = ResetBackline.epoch
        withAnimation(.smooth(duration: 0.35)) { screen = .analyzing }
        importTask = Task { [weak self] in
            let isCancelled: @Sendable () -> Bool = { cancel.value || !ResetBackline.isCurrent(epoch) }
            do {
                let file = try await FileLinkDownload.download(url, into: ImportStaging.downloadsDirectory, progress: { p in
                    Task { @MainActor in self?.importProgress = ImportProgress(phase: 0, fraction: p, secondsRemaining: nil) }
                }, isCancelled: isCancelled)
                if isCancelled() { try? FileManager.default.removeItem(at: file); throw CancellationError() }
                guard let self, self.cancelBox === cancel else { try? FileManager.default.removeItem(at: file); return }
                self.downloadingFromYouTube = false
                self.continueImport(file)
            } catch {
                self?.endLinkDownload(error, cancel: cancel, epoch: epoch)
            }
        }
    }

    /// How a Vimeo or file-link download that didn't finish ends: quietly when it was cancelled or a newer import
    /// replaced it (links L8), otherwise on the failure screen.
    private func endLinkDownload(_ error: Error, cancel: CancelBox, epoch: Int) {
        guard ResetBackline.isCurrent(epoch), cancelBox === cancel else { return }
        downloadingFromYouTube = false
        if error is CancellationError || cancel.value {
            withAnimation(.smooth) { screen = song == nil ? .empty : .mixer }
        } else {
            withAnimation(.smooth) { screen = .failed(error.localizedDescription) }
        }
    }

    func retryImport() {
        // A music-service link is read and matched again, so the song keeps its own name and cover (S04).
        if case .spotify(let ref) = lastLink, lastImportURL == nil { openSpotify(ref); return }
        if let v = lastYouTube, lastImportURL == nil { openYouTube(v); return }
        if lastImportURL == nil {
            switch lastLink {
            case .file(let url): openFileLink(url); return
            case .vimeo(let id, let hash): openVimeo(id: id, hash: hash); return
            default: break
            }
        }
        if let url = lastImportURL { open(url) } else { screen = .empty }
    }

    /// "Not now" on a failed import: back to the song that was open, or to the start screen.
    func dismissFailure() {
        withAnimation(.smooth) { screen = song == nil ? .empty : .mixer }
    }
}
