import Darwin
import Foundation

// MARK: - The render's WebKit processes end with it
//
// Owns: pinning a process by (pid, start time, name) and, after the helper ended, waiting until the WebKit processes it
// reported (WebContent, GPU, Networking) are really gone — killing any still running as the same process after a grace
// period. Measured 2026-11-17: they are gone 0.1–0.3 s after the helper, killed or not. A process that is exiting can no
// longer be described (`proc_pidinfo` fails) while its pid still exists: that still counts as not gone yet (the first
// version called it gone and the checks caught WebKit processes still there). Does not own: killing the helper
// (`WebMotionHelperProcess`). docs/architecture/web-motion-renderer.md「内存」.

/// A running process, pinned by its start time so a recycled process id is never mistaken for it.
struct WebMotionProcessIdentity: Sendable, Equatable {
    let pid: Int32
    let startedMicroseconds: UInt64
    let name: String

    static func current(_ pid: Int32) -> WebMotionProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return WebMotionProcessIdentity(pid: pid, startedMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                                        name: name)
    }

    enum State {
        /// No process has this pid.
        case gone
        /// Still this process (or exiting: the pid exists but can no longer be described).
        case here
        /// The pid now belongs to another process.
        case replaced
    }

    var state: State {
        guard kill(pid, 0) == 0 || errno == EPERM else { return .gone }
        guard let now = WebMotionProcessIdentity.current(pid) else { return .here }
        return now == self ? .here : .replaced
    }
}

/// After the helper ended, its WebKit processes must end too. Any still running as the same process after the grace
/// period is killed (only a process that can still be identified as the same one is ever signalled).
enum WebMotionProcessTeardown {
    /// The pids that had to be killed (normally none).
    static func ensureGone(_ processes: [WebMotionProcessIdentity], grace: Double) async -> [Int32] {
        let deadline = ProcessInfo.processInfo.systemUptime + grace
        var waiting = processes.filter { $0.state == .here }
        while !waiting.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waiting = waiting.filter { $0.state == .here }
        }
        let stuck = waiting.filter { WebMotionProcessIdentity.current($0.pid) == $0 }
        for process in stuck { kill(process.pid, SIGKILL) }
        return stuck.map(\.pid)
    }
}
