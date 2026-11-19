#if DEBUG
import AppKit
import AVFoundation
import CoreVideo
import QuartzCore
import os

// Observes the production item's decoded frames at the playback layer's display opportunities.
// Window work stays on the main actor. Core Video samples on its own display thread.
final class PlaybackStartVideoProbe: @unchecked Sendable {
    struct Frame {
        let host: Double
        let timeline: Double
    }

    private struct Capture {
        var item: AVPlayerItem?
        var player: AVPlayer?
        var surface: UUID?
        var displayReady = false
        var firstDisplayed: Frame?
        var displayed: Frame?
        var playingFrames: [Frame] = []
        var previousDeadline: Double?
        var previousCallback: Double?
        var displayPeriod = Double.infinity
        var longestCallbackGap = 0.0
    }

    private let output = AVPlayerItemVideoOutput(outputSettings: nil)
    private let capture = OSAllocatedUnfairLock(initialState: Capture())
    @MainActor private var link: CVDisplayLink?
    @MainActor private var readiness: NSKeyValueObservation?

    var firstDisplayed: Frame? { capture.withLock { $0.firstDisplayed } }
    var displayed: Frame? { capture.withLock { $0.displayed } }
    var playingFrames: [Frame] { capture.withLock { $0.playingFrames } }
    var cadence: (period: Double, longestGap: Double) {
        capture.withLock { ($0.displayPeriod, $0.longestCallbackGap) }
    }

    @MainActor
    func start(on screen: NSScreen) throws {
        // This debug probe needs Core Video's separate thread so editor work cannot delay sampling.
        var created: CVDisplayLink?
        guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CVDisplayLinkCreateWithCGDisplay(display.uint32Value, &created) == kCVReturnSuccess,
              let link = created,
              CVDisplayLinkSetOutputHandler(link, { [weak self] _, _, target, _, _ in
                  self?.displayTick(hostTime: target.pointee.hostTime)
                  return kCVReturnSuccess
              }) == kCVReturnSuccess,
              CVDisplayLinkStart(link) == kCVReturnSuccess else {
            throw PlaybackStartBench.Failure("Cannot start the editor display's video sampling thread")
        }
        self.link = link
    }

    @MainActor
    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        readiness = nil
        let item = capture.withLock { state in
            let item = state.item
            state = Capture()
            return item
        }
        item?.remove(output)
    }

    @MainActor
    func mount(_ view: PlayerLayerView) {
        let surface = UUID()
        let player = view.player
        capture.withLock {
            $0.player = player
            $0.surface = surface
            $0.displayReady = false
        }
        readiness = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, change in
            self?.capture.withLock {
                guard $0.surface == surface else { return }
                $0.displayReady = change.newValue == true
            }
        }
    }

    @MainActor
    func attach(to item: AVPlayerItem) {
        let previous = capture.withLock { state in
            let previous = state.item
            state.item = nil
            state.firstDisplayed = nil
            state.displayed = nil
            state.playingFrames.removeAll(keepingCapacity: true)
            return previous
        }
        previous?.remove(output)
        item.add(output)
        capture.withLock { $0.item = item }
    }

    func resetPlayingFrames() {
        capture.withLock {
            $0.playingFrames.removeAll(keepingCapacity: true)
            $0.previousDeadline = nil
            $0.previousCallback = nil
            $0.displayPeriod = .infinity
            $0.longestCallbackGap = 0
        }
    }

    private func displayTick(hostTime: UInt64) {
        guard hostTime != 0 else { return }
        let host = AVAudioTime.seconds(forHostTime: hostTime)
        let callback = CACurrentMediaTime()
        let (item, player, displayReady) = capture.withLock { state in
            // The display thread also ticks before the preview can supply a picture.
            if let previous = state.previousDeadline, host > previous {
                state.displayPeriod = min(state.displayPeriod, host - previous)
            }
            if let previous = state.previousCallback {
                state.longestCallbackGap = max(state.longestCallbackGap, callback - previous)
            }
            state.previousDeadline = host
            state.previousCallback = callback
            return (state.item, state.player, state.displayReady)
        }
        guard displayReady, let item, let player, player.currentItem === item else { return }
        let time = output.itemTime(forHostTime: host)
        guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time) else { return }
        var presentation = CMTime.invalid
        guard output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentation) != nil,
              presentation.isNumeric else { return }
        let frame = Frame(host: host, timeline: presentation.seconds)
        let playing = player.timeControlStatus == .playing
        capture.withLock { state in
            guard state.item === item else { return }
            if state.firstDisplayed == nil { state.firstDisplayed = frame }
            state.displayed = frame
            if playing, state.playingFrames.count < 300, (state.playingFrames.last?.timeline ?? -.infinity) < frame.timeline {
                state.playingFrames.append(frame)
            }
        }
    }
}
#endif
