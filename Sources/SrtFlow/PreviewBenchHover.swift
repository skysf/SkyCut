import AVFoundation
import Darwin

// The preview perf ratchet's hover phase (docs/architecture/preview-perf-ratchet.md section 15). The pointer sweeps the
// timeline through the timeline's own hover entry (`PlayerClock.peek`). Each stop waits for its frame on the hover
// preview's own player, then the pointer leaves. Its memory is a gated item of its own (`<scenario>.hover.peakMB`): the
// hover player costs memory while hovering, which the user approved on 2026-11-20 (about 50 MB). The scenario's
// `memory.peakMB` is read before this phase, so it measures what it always did.
@MainActor
enum PreviewBenchHover {
    struct Memory {
        /// The footprint just before the first hover (MB).
        var before = 0.0
        /// The highest footprint while hovering (MB).
        var peak = 0.0
    }

    /// Hover stops, evenly spaced inside the timeline.
    static let stops = 8

    static func sweep(_ project: VideoEditProject) async throws -> Memory {
        let clock = project.clock
        var memory = Memory(before: footprintMB())
        memory.peak = memory.before
        for index in 1...stops {
            let time = project.duration * Double(index) / Double(stops + 1)
            clock.peek(at: time)
            let deadline = Date().addingTimeInterval(15)
            while !(clock.hover.isShowing && abs((clock.hover.shownTime ?? -1) - time) < 0.001) {
                memory.peak = max(memory.peak, footprintMB())
                guard Date() < deadline else {
                    throw PreviewBench.Failure(String(format: "The hover frame at %.2f s did not appear within 15 s", time))
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            memory.peak = max(memory.peak, footprintMB())
        }
        clock.endPeek()
        return memory
    }

    /// The process's footprint now (Activity Monitor's Memory column), in MB to one decimal.
    static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return -1 }
        return (Double(info.ri_phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}
