import AVFoundation

// MARK: - The native player's callbacks that PlayerClock listens to
//
// What it does: registers the periodic time observer, the rate observation and one item notification on an AVPlayer,
// delivers them on the main thread, and removes them when released (with its PlayerClock). Split out of
// VideoPreviewView.swift on 2026-11-20 to keep that file under 600 lines.
// What it does not do: decide what a tick, a rate change or the notification means (PlayerClock).
final class PlayerClockObservers {
    private let player: AVPlayer
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var itemObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - tick: the item time, every `interval` of playback and when playback starts, stops or jumps.
    ///   - playing: whether the rate is above zero, on every rate change (also when the player stops by itself).
    ///   - item: `notification` was posted for this item (any item: the caller checks it is the current one).
    init(player: AVPlayer, interval: TimeInterval, tick: @escaping (CMTime) -> Void, playing: @escaping (Bool) -> Void,
         item notification: Notification.Name, posted: @escaping (AVPlayerItem) -> Void) {
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: .main, using: tick
        )
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { player, _ in
            let isPlaying = player.rate > 0
            if Thread.isMainThread {
                playing(isPlaying)
            } else {
                DispatchQueue.main.async { playing(isPlaying) }
            }
        }
        itemObserver = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { note in
            if let item = note.object as? AVPlayerItem { posted(item) }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        rateObservation?.invalidate()
        if let itemObserver { NotificationCenter.default.removeObserver(itemObserver) }
    }
}
