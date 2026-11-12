import Foundation
import MetricKit

/// D20 (f): the system's own reports of Backline crashing, hanging, or being stopped for memory, written to the
/// app's log (`AppLog`) when the system delivers them (at a launch after the event, or once a day). Ported from
/// iOS as it is: MetricKit offers the same reports on macOS 12 and later. Only what the report
/// says about the app's code (the exception, the signal, where in the binary, how long a hang lasted) and the
/// counts of how earlier runs ended; nothing about songs or the person. Nothing is sent anywhere: MetricKit hands
/// the reports to the app, and the app keeps them in its own log on the Mac.
final class SystemDiagnostics: NSObject, MXMetricManagerSubscriber {
    private static let shared = SystemDiagnostics()
    /// The longest call stack text kept per report (the log holds about 512 KB in all).
    nonisolated static let stackLimit = 6_000

    /// Starts listening (at launch); reports that arrived while the app was closed come soon after.
    static func start() {
        MXMetricManager.shared.add(shared)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for line in Self.lines(for: payload) { AppLog.note(line) }
        }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let front = exits.foregroundExitData, back = exits.backgroundExitData
            AppLog.note("system: how runs ended (\(Self.span(payload.timeStampBegin, payload.timeStampEnd))): in front "
                        + "\(front.cumulativeNormalAppExitCount) normal, \(front.cumulativeMemoryResourceLimitExitCount) memory limit, "
                        + "\(front.cumulativeBadAccessExitCount) bad access, \(front.cumulativeAbnormalExitCount) abnormal, "
                        + "\(front.cumulativeAppWatchdogExitCount) watchdog; away \(back.cumulativeMemoryPressureExitCount) memory pressure, "
                        + "\(back.cumulativeMemoryResourceLimitExitCount) memory limit, \(back.cumulativeSuspendedWithLockedFileExitCount) locked file")
        }
    }

    /// The log lines for one diagnostic payload: one per crash, hang, CPU or disk report, then its call stack.
    nonisolated static func lines(for payload: MXDiagnosticPayload) -> [String] {
        var out: [String] = []
        let when = span(payload.timeStampBegin, payload.timeStampEnd)
        for c in payload.crashDiagnostics ?? [] {
            var what = "system: crash \(when), build \(c.metaData.applicationBuildVersion)"
            if let t = c.exceptionType { what += ", exception \(t)" }
            if let code = c.exceptionCode { what += " code \(code)" }
            if let s = c.signal { what += ", signal \(s)" }
            if let r = c.terminationReason { what += ", \(r)" }
            if let v = c.virtualMemoryRegionInfo { what += ", \(v.replacingOccurrences(of: "\n", with: " "))" }
            out.append(what)
            out.append(stack(c.callStackTree))
        }
        for h in payload.hangDiagnostics ?? [] {
            out.append("system: hang \(when), build \(h.metaData.applicationBuildVersion), \(seconds(h.hangDuration)) s")
            out.append(stack(h.callStackTree))
        }
        for c in payload.cpuExceptionDiagnostics ?? [] {
            out.append("system: CPU use \(when), \(seconds(c.totalCPUTime)) s of CPU in \(seconds(c.totalSampledTime)) s")
            out.append(stack(c.callStackTree))
        }
        for d in payload.diskWriteExceptionDiagnostics ?? [] {
            out.append("system: disk writes \(when), \(Int(d.totalWritesCaused.converted(to: .megabytes).value)) MB")
        }
        return out
    }

    /// A call stack as the system wrote it (binary names and offsets), on one line and cut to `stackLimit`.
    nonisolated static func stack(_ tree: MXCallStackTree) -> String {
        let json = String(decoding: tree.jsonRepresentation(), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
        return "system: stack " + (json.count > stackLimit ? String(json.prefix(stackLimit)) + " (cut)" : json)
    }

    nonisolated static func seconds(_ m: Measurement<UnitDuration>) -> String {
        String(format: "%.1f", m.converted(to: .seconds).value)
    }

    nonisolated static func span(_ a: Date, _ b: Date) -> String {
        let f = ISO8601DateFormatter()
        return a == b ? f.string(from: a) : "\(f.string(from: a)) to \(f.string(from: b))"
    }
}
