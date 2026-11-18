import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// Turned pictures that fill the frame keep it covered while rise and pop play — in the preview and in the export alike. 2026-11-18:
// a clip turned 5° at scale 1.2 rose in with its top corners bare (the old test counted every turned clip as not filling, so it got
// the picture-in-picture rise with no growth). The export prerenders animated clips with the preview's builder (V1 on black, V2 as
// fill + matte), so both pipelines are measured at the frame's four corners against its centre, and against each other.
// Case: docs/bugfixes/2026-11-18-turned-clip-entrance-bares-edges.md. The geometry at every frame: checks/PreviewComposition/EntranceCover.swift.
// Built by scripts/check-clip-animation.sh.

func checkTurnedEntrances(white: URL, black: URL, meta: MediaInfo, canvas: CGSize) async {
    // V1: turned 5° at 1.2 (fills the frame at rest), rise in.
    var rise = EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: meta)
    rise.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.2, height: 1.2)
    rise.rotationDegrees = 5
    rise.presetAnimation = ClipPresetAnimation(entrance: .rise, intensity: 1)
    rise.videoFadeInDuration = 2
    var onMain = TimelineState()
    onMain.mainClips = [rise]
    await reconcileCorners(onMain, name: "turned-rise", canvas: canvas, times: [0.3, 0.5, 1.0])

    // V2 over a black V1: turned −5° at 1.2, pop in (the full-frame pop comes down from big; the old one sprang up from small).
    var pop = rise
    pop.rotationDegrees = -5
    pop.presetAnimation = ClipPresetAnimation(entrance: .pop, intensity: 1)
    var onTop = TimelineState()
    onTop.mainClips = [EditClip(sourceURL: black, sourceDuration: 4, timelineStart: 0, info: meta)]
    onTop.overlayTracks = [EditLane(clips: [pop])]
    await reconcileCorners(onTop, name: "turned-pop-overlay", canvas: canvas, times: [0.3, 0.5, 1.3])
}

/// At each time: every corner of the frame is as bright as its centre (nothing bare) in the preview and in the export, and the two
/// pipelines agree on each corner.
private func reconcileCorners(_ state: TimelineState, name: String, canvas: CGSize, times: [Double]) async {
    guard let built = await VideoEditCompositionBuilder.build(from: state) else {
        return check(false, "\(name): the preview composition builds")
    }
    guard let product = await exportProduct(state, name: name) else { return }
    let centre = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    let corners = [
        ("top left", CGRect(x: 0, y: 0, width: 0.12, height: 0.12)), ("top right", CGRect(x: 0.88, y: 0, width: 0.12, height: 0.12)),
        ("bottom left", CGRect(x: 0, y: 0.88, width: 0.12, height: 0.12)),
        ("bottom right", CGRect(x: 0.88, y: 0.88, width: 0.12, height: 0.12))
    ]
    for time in times {
        let previewCentre = await previewProbe(built, at: time, region: centre)
        let exportCentre = exportProbe(product.url, at: time, region: centre, canvas: canvas, name: name)
        check(previewCentre > 0.2 && exportCentre > 0.2, "\(name) \(time) s: the picture shows (centre \(previewCentre) / \(exportCentre))")
        for (label, region) in corners {
            let preview = await previewProbe(built, at: time, region: region)
            let export = exportProbe(product.url, at: time, region: region, canvas: canvas, name: name)
            check(abs(preview - previewCentre) < 0.08,
                  "\(name) \(time) s: the preview's \(label) corner is not bare (\(preview) vs centre \(previewCentre))")
            check(abs(export - exportCentre) < 0.08,
                  "\(name) \(time) s: the export's \(label) corner is not bare (\(export) vs centre \(exportCentre))")
            check(abs(preview - export) < pipelineTolerance, "\(name) \(time) s: \(label) corner, preview \(preview) / export \(export)")
        }
    }
}
