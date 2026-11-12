import AVFoundation
import Accelerate
import BacklineKit
import Foundation

/// Songs split before part levels existed (U05) are measured once in the background: every stored part
/// is streamed from disk half a second at a time, so nothing is loaded whole. The result reaches the rows
/// at the next pause, so the list never rearranges itself while the song plays.
///
/// Port of backline-ios Backline/App/PartLevelsJob.swift.
extension AppModel {
    func measurePartLevels(_ rec: SongRecord) {
        // Not beside an import (ios-import#1): its end measures the open song.
        guard !importUnderWay else { return }
        let store = self.store
        Task.detached(priority: .utility) {
            guard let measured = Self.measureStoredLevels(rec, store: store) else { return }
            await MainActor.run {
                guard self.song?.id == rec.id, self.song?.levels == nil || self.song?.instruments == nil else { return }
                self.pendingLevels = measured
                if !self.isPlaying { self.applyPendingLevels() }
            }
        }
    }

    func applyPendingLevels() {
        guard let measured = pendingLevels, var rec = song else { return }
        pendingLevels = nil
        rec.levels = measured.levels
        rec.instruments = measured.instruments
        song = rec
        persistCurrent()
    }

    /// Per-part levels of a stored song: its parts as stored (undoing each part's storage gain) against
    /// their sum, which is the whole song (folded parts already live in Other). In the same pass the sound
    /// classifier hears the song, and the guitar and the lead where they play (U06).
    nonisolated static func measureStoredLevels(_ rec: SongRecord, store: SongStore)
        -> (levels: [String: PartLevel], instruments: [String: InstrumentShares])? {
        var parts: [(key: String, url: URL, gain: Float, inMix: Bool)] = rec.stems.map {
            ($0.rawValue, store.stemURL(rec.id, $0), rec.storageScale[$0.rawValue] ?? 1, true)
        }
        if let gs = rec.guitarSplit {
            parts.append((StemKind.leadGuitar.rawValue, store.stemURL(rec.id, .leadGuitar), gs.leadScale, false))
            parts.append((StemKind.rhythmGuitar.rawValue, store.stemURL(rec.id, .rhythmGuitar), gs.rhythmScale, false))
            if gs.otherAdjusted { parts.append((ImportPipeline.otherSplitKey, store.otherSplitURL(rec.id), gs.otherScale, false)) }
        }
        guard let files = try? parts.map({ try AVAudioFile(forReading: $0.url, commonFormat: .pcmFormatFloat32, interleaved: false) })
        else { return nil }
        let n = PartPresence.frame
        let bufs = files.map { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: AVAudioFrameCount(n))! }
        // An AAC part (D19) holds half its stored level: its format gain comes in with the storage gain's undo.
        let formats = files.map(SongStore.formatGain)
        var mixL = [Float](repeating: 0, count: n), mixR = [Float](repeating: 0, count: n)
        var partFrames = [[Float]](repeating: [], count: parts.count), mixFrames: [Float] = []
        let mixEar = try? InstrumentListener()
        let heard = [StemKind.guitar.rawValue, StemKind.leadGuitar.rawValue]
        let ears: [String: InstrumentListener] = Dictionary(uniqueKeysWithValues: heard.compactMap { k in
            parts.contains { $0.key == k } ? (try? InstrumentListener()).map { (k, $0) } : nil
        })
        // This half second of the guitar and the lead, kept until the mix for it is complete.
        var held: [String: (l: [Float], r: [Float], gain: Float, ms: Float)] = [:]
        while true {
            mixL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            mixR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            var count = 0
            for (i, f) in files.enumerated() {
                // Reading at the end of a file throws: a part that ended reads as silence.
                if f.framePosition < f.length {
                    guard (try? f.read(into: bufs[i], frameCount: AVAudioFrameCount(n))) != nil else { return nil }
                } else {
                    bufs[i].frameLength = 0
                }
                let m = Int(bufs[i].frameLength)
                count = max(count, m)
                guard m > 0, let ch = bufs[i].floatChannelData else { partFrames[i].append(0); continue }
                let undo = formats[i] / max(parts[i].gain, 1e-6)
                let r = bufs[i].format.channelCount > 1 ? ch[1] : ch[0]
                var sl: Float = 0, sr: Float = 0
                vDSP_svesq(ch[0], 1, &sl, vDSP_Length(m))
                vDSP_svesq(r, 1, &sr, vDSP_Length(m))
                partFrames[i].append((sl + sr) / Float(2 * m) * undo * undo)
                if ears[parts[i].key] != nil {
                    held[parts[i].key] = (Array(UnsafeBufferPointer(start: ch[0], count: m)), Array(UnsafeBufferPointer(start: r, count: m)),
                                          undo, (sl + sr) / Float(2 * m) * undo * undo)
                }
                if parts[i].inMix {
                    var u = undo
                    mixL.withUnsafeMutableBufferPointer { vDSP_vsma(ch[0], 1, &u, $0.baseAddress!, 1, $0.baseAddress!, 1, vDSP_Length(m)) }
                    mixR.withUnsafeMutableBufferPointer { vDSP_vsma(r, 1, &u, $0.baseAddress!, 1, $0.baseAddress!, 1, vDSP_Length(m)) }
                }
            }
            if count < n / 4 {
                for i in partFrames.indices where partFrames[i].count > mixFrames.count { partFrames[i].removeLast() }
                break
            }
            var sl: Float = 0, sr: Float = 0
            vDSP_svesq(mixL, 1, &sl, vDSP_Length(count))
            vDSP_svesq(mixR, 1, &sr, vDSP_Length(count))
            let mixMS = (sl + sr) / Float(2 * count)
            mixFrames.append(mixMS)
            mixL.withUnsafeBufferPointer { l in mixR.withUnsafeBufferPointer { r in mixEar?.feed(left: l.baseAddress!, right: r.baseAddress!, count: count) } }
            for (k, h) in held where !h.l.isEmpty && PartPresence.isActive(part: h.ms, mix: mixMS) {
                h.l.withUnsafeBufferPointer { l in h.r.withUnsafeBufferPointer { r in ears[k]?.feed(left: l.baseAddress!, right: r.baseAddress!, count: h.l.count, gain: h.gain) } }
            }
            held = [:]
        }
        var out: [String: PartLevel] = [:]
        for (i, p) in parts.enumerated() { out[p.key] = PartPresence.level(part: partFrames[i], mix: mixFrames) }
        var instruments: [String: InstrumentShares] = [:]
        instruments["mix"] = mixEar?.finish()
        if let g = ears[StemKind.guitar.rawValue]?.finish() { instruments[StemKind.guitar.rawValue] = g }
        if let l = ears[StemKind.leadGuitar.rawValue]?.finish() { instruments["lead"] = l }
        return (out, instruments)
    }
}
