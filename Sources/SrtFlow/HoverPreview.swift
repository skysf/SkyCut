import AVFoundation
import Combine

// MARK: - The hover preview's own player
//
// What it does: while the pointer hovers the timeline, its frames come from a second AVPlayer with its own item on the
// preview item's composition. The editing player stays placed and primed at the playhead, so Play after a hover starts
// at once. Until 2026-11-20 the hover moved the editing player, and Play waited for the playhead's frame to be decoded
// again: 0.6–0.8 s at 4K mid-GOP in original mode. The user approved the memory this costs while hovering, about 50 MB
// (docs/architecture/preview-perf-ratchet.md section 15, docs/architecture/playback-start.md "Hover").
//
// The hover item is built from the preview's own item: same asset, same video composition. So upper tracks, alpha
// sources and web-motion movies look the same. `HoverPreviewSurface` draws the grade and covers on the hover layers.
// The item lives while the pointer hovers and `releaseDelay` after. A new preview item replaces it on the next hover.
// Main thread only.
// What it does not do: the playhead, sound or playback (PlayerClock); drawing (HoverPreviewSurface).

/// The view that shows the hover picture: hidden until the hover's first frame has landed, hidden again when it ends.
protocol HoverPictureHost: AnyObject {
    func showHoverPicture(_ shown: Bool)
}

final class HoverPreview: ObservableObject {
    /// The hover item is installed: the preview mounts the hover layers, hidden until `isShowing`.
    @Published private(set) var hasItem = false
    /// The pointer's frame is on screen over the editing picture.
    private(set) var isShowing = false {
        didSet { if isShowing != oldValue { host?.showHoverPicture(isShowing) } }
    }
    /// Where the hover's last seek landed: the frame on screen while `isShowing`.
    private(set) var shownTime: TimeInterval?
    /// How long the item outlives a hover: a pointer that comes back soon gets its frames without a new item.
    static let releaseDelay: TimeInterval = 3

    private(set) lazy var player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
        return player
    }()
    private let scrubber = ChainedScrub()
    private let readiness = PreviewReadiness()
    private weak var host: HoverPictureHost?
    private weak var layer: AVPlayerLayer?
    /// The preview item the hover item was built from.
    private weak var source: AVPlayerItem?
    /// The pointer hovers on this player (from `show` to `hide`).
    private(set) var isHovering = false
    private var release: DispatchWorkItem?

    /// Shows the frame at `seconds` of `item`, the preview's current item, on the hover player.
    func show(at seconds: TimeInterval, of item: AVPlayerItem) {
        release?.cancel()
        release = nil
        if source !== item || player.currentItem == nil { install(from: item) }
        // A frame left from an earlier hover stays hidden until this hover's first seek lands.
        isHovering = true
        scrubber.scrub(player, to: seconds, landed: { [weak self] target in self?.landed(at: target) }, idle: {})
    }

    /// The hover ended: the editing picture shows again at once; the item goes `releaseDelay` later. A no-op when no
    /// hover is on (every seek clears `peekTime`): it must not push a scheduled release back.
    func hide() {
        guard isHovering else { return }
        isHovering = false
        isShowing = false
        scrubber.cancelPending()
        readiness.clear()
        scheduleRelease()
    }

    /// The mounted hover view and its player layer (`HoverPreviewSurface`).
    func bind(_ host: HoverPictureHost, layer: AVPlayerLayer) {
        self.host = host
        self.layer = layer
        host.showHoverPicture(isShowing)
    }

    private func install(from item: AVPlayerItem) {
        readiness.clear()
        scrubber.cancelPending()
        isShowing = false
        let hoverItem = AVPlayerItem(asset: item.asset)
        hoverItem.videoComposition = item.videoComposition
        // A seek completes once its frame is composed: the hover shows no frame from before the seek.
        hoverItem.seekingWaitsForVideoCompositionRendering = true
        player.replaceCurrentItem(with: hoverItem)
        source = item
        shownTime = nil
        if !hasItem { hasItem = true }
    }

    private func landed(at seconds: TimeInterval) {
        guard isHovering, let item = player.currentItem else { return }
        shownTime = seconds
        guard !isShowing else { return }
        readiness.watch(item, player: player, layer: layer, failed: { [weak self] in self?.hide() }) { [weak self] in
            guard let self, self.isHovering else { return }
            self.isShowing = true
        }
    }

    private func scheduleRelease() {
        release?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dropItem() }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay, execute: work)
    }

    private func dropItem() {
        guard !isHovering else { return }
        release = nil
        readiness.clear()
        player.replaceCurrentItem(with: nil)
        source = nil
        shownTime = nil
        if hasItem { hasItem = false }
    }
}
