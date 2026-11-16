import Foundation
import SrtFlowWebMotionKit

// Normal pages through the real helper and SkyCut's API: accepted with every check passed, the movie is what SkyCut
// expects (premultiplied tag, frame count), two renders are pixel-identical, the clock takeover shows in the pixels,
// and the default layout (1080 CSS px tall) lands where it should at another output size.

enum NormalChecks {
    static func run() async {
        section("Normal pages")
        await plainTwice()
        await clockBands()
        await layout()
    }

    private static func plainTwice() async {
        let first = await render(Fixture.job(Pages.plain, name: "plain-1"))
        let second = await render(Fixture.job(Pages.plain, name: "plain-2"))
        guard let a = first.render, let b = second.render else {
            check(false, "a normal page is accepted (\(first.summary) / \(second.summary))")
            return
        }
        check(a.result.checks.allSatisfy { $0.passed == true }, "a normal page passes all six checks: "
            + a.result.checks.map { "\($0.name.rawValue)=\($0.passed.map(String.init) ?? "nil")" }.joined(separator: " "))
        check(a.result.frameCount == 12 && a.result.frameHashes.count == 12, "12 frames for 1 s at 12 fps")
        let versions = a.result.versions
        check(versions?.renderer == WebMotionVersion.renderer && versions?.macOS.isEmpty == false
              && versions?.webKit.isEmpty == false && versions?.macOSBuild.isEmpty == false,
              "renderer, macOS and WebKit versions are reported (\(String(describing: versions)))")
        check(a.result.frameHashes == b.result.frameHashes, "two renders of the same page are pixel-identical (12 frame hashes)")
        let tag = await MovieFrames.alphaTag(a.file)
        check(tag == .premultiplied, "SkyCut reads the movie as premultiplied alpha (SourceAlpha: \(String(describing: tag)))")
        check(await MovieFrames.frameCount(a.file) == 12, "the movie has 12 frames")
        let framesA = await MovieFrames.decode(a.file, frames: [0, 6, 11])
        let framesB = await MovieFrames.decode(b.file, frames: [0, 6, 11])
        let same = [0, 6, 11].allSatisfy { index in
            guard let x = framesA[index], let y = framesB[index] else { return false }
            return x.difference(to: y).maximum == 0
        }
        check(same, "the two movies decode to identical frames")
        if let frame = framesA[6] {
            check(frame.width == 320 && frame.height == 180, "the movie is exactly the requested 320×180")
            check(frame.firstOpaqueX(row: 100, threshold: 60) == 110, "the box stands at x = 110 at t = 0.5 (10 + 0.5 × 200), "
                + "got \(String(describing: frame.firstOpaqueX(row: 100, threshold: 60)))")
        }
        check(a.result.alpha?.path == .fast, "this Mac draws the fast transparent background (calibration: \(a.result.alpha?.calibration ?? "-"))")
        print("    timing: \(String(format: "%.2f", a.result.timing.totalSeconds)) s in all, "
            + "\(String(format: "%.1f", a.result.timing.framesPerSecond)) frames/s drawing, peak \(a.peakFootprint >> 20) MB")
    }

    private static func clockBands() async {
        let first = await render(Fixture.job(Pages.clockBands, name: "bands-1"))
        let second = await render(Fixture.job(Pages.clockBands, name: "bands-2"))
        guard let a = first.render, let b = second.render else {
            check(false, "the clock page is accepted (\(first.summary) / \(second.summary))")
            return
        }
        check(a.result.frameHashes == b.result.frameHashes, "Math.random-driven pixels are the same in two renders (seeded per t)")
        let frames = await MovieFrames.decode(a.file, frames: [0, 6])
        let names = ["performance.now", "Date.now", "CSS animation", "requestAnimationFrame"]
        for (band, name) in names.enumerated() {
            let row = band * 30 + 10
            let start = frames[0]?.firstOpaqueX(row: row)
            let middle = frames[6]?.firstOpaqueX(row: row)
            check(start == 0 && middle == 50, "\(name) follows the render time: x = 0 at t = 0, 50 at t = 0.5 "
                + "(got \(String(describing: start)), \(String(describing: middle)))")
        }
    }

    /// Default layout: the page sees 1920×1080 CSS px whatever the output; at 640×360 a CSS (960, 540) box is at (320, 180).
    private static func layout() async {
        var job = Fixture.job(Pages.layout, name: "layout", width: 640, height: 360, parameters: ["color": "#ff0000"])
        job.layoutHeight = WebMotionCaps.referenceLayoutHeight
        let outcome = await render(job)
        guard let done = outcome.render, let frame = await MovieFrames.decode(done.file, frames: [0])[0] else {
            check(false, "the layout page is accepted (\(outcome.summary))")
            return
        }
        let inside = frame.pixel(x: 330, y: 190)
        let outside = frame.pixel(x: 310, y: 170)
        check(inside.r > 250 && inside.a > 250 && outside.a == 0,
              "1080-tall layout at 640×360: the CSS (960, 540) box starts at (320, 180) and takes its color from MOTION_PARAMS "
              + "(inside \(inside), outside \(outside))")
        check(frame.firstOpaqueX(row: 200) == 320, "the box's left edge is exactly x = 320 (got \(String(describing: frame.firstOpaqueX(row: 200))))")
    }
}
