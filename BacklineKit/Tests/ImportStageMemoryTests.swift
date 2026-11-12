import AVFoundation
import CoreML
import Foundation
import XCTest
@testable import BacklineKit

/// D20: the import's two stages before the parts are worked on, measured on this Mac for long songs, to set
/// and check `MemoryBudget`'s figures (the app's `ImportPipeline.process` is measured in the app's tests).
/// Run on its own, it needs the six-part model package:
///   BL_STAGE_MEMORY=540,1200 BL_SIX_PART_MODEL=Backline/Resources/HTDemucs6s.mlpackage swift test --filter ImportStageMemoryTests
final class ImportStageMemoryTests: XCTestCase {
    /// Decoding an AAC file of each length, then the six-part split of the decoded song: the footprint each adds
    /// beside the song, in MB and in song copies.
    func testDecodeAndSplitFootprint() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["BL_STAGE_MEMORY"], let pkg = env["BL_SIX_PART_MODEL"] else {
            throw XCTSkip("set BL_STAGE_MEMORY (seconds) and BL_SIX_PART_MODEL (the .mlpackage)")
        }
        let units: MLComputeUnits = env["BL_STAGE_CPU"] != nil ? .cpuOnly : .cpuAndGPU
        let modelURL = try await DemucsSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: URL(fileURLWithPath: pkg))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for seconds in list.split(separator: ",").compactMap({ Double($0) }) {
            // The file, written in AAC as most songs arrive, from a song made in memory and dropped again.
            let file = dir.appendingPathComponent("song-\(Int(seconds)).m4a")
            try autoreleasepool { try Self.writeAAC(GuitarSplitterMemoryTests.looped(seconds: seconds), to: file) }
            let a = Double(Int(seconds * 44_100) * 8)

            let d = FootprintSampler.measure { try? AudioDecoder.decode(file) }
            guard let song = d.value else { XCTFail("decode"); return }
            let decodeAdded = Double(d.peak) - Double(d.before)
            print(String(format: "[stage-memory] %.0f s decode: before %.0f MB, peak %.0f MB, added %.0f MB = %.2f a (a = %.0f MB)",
                         seconds, Double(d.before) / 1e6, Double(d.peak) / 1e6, decodeAdded / 1e6, decodeAdded / a, a / 1e6))

            let t0 = Date()
            let s = FootprintSampler.measure { () -> [StereoAudio]? in
                guard let sep = try? DemucsSeparator(modelURL: modelURL, computeUnits: units) else { return nil }
                return try? sep.separate(song)
            }
            XCTAssertEqual(s.value?.count, 6)
            let splitAdded = Double(s.peak) - Double(s.before)
            print(String(format: "[stage-memory] %.0f s six-part split (%@, %.0f s): before %.0f MB, peak %.0f MB, added %.0f MB = %.2f a beside the song; with the song %.2f a",
                         seconds, units == .cpuOnly ? "CPU" : "GPU", Date().timeIntervalSince(t0), Double(s.before) / 1e6,
                         Double(s.peak) / 1e6, splitAdded / 1e6, splitAdded / a, splitAdded / a + 1))
        }
    }

    /// The lead guitar model over guitar + Other of each length (the lead refinement's model step): the footprint
    /// it adds beside its input. `BL_STAGE_MEMORY` and `BL_LEAD_MODEL` (the .mlpackage).
    func testLeadModelFootprint() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["BL_STAGE_MEMORY"], let pkg = env["BL_LEAD_MODEL"] else {
            throw XCTSkip("set BL_STAGE_MEMORY (seconds) and BL_LEAD_MODEL (the .mlpackage)")
        }
        let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: pkg))
        defer { try? FileManager.default.removeItem(at: compiled) }
        for seconds in list.split(separator: ",").compactMap({ Double($0) }) {
            let src = GuitarSplitterMemoryTests.looped(seconds: seconds)
            let a = Double(src.frameCount * 8)
            let t0 = Date()
            let m = FootprintSampler.measure { () -> StereoAudio? in
                guard let model = try? LeadSeparator(modelURL: compiled) else { return nil }
                return try? model.lead(of: src)
            }
            XCTAssertNotNil(m.value)
            let added = Double(m.peak) - Double(m.before)
            print(String(format: "[stage-memory] %.0f s lead model (%.0f s): added %.0f MB = %.2f a beside its input (a = %.0f MB)",
                         seconds, Date().timeIntervalSince(t0), added / 1e6, added / a, a / 1e6))
        }
    }

    static func writeAAC(_ audio: StereoAudio, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let chunk = 1 << 16
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        var pos = 0
        while pos < audio.frameCount {
            let n = min(chunk, audio.frameCount - pos)
            audio.left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + pos, count: n) }
            audio.right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress! + pos, count: n) }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            pos += n
        }
    }
}
