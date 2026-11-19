#if DEBUG
import AppKit
import AVFoundation
import QuartzCore

// Observes the production item's decoded frames at the playback layer's display opportunities.
// The item continues to feed AVPlayerLayer while this second consumer reads frame timestamps.
@MainActor
final class PlaybackStartVideoProbe: NSObject {
    struct Frame {
        let host: Double
        let timeline: Double
    }

    private let output = AVPlayerItemVideoOutput(outputSettings: nil)
    private weak var item: AVPlayerItem?
    private var link: CADisplayLink?
    weak var surface: PlayerLayerView?
    private(set) var firstDisplayed: Frame?
    private(set) var displayed: Frame?
    private(set) var playingFrames: [Frame] = []

    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        item?.remove(output)
    }

    func attach(to item: AVPlayerItem) {
        self.item?.remove(output)
        firstDisplayed = nil
        displayed = nil
        item.add(output)
        self.item = item
    }

    func resetPlayingFrames() { playingFrames.removeAll(keepingCapacity: true) }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard let surface, surface.window?.isVisible == true, let player = surface.player,
              let item, player.currentItem === item, surface.playerLayer.isReadyForDisplay else { return }
        let host = link.targetTimestamp
        let time = output.itemTime(forHostTime: host)
        guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time) else { return }
        var presentation = CMTime.invalid
        guard output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentation) != nil,
              presentation.isNumeric else { return }
        let frame = Frame(host: host, timeline: presentation.seconds)
        if firstDisplayed == nil { firstDisplayed = frame }
        displayed = frame
        if player.timeControlStatus == .playing, playingFrames.count < 300 {
            if (playingFrames.last?.timeline ?? -.infinity) < frame.timeline {
                playingFrames.append(frame)
            }
        }
    }
}
#endif
