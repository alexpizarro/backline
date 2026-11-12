import Accelerate
import CoreML
import Foundation
import XCTest
@testable import BacklineKit

/// Measurement, not a gate (skipped unless `BL_ADDUP_SONG` names an audio file): why a song's six parts don't add
/// back up to it. Prints the song's own figures (peak, stereo width, how much is out of phase), each part's power
/// against the song's, and the add-up figures with each part left out in turn.
final class SeparationAddUpProbeTests: XCTestCase {
    func testProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BL_ADDUP_SONG"] else { throw XCTSkip("set BL_ADDUP_SONG") }
        let song = try AudioDecoder.decode(URL(fileURLWithPath: path))
        let n = song.frameCount
        func power(_ x: [Float]) -> Float { var p: Float = 0; vDSP_svesq(x, 1, &p, vDSP_Length(x.count)); return p }
        func dot(_ a: [Float], _ b: [Float]) -> Float { var d: Float = 0; vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count))); return d }
        var mid = [Float](repeating: 0, count: n), side = mid
        var half: Float = 0.5
        vDSP_vasm(song.left, 1, song.right, 1, &half, &mid, 1, vDSP_Length(n))
        vDSP_vsub(song.right, 1, song.left, 1, &side, 1, vDSP_Length(n))
        vDSP_vsmul(side, 1, &half, &side, 1, vDSP_Length(n))
        var peak: Float = 0
        vDSP_maxmgv(song.left, 1, &peak, vDSP_Length(n))
        var peakR: Float = 0
        vDSP_maxmgv(song.right, 1, &peakR, vDSP_Length(n))
        let lr = dot(song.left, song.right) / (power(song.left) * power(song.right)).squareRoot()
        print(String(format: "[addup] %@: %.1f s at %.0f Hz, peak L %.3f R %.3f, L/R correlation %.3f, side/mid power %.3f",
                     (path as NSString).lastPathComponent, song.duration, song.sampleRate, peak, peakR, lr, power(side) / max(1e-9, power(mid))))

        let url = try await DemucsSeparator.locateModel(in: Bundle(for: Self.self), packageFallback: PredictionGateTests.package)
        let units: MLComputeUnits = env["BL_ADDUP_CPU"] != nil ? .cpuOnly : .cpuAndGPU
        let parts = try DemucsSeparator(modelURL: url, computeUnits: units).separate(song)
        let songPower = power(song.left) + power(song.right)
        for (name, p) in zip(DemucsSeparator.sources, parts) {
            let pw = (power(p.left) + power(p.right)) / songPower
            let c = (dot(p.left, song.left) + dot(p.right, song.right)) / ((power(p.left) + power(p.right)) * songPower).squareRoot()
            print(String(format: "[addup] %@ power %.3f of the song, correlation with the song %.3f", name, pw, c))
        }
        let all = DemucsSeparator.reconstruction(of: parts, song: song)
        print(String(format: "[addup] all six: power %.3f correlation %.3f", all.power, all.correlation))
        // The song's offset from zero (its mean, which the split adds back to every part) and each part's.
        func mean(_ x: [Float]) -> Float { var m: Float = 0; vDSP_meanv(x, 1, &m, vDSP_Length(x.count)); return m }
        var std: Float = 0, m: Float = 0
        vDSP_normalize(mid, 1, nil, 1, &m, &std, vDSP_Length(n))
        print(String(format: "[addup] song mean %.5f, spread %.5f; parts' means: %@", m, std,
                     parts.map { String(format: "%.5f", (mean($0.left) + mean($0.right)) / 2) }.joined(separator: " ")))
        // The same parts with the song's offset added once in all instead of once to each part.
        let once = parts.map { p -> StereoAudio in
            var l = p.left, r = p.right
            var shift = -m * Float(DemucsSeparator.sources.count - 1) / Float(DemucsSeparator.sources.count)
            vDSP_vsadd(l, 1, &shift, &l, 1, vDSP_Length(n)); vDSP_vsadd(r, 1, &shift, &r, 1, vDSP_Length(n))
            return StereoAudio(left: l, right: r, sampleRate: p.sampleRate)
        }
        let fixed = DemucsSeparator.reconstruction(of: once, song: song)
        print(String(format: "[addup] with the offset added once: power %.4f correlation %.4f", fixed.power, fixed.correlation))
        for (i, name) in DemucsSeparator.sources.enumerated() {
            var rest = parts; rest.remove(at: i)
            let r = DemucsSeparator.reconstruction(of: rest, song: song)
            print(String(format: "[addup] without %@: power %.3f correlation %.3f", name, r.power, r.correlation))
        }
        // Over time: the add-up figures per 10 s.
        let step = 441_000
        var line = "[addup] per 10 s power:"
        for start in stride(from: 0, to: n, by: step) {
            let len = min(step, n - start)
            func cut(_ a: StereoAudio) -> StereoAudio {
                StereoAudio(left: Array(a.left[start..<start + len]), right: Array(a.right[start..<start + len]), sampleRate: a.sampleRate)
            }
            let r = DemucsSeparator.reconstruction(of: parts.map(cut), song: cut(song))
            line += String(format: " %.2f/%.2f", r.power, r.correlation)
        }
        print(line)
    }
}
