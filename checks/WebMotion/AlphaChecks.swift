import Foundation
import SrtFlowWebMotionKit

// The transparent background: known premultiplied values in the decoded movie; the fast path (WebKit's non-public
// switch) and the public black-and-white path agree within the probe's numbers (max 2 before encoding, + ProRes); and a
// broken fast path is noticed by the calibration and replaced by the public path on its own (`.auto`), or refused
// (`.fast`). `SRTFLOW_WEB_MOTION_TEST_BREAK_FAST_ALPHA` makes the helper skip the switch, as a macOS without it would.

enum AlphaChecks {
    static let breakFastAlpha = "SRTFLOW_WEB_MOTION_TEST_BREAK_FAST_ALPHA"

    static func run() async {
        section("Transparent background")
        let fast = await render(Fixture.job(Pages.alphaPatches, name: "alpha-fast", alpha: .fast))
        let open = await render(Fixture.job(Pages.alphaPatches, name: "alpha-public", alpha: .public))
        Fixture.setEnvironment(breakFastAlpha, "1")
        let switched = await render(Fixture.job(Pages.alphaPatches, name: "alpha-auto-broken", alpha: .auto))
        let refused = await render(Fixture.job(Pages.alphaPatches, name: "alpha-fast-broken", alpha: .fast))
        Fixture.setEnvironment(breakFastAlpha, nil)
        guard let fastRender = fast.render, let publicRender = open.render,
              let fastFrame = await MovieFrames.decode(fastRender.file, frames: [0])[0],
              let publicFrame = await MovieFrames.decode(publicRender.file, frames: [0])[0] else {
            check(false, "the alpha page renders on both paths (\(fast.summary) / \(open.summary))")
            return
        }
        patches(fastFrame, path: "fast")
        patches(publicFrame, path: "public")
        let (maximum, mean) = fastFrame.difference(to: publicFrame)
        check(maximum <= 3 && mean < 0.25, "fast and public paths agree on every pixel, glow edge included: max \(maximum), "
            + "mean " + String(format: "%.4f", mean) + " (the probe: max 2 before encoding; ProRes adds at most 1)")
        check(publicRender.result.alpha?.path == .public, "the public path reports itself")
        if let auto = switched.render, let autoFrame = await MovieFrames.decode(auto.file, frames: [0])[0] {
            check(auto.result.alpha?.path == .public && auto.result.alpha?.fastPathProblem?.contains("clear") == true,
                  "auto with a broken fast path: the calibration caught it and the public path took over "
                  + "(\(auto.result.alpha?.fastPathProblem ?? "no reason"))")
            check(autoFrame.difference(to: fastFrame).maximum <= 3, "…and the movie matches the good fast-path movie")
        } else {
            check(false, "auto with a broken fast path still renders (\(switched.summary))")
        }
        if case .failed(.rendererFailed(let message)) = refused {
            check(message.contains("fast transparent background is wrong"), "fast-only with a broken fast path is refused: \(message)")
        } else {
            check(false, "fast-only with a broken fast path is refused (\(refused.summary))")
        }
    }

    /// Patch centers in premultiplied BGRA, ± 2 (ProRes 4444 round trip).
    private static func patches(_ frame: DecodedFrame, path: String) {
        let wanted: [(String, Int, Int, (Int, Int, Int, Int))] = [
            ("nothing", 20, 40, (0, 0, 0, 0)), ("50 % green", 80, 40, (0, 128, 0, 128)),
            ("red", 130, 40, (0, 0, 255, 255)), ("25 % white", 180, 40, (64, 64, 64, 64)),
        ]
        for (name, x, y, want) in wanted {
            let got = frame.pixel(x: x, y: y)
            let close = abs(got.b - want.0) <= 2 && abs(got.g - want.1) <= 2 && abs(got.r - want.2) <= 2 && abs(got.a - want.3) <= 2
            check(close, "\(path) path, \(name): \(got), expected \(want) ± 2")
        }
        // The glow: opaque-ish center, a falling edge, nothing far out; color never above alpha (premultiplied).
        let ring = [230, 245, 255, 265, 300].map { frame.pixel(x: $0, y: 110).a }
        check(ring[0] > 200 && zip(ring, ring.dropFirst()).allSatisfy { $0 >= $1 } && ring.last == 0,
              "\(path) path, glow edge falls off smoothly to nothing: \(ring)")
        let premultiplied = (0..<frame.width).allSatisfy { x in
            let p = frame.pixel(x: x, y: 110)
            return p.r <= p.a + 2 && p.g <= p.a + 2 && p.b <= p.a + 2
        }
        check(premultiplied, "\(path) path, the glow row is premultiplied (no color above its alpha)")
    }
}
