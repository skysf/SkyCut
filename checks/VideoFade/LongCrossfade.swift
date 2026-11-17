import AVFoundation
import CoreGraphics
import Foundation

// MCP-6: a 1.042-second crossFade on two touching 1.5-second shots with real handles is delivered unchanged by both
// production pipelines. This also runs the existing still regressions; it does not change their fixtures or expectations.
enum LongCrossfadeChecks {
    static func run() async {
        await checkStillCrossfade()
        do {
            let canvas = CGSize(width: 128, height: 72)
            let bright = try await makeSolidVideo(white: 1, seconds: 4, name: "long-crossfade-white.mp4", size: canvas)
            let dark = try await makeSolidVideo(white: 0, seconds: 4, name: "long-crossfade-black.mp4", size: canvas)
            var first = EditClip(sourceURL: bright, sourceDuration: 1.5, timelineStart: 0, info: info(canvas, seconds: 4))
            first.transitionAfter = .crossFade
            first.transitionDuration = 1.042
            let second = EditClip(sourceURL: dark, sourceStart: 1.25, sourceDuration: 1.5, timelineStart: 1.5,
                                  info: info(canvas, seconds: 4))
            var state = TimelineState()
            state.frameRate = .fps24
            state.mainClips = [first, second]
            let expanded = state.expandingTransitionHandles()
            check(abs(expanded.transitionOverlap(afterMainIndex: 0) - 1.042) < 1e-9,
                  "MCP-6: the render copies retain the full requested 1.042 seconds")
            let window = state.renderedTransitionWindow(afterMainIndex: 0)
            check(window.map { abs($0.start - 0.979) < 1e-9 && abs($0.duration - 1.042) < 1e-9 } == true,
                  "MCP-6: the requested dissolve is centred on the 1.5-second cut")
            let points = [(1.5 - 1.042 / 4, 0.75), (1.5 + 1.042 / 4, 0.25)]
            for (time, expected) in points {
                let got = await previewPixel(state, x: 64, y: 36, at: time)
                check(got.map { abs($0 - expected) < 0.12 } == true,
                      "MCP-6 preview: the full dissolve has brightness \(expected) at \(time), got \(got ?? -1)")
            }
            guard let product = await export(state, name: "long-crossfade-export.mp4") else { return }
            for (time, expected) in points {
                let got = pixel(product, x: 64, y: 36, at: time, name: "long-crossfade")
                check(got.map { abs($0 - expected) < 0.12 } == true,
                      "MCP-6 export: the full dissolve has brightness \(expected) at \(time), got \(got ?? -1)")
            }
            let duration = mediaDuration(product)
            check(duration.map { abs($0 - 3) < 0.05 } == true,
                  "MCP-6: extending render handles keeps the exported 3-second timeline, got \(duration ?? -1)")
        } catch {
            check(false, "MCP-6: synthetic crossFade fixture failed: \(error)")
        }
    }
}
