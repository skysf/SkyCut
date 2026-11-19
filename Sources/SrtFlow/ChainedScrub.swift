import AVFoundation

// MARK: - Exact seeks while scrubbing and hovering (Apple QA1820)
//
// What it does: while one zero-tolerance seek is in flight only the newest target is kept, and it is sent when the
// seek completes. Sending a seek per mouse move floods the decoder: seeks in flight keep being cancelled and the
// picture refreshes unevenly. Never a coarse keyframe seek: a composition's keyframes are seconds apart and the
// picture would stand still while dragging (docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md).
// Split out of VideoPreviewView.swift on 2026-11-19. Main thread only.
// What it does not do: placing the playhead or preparing playback (PlayerClock).
final class ChainedScrub {
    private var isSeeking = false
    private var pending: TimeInterval?

    /// Forgets a target that has not been sent yet.
    func cancelPending() { pending = nil }

    /// `idle` runs once the last seek completes with no newer target waiting.
    func scrub(_ player: AVPlayer, to seconds: TimeInterval, idle: @escaping () -> Void) {
        guard !isSeeking else {
            pending = seconds
            return
        }
        isSeeking = true
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSeeking = false
                if let next = self.pending, let player {
                    self.pending = nil
                    self.scrub(player, to: next, idle: idle)
                } else {
                    idle()
                }
            }
        }
    }
}
