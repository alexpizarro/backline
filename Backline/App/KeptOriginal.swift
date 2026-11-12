import AVFoundation
import BacklineKit
import Foundation

/// What a song keeps of the audio it was split from (D18). When the file an import decodes is lossy audio
/// (MP3, AAC), that file is kept as `source.<ext>` instead of writing `original.caf`: it is a fifth to a third
/// of the size, and decoding it again with `AudioDecoder.decode` gives the very samples that were split. When
/// the source is PCM or lossless (a recording included), or nothing better can be done, `original.caf` is
/// written as before. A video's sound is copied out unchanged into `source.m4a` when it is AAC and decodes to
/// the same samples; otherwise the video gets `original.caf` too.
nonisolated enum KeptOriginal {
    enum Plan: Equatable, Sendable {
        /// Keep the file itself, as `source.<ext>`.
        case keepFile(ext: String)
        /// Copy the AAC sound out of a video into `source.m4a`, if it decodes to the same samples.
        case copyOutVideoSound
        /// Write `original.caf` (Apple Lossless) from the decoded song, as before 1.1.
        case writeLossless
    }

    /// Lossy codecs Core Audio reads. Anything else (PCM, Apple Lossless, FLAC, or a format not listed) keeps the
    /// lossless original, so nothing is ever kept at a lower quality than it came in.
    static let lossyFormats: Set<AudioFormatID> = [
        kAudioFormatMPEGLayer1, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3,
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
        kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2,
        kAudioFormatMPEG4AAC_Spatial, kAudioFormatOpus, kAudioFormatAC3, kAudioFormatEnhancedAC3,
        kAudioFormatAMR, kAudioFormatAMR_WB,
    ]
    static let aacFormats: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
    ]

    /// Decides from the file's own tracks (not its name) what to keep.
    static func plan(for url: URL) async -> Plan {
        let asset = AVURLAsset(url: url)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio), audio.count == 1,
              let formats = try? await audio[0].load(.formatDescriptions), formats.count == 1 else { return .writeLossless }
        let codec = CMFormatDescriptionGetMediaSubType(formats[0])
        let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        if hasVideo { return aacFormats.contains(codec) ? .copyOutVideoSound : .writeLossless }
        let ext = url.pathExtension.lowercased()
        guard lossyFormats.contains(codec), AudioDecoder.supportedExtensions.contains(ext) else { return .writeLossless }
        return .keepFile(ext: ext)
    }

    /// Puts the kept source in `folder` and returns its name for the record, or nil when the song should keep
    /// `original.caf` instead. `decoded` is the audio the import split (a video's copied-out sound must decode
    /// to exactly that). A file the app owns (a staged copy, a download) is hard-linked, so nothing is copied
    /// and the staged name can be discarded as before; anything else is copied.
    static func keep(_ url: URL, plan: Plan, decoded: StereoAudio, in folder: URL) async -> String? {
        switch plan {
        case .writeLossless:
            return nil
        case .keepFile(let ext):
            let name = SongStore.sourceName(extension: ext)
            let dst = folder.appendingPathComponent(name)
            let fm = FileManager.default
            try? fm.removeItem(at: dst)
            if ImportStaging.isOwned(url), (try? fm.linkItem(at: url, to: dst)) != nil { return name }
            return (try? fm.copyItem(at: url, to: dst)) != nil ? name : nil
        case .copyOutVideoSound:
            let name = SongStore.sourceName(extension: "m4a")
            let dst = folder.appendingPathComponent(name)
            // Decoding it to check needs one more song-sized copy for a moment; without room, keep the lossless
            // one. A Mac sets no per-app limit (`MemoryBudget.available` is 0), so there it always goes ahead.
            let need = UInt64(decoded.frameCount) * 8 * 2
            let free = MemoryBudget.available
            if free > 0, free < need { return nil }
            do {
                try await copyOutSound(of: url, to: dst)
                let back = try AudioDecoder.decode(dst)
                if same(back, decoded) { return name }
                AppLog.note("kept original: the video's sound decodes differently on its own; writing original.caf")
            } catch {
                AppLog.note("kept original: couldn't copy the video's sound out (\(error.localizedDescription))")
            }
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
    }

    /// Sample for sample the same audio.
    static func same(_ a: StereoAudio, _ b: StereoAudio) -> Bool {
        a.frameCount == b.frameCount && a.sampleRate == b.sampleRate && a.left == b.left && a.right == b.right
    }

    /// Copies a video's audio track into an `.m4a` without decoding or re-encoding it.
    static func copyOutSound(of url: URL, to dst: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let hint = try await track.load(.formatDescriptions).first
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw CocoaError(.fileReadUnsupportedScheme) }
        reader.add(output)
        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        var appended = true
        while appended, let buffer = output.copyNextSampleBuffer() {
            while writer.status == .writing, !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            appended = writer.status == .writing && input.append(buffer)
        }
        // A writer that stopped is never asked to finish (its completion can then come twice).
        guard appended, writer.status == .writing, reader.status != .failed else {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        input.markAsFinished()
        await completion { done in writer.finishWriting(completionHandler: done) }
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Waits for a no-argument completion handler, resuming once however many times it is called. AVFoundation's
    /// awaited forms of these (`await writer.finishWriting()`) crashed when the framework called back twice (a
    /// Simulator crash on 11 November: "continuation resumed twice" inside `finishWriting`), so every such call
    /// in the app goes through here with the completion-handler form.
    static func completion(_ start: (@escaping @Sendable () -> Void) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            start { if once.claim() { done.resume() } }
        }
    }
}

/// True for the first caller only.
private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
