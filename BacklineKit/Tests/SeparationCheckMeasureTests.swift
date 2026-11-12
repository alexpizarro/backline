import CoreML
import Foundation
import XCTest
@testable import BacklineKit

/// Measurement, not a gate (skipped unless `BL_RECON_SONGS` lists audio files, comma-separated): the add-up
/// check's two figures for real songs split on the CPU and on the GPU, and for splits spoiled the way the Mac saw
/// (two six-part passes at once, bypassing `PredictionGate`). The thresholds in `DemucsSeparator.reconstructs`
/// come from these numbers.
final class SeparationCheckMeasureTests: XCTestCase {
    func testMeasure() async throws {
        let list = ProcessInfo.processInfo.environment["BL_RECON_SONGS"] ?? ""
        try XCTSkipIf(list.isEmpty, "set BL_RECON_SONGS")
        let songs = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let units = (ProcessInfo.processInfo.environment["BL_RECON_UNITS"] ?? "gpu,cpu").split(separator: ",")
        let spoil = Int(ProcessInfo.processInfo.environment["BL_RECON_SPOIL"] ?? "0") ?? 0
        let url = try await DemucsSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: PredictionGateTests.package)
        for song in songs {
            let audio = try AudioDecoder.decode(song)
            for u in units {
                let sep = try DemucsSeparator(modelURL: url, computeUnits: u == "cpu" ? .cpuOnly : .cpuAndGPU)
                let t = Date()
                let parts = try sep.separate(audio)
                let r = DemucsSeparator.reconstruction(of: parts, song: audio)
                print(String(format: "[recon] %@ %@ power=%.5f correlation=%.5f (%.0f s)", song.lastPathComponent, String(u),
                             r.power, r.correlation, Date().timeIntervalSince(t)))
            }
            // Spoiled on purpose: two passes at once on the GPU, without the gate.
            for k in 0..<spoil {
                let a = try DemucsSeparator(modelURL: url, computeUnits: .cpuAndGPU)
                let b = try DemucsSeparator(modelURL: url, computeUnits: .cpuAndGPU)
                let pair = try await withThrowingTaskGroup(of: [StereoAudio].self) { group in
                    for s in [a, b] { group.addTask { try s.separateHoldingGate(audio, progress: { _ in }, isCancelled: { false }) } }
                    var out: [[StereoAudio]] = []
                    for try await r in group { out.append(r) }
                    return out
                }
                for p in pair {
                    let r = DemucsSeparator.reconstruction(of: p, song: audio)
                    print(String(format: "[recon] %@ concurrent#%d power=%.5f correlation=%.5f", song.lastPathComponent, k, r.power, r.correlation))
                }
            }
        }
    }
}
