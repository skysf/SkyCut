import AVFoundation

// MARK: - Waiting until the preview can play
//
// What it does: one pending wait at a time until the native player, its current item and, when asked, the mounted
// preview layer report ready. A newer wait is refused until `clear()`; only the item that is still the player's can
// release it. PlayerClock waits here before priming a paused placement and before a pending Play starts
// (docs/architecture/playback-start.md). Split out of VideoPreviewView.swift on 2026-11-19.
// What it does not do: decide what follows (the caller's `failed` and `ready`).
final class PreviewReadiness {
    private var observations: [NSKeyValueObservation] = []
    private var request: UUID?

    func clear() {
        request = nil
        observations.removeAll()
    }

    func watch(
        _ item: AVPlayerItem, player: AVPlayer, layer: AVPlayerLayer?,
        failed: @escaping () -> Void, ready: @escaping () -> Void
    ) {
        guard request == nil else { return }
        let request = UUID()
        self.request = request
        let check: () -> Void = { [weak self, weak item, weak player, weak layer] in
            DispatchQueue.main.async {
                guard let self, let item, let player, self.request == request, player.currentItem === item else { return }
                if item.status == .failed || player.status == .failed {
                    failed()
                    return
                }
                guard item.status == .readyToPlay, player.status == .readyToPlay,
                      layer?.isReadyForDisplay != false else { return }
                self.clear()
                ready()
            }
        }
        observations = [
            item.observe(\.status, options: [.initial, .new]) { _, _ in check() },
            player.observe(\.status, options: [.initial, .new]) { _, _ in check() },
        ]
        if let layer {
            observations.append(layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, _ in check() })
        }
    }
}
