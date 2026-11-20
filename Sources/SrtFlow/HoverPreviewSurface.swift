import AVFoundation
import AppKit
import SwiftUI

// MARK: - The hover picture over the preview
//
// What it does: draws the hover player's frame over the editing picture, with the same grade and covers at the
// hover's time, so a hover looks like the preview would at that frame. It reuses the preview's own pieces: a
// `PlayerLayerView` with `FilterStackAttachment` (grade) and a `CoverHostView` (blur / mosaic) on the hover player.
// The overlays (shapes, texts, subtitles, the transform box) stay sibling views above it, read at the hover's time.
// `HoverPreview` shows and hides it directly (`alphaValue`), never through SwiftUI. The hover picture then stays on
// screen until the editing picture can take over, and it is gone in the same turn as the hover's end.
// Its background is clear: a frame not yet drawn shows the editing picture under it, not black.
// What it does not do: decide what to show (HoverPreview) or the preview's own layers (PreviewPlayerSurface).

/// Mounted while the hover player has an item (`HoverPreview.hasItem`); hidden until its first frame lands.
struct HoverPreviewSurface: NSViewRepresentable {
    let hover: HoverPreview
    /// The grade and covers at the hover's time.
    let grade: FilterStack
    let covers: CoverStack

    func makeCoordinator() -> FilterStackAttachment { FilterStackAttachment() }

    func makeNSView(context: Context) -> HoverPreviewView {
        let view = HoverPreviewView(player: hover.player)
        hover.bind(view, layer: view.picture.playerLayer)
        return view
    }

    func updateNSView(_ view: HoverPreviewView, context: Context) {
        PerfCounters.update(Self.self)
        context.coordinator.apply(grade, to: view.picture)
        view.apply(covers, grade: grade)
    }
}

final class HoverPreviewView: NSView, HoverPictureHost {
    let picture = PlayerLayerView()
    private let player: AVPlayer
    private var covers: CoverHostView?

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
        picture.player = player
        picture.playerLayer.backgroundColor = nil
        addSubview(picture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only looked at: events go to the editor's overlays and timeline as without it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        picture.frame = bounds
        covers?.frame = bounds
    }

    func showHoverPicture(_ shown: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = shown ? 1 : 0
        CATransaction.commit()
    }

    /// The covers at the hover's time over the graded picture, as `CoverPreviewLayer` does over the editing picture.
    /// No cover layer is built while nothing is covered.
    func apply(_ stack: CoverStack, grade: FilterStack) {
        guard !stack.isEmpty else {
            covers?.removeFromSuperview()
            covers = nil
            return
        }
        if covers == nil {
            let host = CoverHostView(player: player)
            host.frame = bounds
            addSubview(host)
            covers = host
        }
        covers?.apply(stack, grade: grade)
    }
}
