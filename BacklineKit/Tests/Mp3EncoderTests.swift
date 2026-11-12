import AVFoundation
import Foundation
import Testing
@testable import BacklineKit

struct Mp3EncoderTests {
    /// A 440 Hz tone encodes to an MP3 that decodes back to the same length and the same pitch.
    @Test func encodesDecodableMp3() throws {
        let sr = 44_100, seconds = 3
        let n = sr * seconds
        let tone = (0..<n).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / Double(sr))) }
        let enc = try Mp3Encoder(sampleRate: sr, title: "Tone", artist: "Backline")
        var data = enc.id3v2Header()
        for start in stride(from: 0, to: n, by: 4096) {
            let m = min(4096, n - start)
            data.append(try tone.withUnsafeBufferPointer { try enc.encode(left: $0.baseAddress! + start, right: $0.baseAddress! + start, frames: m) })
        }
        data.append(enc.finish())
        #expect(data.count > 10_000)
        #expect(data.prefix(3) == Data("ID3".utf8))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).mp3")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - Double(seconds)) < 0.15, "duration \(duration)")

        let audio = try AudioDecoder.decode(url)
        // Zero crossings give the pitch: ~880 per second for 440 Hz.
        var crossings = 0
        for i in (sr / 2)..<(sr * 5 / 2) where (audio.left[i - 1] < 0) != (audio.left[i] < 0) { crossings += 1 }
        #expect(abs(Double(crossings) / 2 - 880) < 12, "crossings \(crossings)")
    }
}
