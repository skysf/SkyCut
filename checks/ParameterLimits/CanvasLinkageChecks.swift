import CoreGraphics
import Foundation
@testable import SrtFlow

// The real perform path must follow V1 before an automatic canvas change rewrites overlay geometry.
// These model fixtures never decode or render their synthetic portrait metadata.
@MainActor enum CanvasLinkageChecks {
    static func run(_ f: ParameterFixture, require: (Bool, String) -> Void) {
        let wasEnabled = f.project.linkageEnabled
        defer {
            f.project.linkageEnabled = wasEnabled
            f.reset()
        }
        for magnet in [false, true] {
            var state = f.before
            state.canvasRatio = .auto
            state.mainMagnet = magnet
            let first = state.mainClips[0]
            var phone = EditClip(sourceURL: first.sourceURL, sourceDuration: 1, timelineStart: 1, info: first.info)
            phone.info?.displaySize = CGSize(width: 90, height: 160)
            state.mainClips.append(phone)
            let title = TextOverlay(text: "Follow the phone", timelineStart: 1.25, duration: 0.5)
            let gone = TextOverlay(text: "Deleted host", timelineStart: 0.25, duration: 0.5)
            let shape = ShapeAnnotation(kind: .rectangle, timelineStart: 1.25, duration: 0.5, width: 0.3, height: 0.2)
            var overlay = EditClip(sourceURL: first.sourceURL, sourceDuration: 0.5, timelineStart: 1.25, info: first.info)
            overlay.placement = ClipPlacement(centerX: 0.7, centerY: 0.3, width: 0.3, height: 0.3)
            state.textOverlays = [title, gone]
            state.shapes = [shape]
            state.overlayTracks = [EditLane(clips: [overlay])]
            state.assignMissingTrackColors()

            for enabled in [true, false] {
                f.reset(state)
                f.project.linkageEnabled = enabled
                let before = f.project.state
                let report = f.project.perform(rebuildsPreview: false, deletesContent: true) { next in
                    next.remove(first.id)
                    if !magnet { next.update(phone.id) { $0.timelineStart = 0 } }
                }
                let after = f.project.state
                let text = after.textOverlays.first { $0.id == title.id }
                let box = after.shapes.first { $0.id == shape.id }
                let picture = after.clip(with: overlay.id)
                let expectedStart = enabled ? 0.25 : 1.25
                require(text?.timelineStart == expectedStart && box?.timelineStart == expectedStart
                        && picture?.timelineStart == expectedStart, "auto canvas: text, shape and framed V2 follow V1 only with linkage on")
                require(after.textOverlays.contains { $0.id == gone.id } == !enabled,
                        "auto canvas: the deleted host's title follows the linkage switch")
                require(report.moved == (enabled ? 3 : 0) && report.deleted == (enabled ? 1 : 0),
                        "auto canvas: the linkage report describes all moved and deleted overlays")
                let oldCanvas = TimelineRenderSize.size(for: before)
                let newCanvas = TimelineRenderSize.size(for: after)
                let oldPixels = title.style.fontSize * TextOverlay.pixelScale(canvas: oldCanvas) / min(oldCanvas.width, oldCanvas.height)
                let newPixels = (text?.style.fontSize ?? 0) * TextOverlay.pixelScale(canvas: newCanvas) / min(newCanvas.width, newCanvas.height)
                require(abs(oldPixels - newPixels) < 1e-6, "auto canvas: a linked title still keeps its size against the short side")
                let expectedBox = OverlayReframe.scaled(shape, by: .init(from: oldCanvas, to: newCanvas))
                require(box?.width == expectedBox.width && box?.height == expectedBox.height,
                        "auto canvas: a linked shape still keeps its proportions")
                let expectedPicture = CanvasReframe.reframed(overlay, from: oldCanvas, to: newCanvas)
                require(picture?.placement == expectedPicture?.placement, "auto canvas: linked V2 still keeps its framing")
                f.project.effectiveUndoManager!.undo()
                require(f.project.state == before && !f.project.effectiveUndoManager!.canUndo,
                        "auto canvas: one undo restores the host, linked objects and all geometry")
                f.project.effectiveUndoManager!.redo()
                require(f.project.state == after, "auto canvas: one redo restores linkage and reframing together")
            }
        }
    }
}
