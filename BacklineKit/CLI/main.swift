import Accelerate
import CoreML
import AVFoundation
import BacklineKit
import Foundation

// backline-cli separate <input> <outdir> [--model path/to/HTDemucs6s.mlpackage]
// backline-cli analyze <stemdir>        (stems written by `separate`)
func writeWav(_ a: StereoAudio, to url: URL) throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: a.sampleRate, channels: 2, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(a.frameCount))!
    buf.frameLength = AVAudioFrameCount(a.frameCount)
    a.left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: a.frameCount) }
    a.right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: a.frameCount) }
    try file.write(from: buf)
}

let args = CommandLine.arguments
// backline-cli split <guitar.wav> <outdir>   (stereo lead/rhythm split)
// backline-cli lead-ml <input.wav> <outdir> --model <LeadRhythmHTDemucs.mlpackage>
if args.count >= 4, args[1] == "lead-ml" {
    let sem1 = DispatchSemaphore(value: 0)
    Task {
        do {
            let x = try AudioDecoder.decode(URL(fileURLWithPath: args[2]))
            guard let i = args.firstIndex(of: "--model"), i + 1 < args.count else { print("need --model"); exit(2) }
            let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: args[i + 1]))
            let sep = try LeadSeparator(modelURL: compiled)
            let t0 = Date()
            let lead = try sep.lead(of: x)
            print(String(format: "lead-ml %.2fs for %.1fs of audio", Date().timeIntervalSince(t0), x.duration))
            let out = URL(fileURLWithPath: args[3])
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try writeWav(lead, to: out.appendingPathComponent("lead.wav"))
        } catch { print("error:", error); exit(1) }
        sem1.signal()
    }
    sem1.wait()
    exit(0)
}
// backline-cli backing <stemdir> <out.wav> [--rate r] [--pitch st]
//   Full app pipeline on separated stems: guitar+other stereo split, lead removed, export through the engine.
if args.count >= 4, args[1] == "backing" {
    let dir = URL(fileURLWithPath: args[2])
    func load(_ n: String) throws -> StereoAudio { try AudioDecoder.decode(dir.appendingPathComponent("\(n).wav")) }
    let g = try load("guitar"), o = try load("other")
    var src = g
    vDSP_vadd(src.left, 1, o.left, 1, &src.left, 1, vDSP_Length(src.frameCount))
    vDSP_vadd(src.right, 1, o.right, 1, &src.right, 1, vDSP_Length(src.frameCount))
    let r = GuitarSplitter.split(src)
    // rhythm + other' = (g + o) − lead
    var rest = src
    vDSP_vsub(r.lead.left, 1, src.left, 1, &rest.left, 1, vDSP_Length(src.frameCount))
    vDSP_vsub(r.lead.right, 1, src.right, 1, &rest.right, 1, vDSP_Length(src.frameCount))
    let stems = [rest, try load("bass"), try load("drums"), try load("vocals"), try load("piano")]
    let e = PlaybackEngine(drivesOutput: false)
    e.load(stems: stems, pitchLocked: [false, false, true, false, false])
    func opt(_ k: String) -> Double? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } }
    var L = [Float](), R = [Float]()
    e.export(.init(gains: [1, 1, 1, 1, 1], rate: opt("--rate") ?? 1, semitones: opt("--pitch") ?? 0)) { l, rr, n in
        L.append(contentsOf: UnsafeBufferPointer(start: l, count: n)); R.append(contentsOf: UnsafeBufferPointer(start: rr, count: n)); return true
    }
    try writeWav(StereoAudio(left: L, right: R, sampleRate: 44_100), to: URL(fileURLWithPath: args[3]))
    print("backing written, split width \(r.width)")
    exit(0)
}
// backline-cli split-go <stemdir> <outdir>  (app pipeline: split guitar+other, lead taken from both)
if args.count >= 4, args[1] == "split-go" {
    let dir = URL(fileURLWithPath: args[2])
    let g = try AudioDecoder.decode(dir.appendingPathComponent("guitar.wav"))
    let o = try AudioDecoder.decode(dir.appendingPathComponent("other.wav"))
    var src = g
    vDSP_vadd(src.left, 1, o.left, 1, &src.left, 1, vDSP_Length(src.frameCount))
    vDSP_vadd(src.right, 1, o.right, 1, &src.right, 1, vDSP_Length(src.frameCount))
    let r = GuitarSplitter.split(src)
    print(String(format: "split-go confidence %.2f width %.2f shouldSplit %@", r.confidence, r.width, r.shouldSplit ? "yes" : "no"))
    let out = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try writeWav(r.lead, to: out.appendingPathComponent("lead.wav"))
    exit(0)
}
if args.count >= 4, args[1] == "split" {
    let g = try AudioDecoder.decode(URL(fileURLWithPath: args[2]))
    let t0 = Date()
    let r = GuitarSplitter.split(g)
    print(String(format: "split %.2fs  confidence %.2f (width %.2f, lead dynamics %.2f)  shouldSplit %@",
                 Date().timeIntervalSince(t0), r.confidence, r.width, r.leadDynamics, r.shouldSplit ? "yes" : "no"))
    let out = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try writeWav(r.lead, to: out.appendingPathComponent("lead.wav"))
    try writeWav(r.rhythm, to: out.appendingPathComponent("rhythm.wav"))
    exit(0)
}
if args.count >= 3, args[1] == "analyze" {
  let sem0 = DispatchSemaphore(value: 0)
  Task {
   do {
    let dir = URL(fileURLWithPath: args[2])
    var stems: [String: StereoAudio] = [:]
    for name in DemucsSeparator.sources {
        stems[name] = try AudioDecoder.decode(dir.appendingPathComponent("\(name).wav"))
    }
    let dur = stems.values.first!.duration
    let t0 = Date()
    // Beat This! on the original mix if given (--mix), else on the sum of stems.
    var grid: BeatTracker.Result?
    if !args.contains("--dsp") {
        let pkg = URL(fileURLWithPath: "../Backline/Resources/BeatThisSmall.mlpackage")
        let alt = URL(fileURLWithPath: "Backline/Resources/BeatThisSmall.mlpackage")
        let modelURL = try await BeatTracker.locateModel(packageFallback: FileManager.default.fileExists(atPath: pkg.path) ? pkg : alt)
        let tracker = try BeatTracker(modelURL: modelURL)
        var mixAudio: StereoAudio
        if let i = args.firstIndex(of: "--mix"), i + 1 < args.count {
            mixAudio = try AudioDecoder.decode(URL(fileURLWithPath: args[i + 1]))
        } else {
            var l = [Float](repeating: 0, count: stems.values.first!.frameCount), r = l
            for s in stems.values { vDSP_vadd(l, 1, s.left, 1, &l, 1, vDSP_Length(l.count)); vDSP_vadd(r, 1, s.right, 1, &r, 1, vDSP_Length(r.count)) }
            mixAudio = StereoAudio(left: l, right: r, sampleRate: 44_100)
        }
        grid = try tracker.track(mixAudio)
        if let g = grid { print(String(format: "beatthis bpm %.1f regularity %.2f", g.bpm, g.regularity)) }
    }
    let a = Analyzer.analyze(stems: stems, duration: dur, beatGrid: grid)
    print(String(format: "analysis %.2fs", Date().timeIntervalSince(t0)))
    print(String(format: "bpm %.1f  beats %d  bars %d  key %@  tuning %+.0f c", a.bpm, a.beats.count, a.downbeats.count, a.key ?? "-", a.tuningCents ?? 0))
    print("first beats", a.beats.prefix(6).map { String(format: "%.2f", $0) })
    for s in a.sections { print(String(format: "  %-10@ %6.1f – %6.1f", s.label, s.start, s.end)) }
   } catch { print("error:", error); exit(1) }
   sem0.signal()
  }
  sem0.wait()
  exit(0)
}
guard args.count >= 4, args[1] == "separate" else {
    print("usage: backline-cli separate <input> <outdir> [--model <mlpackage>]")
    exit(2)
}
let input = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
var modelPkg = URL(fileURLWithPath: "../Backline/Resources/HTDemucs6s.mlpackage")
if let i = args.firstIndex(of: "--model"), i + 1 < args.count { modelPkg = URL(fileURLWithPath: args[i + 1]) }


let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let t0 = Date()
        let audio = try AudioDecoder.decode(input)
        let t1 = Date()
        print(String(format: "decode   %.2fs  (%.1fs of audio)", t1.timeIntervalSince(t0), audio.duration))
        let modelURL = try await DemucsSeparator.locateModel(packageFallback: modelPkg)
        let sep = try DemucsSeparator(modelURL: modelURL)
        let t2 = Date()
        print(String(format: "load     %.2fs", t2.timeIntervalSince(t1)))
        let stems = try sep.separate(audio) { p in
            print(String(format: "\r  chunk %d/%d  eta %.1fs", p.chunk, p.chunks, p.secondsRemaining ?? 0), terminator: "")
            fflush(stdout)
        }
        let t3 = Date()
        print(String(format: "\nseparate %.2fs  (%.1fx realtime)", t3.timeIntervalSince(t2), audio.duration / t3.timeIntervalSince(t2)))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for (name, s) in zip(DemucsSeparator.sources, stems) {
            try writeWav(s, to: outDir.appendingPathComponent("\(name).wav"))
        }
        print("wrote", outDir.path)
    } catch {
        print("error:", error)
        exit(1)
    }
    sem.signal()
}
sem.wait()
