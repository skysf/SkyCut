#if DEBUG
import AVFoundation
import Darwin
import Synchronization

// Captures the host and timeline times of real PCM submitted by a source node.
// One realtime writer publishes immutable entries to the main-actor reader.
final class PlaybackStartAudioProbe {
    struct Block {
        let host: Double
        let renderedAt: Double
        let timeline: Double
        let duration: Double

        var onset: Double { max(renderedAt, host) }
    }

    final class Attempt: @unchecked Sendable {
        private static let capacity = 2_048
        private let request: Double
        private let earliest: Double
        private let entries = UnsafeMutablePointer<Block>.allocate(capacity: Attempt.capacity)
        private let count = Atomic<Int>(0)

        init(request: Double, earliest: Double) {
            self.request = request
            self.earliest = earliest
        }

        deinit {
            entries.deinitialize(count: count.load(ordering: .acquiring))
            entries.deallocate()
        }

        func record(position: Int64, host: UInt64, frames: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
            let index = count.load(ordering: .relaxed)
            guard index < Self.capacity, host != 0 else { return }
            let rate = TimelineAudioEngine.sampleRate
            let time = AVAudioTime.seconds(forHostTime: host)
            guard time >= request, Double(position + Int64(frames)) / rate > earliest else { return }
            for offset in 0..<frames where abs(left[offset]) > 0.001 || abs(right[offset]) > 0.001 {
                let timeline = Double(position + Int64(offset)) / rate
                guard timeline >= earliest else { continue }
                entries.advanced(by: index).initialize(to: Block(
                    host: time + Double(offset) / rate,
                    renderedAt: AVAudioTime.seconds(forHostTime: mach_absolute_time()),
                    timeline: timeline,
                    duration: Double(frames - offset) / rate
                ))
                count.store(index + 1, ordering: .releasing)
                return
            }
        }

        var first: Block? {
            count.load(ordering: .acquiring) > 0 ? entries[0] : nil
        }

        func timeline(at host: Double, extrapolateFirst: Bool = false) -> Double? {
            let total = count.load(ordering: .acquiring)
            if extrapolateFirst, total > 0, host < entries[0].host {
                return entries[0].timeline + host - entries[0].host
            }
            for index in 0..<total {
                let block = entries[index]
                if host < block.host { return nil }
                if host < block.host + block.duration { return block.timeline + host - block.host }
            }
            return nil
        }
    }

    private let attempts = AudioPublished<Attempt>()

    func begin(request: Double, origin: Double) -> Attempt {
        let attempt = Attempt(request: request, earliest: origin)
        attempts.publish(attempt)
        return attempt
    }

    var observer: TimelineAudioEngine.SampleObserver {
        let attempts = self.attempts
        return { position, host, frames, left, right in
            attempts.load()?.record(position: position, host: host, frames: frames, left: left, right: right)
        }
    }
}
#endif
