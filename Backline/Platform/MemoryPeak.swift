import Darwin
import Foundation
import Synchronization

/// How much memory the app is holding, as iOS counts it (plan B03). The install and the Core ML work after
/// it reached 1.72 GB on an 8 GB iPhone; on a 3 or 4 GB phone the margin is unknown, so each long pass
/// writes its peak to the app log and a device run shows what is left.
nonisolated enum MemoryFootprint {
    /// The task's physical footprint in bytes, or 0 if the kernel wouldn't say.
    static var bytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static var megabytes: Int { Int(bytes / 1_048_576) }
}

/// The highest footprint a pass reached. The passes sample it from the progress and cancellation checks
/// they already run every chunk, so nothing is polled and nothing extra is woken up.
nonisolated final class MemoryPeak: Sendable {
    private let highest = Mutex<UInt64>(0)

    init() { sample() }

    func sample() {
        let now = MemoryFootprint.bytes
        highest.withLock { $0 = max($0, now) }
    }

    var megabytes: Int { Int(highest.withLock { $0 } / 1_048_576) }
    /// "peak 1403 MB", for the app log.
    var note: String { "peak \(megabytes) MB" }
}
