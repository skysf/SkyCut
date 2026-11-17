import Darwin
import Foundation
import SrtFlowWebMotionKit

// MARK: - The numbers behind "kill the render when the Mac runs short"
//
// Owns: reading the Mac's memory pressure (`kern.memorystatus_vm_pressure_level`) and a render's footprint (the helper
// plus the WebKit processes it reported, `proc_pid_rusage` physical footprint: what Activity Monitor calls Memory).
// The decision is `WebMotionMemoryPolicy` (pure, in the kit); killing is `WebMotionHelperProcess`.
// The pressure reading is injectable: checks drive the kill with a fake "critical" instead of squeezing a shared Mac
// (`memory_pressure -S` would push every app on the machine into purging). docs/architecture/web-motion-renderer.md「内存」.

struct WebMotionMemoryWatch: Sendable {
    var policy: WebMotionMemoryPolicy
    var pressure: @Sendable () -> WebMotionMemoryPressure

    static var standard: WebMotionMemoryWatch {
        WebMotionMemoryWatch(policy: .standard(physicalMemory: ProcessInfo.processInfo.physicalMemory),
                             pressure: systemPressure)
    }

    /// The kernel's level: 1 normal, 2 warning, 4 critical. Unreadable counts as normal (the budget still applies).
    @Sendable static func systemPressure() -> WebMotionMemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        if level >= 4 { return .critical }
        return level >= 2 ? .warning : .normal
    }

    /// The summed physical footprint of processes still running (ended ones count 0).
    static func footprint(of pids: [Int32]) -> UInt64 {
        pids.reduce(0) { sum, pid in
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return status == 0 ? sum + info.ri_phys_footprint : sum
        }
    }
}
