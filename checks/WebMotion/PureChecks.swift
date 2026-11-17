import Foundation
import SrtFlowWebMotionKit

// The kit's pure rules: alpha from black and white, the empty-frame verdict, where the lock tags go, request bounds,
// the memory policy.

enum PureChecks {
    static func run() {
        section("Pure rules (kit)")
        deriveAlpha()
        blankFrames()
        lockTags()
        requestBounds()
        memoryPolicy()
    }

    private static func deriveAlpha() {
        // Over black / over white for: nothing, opaque gray, 50 % green, 25 % white.
        let black: [UInt8] = [0, 0, 0, 0, 90, 90, 90, 255, 0, 128, 0, 255, 64, 64, 64, 255]
        let white: [UInt8] = [255, 255, 255, 255, 90, 90, 90, 255, 127, 255, 127, 255, 255, 255, 255, 255]
        var out = black
        out.withUnsafeMutableBytes { target in
            white.withUnsafeBytes { source in
                let bytes = WebMotionFrameBytes(base: source.baseAddress!, width: 4, height: 1, bytesPerRow: 16)
                WebMotionPixels.deriveAlpha(black: target.baseAddress!, white: bytes)
            }
        }
        check(Array(out[0..<4]) == [0, 0, 0, 0], "black/white derivation: nothing stays fully transparent")
        check(Array(out[4..<8]) == [90, 90, 90, 255], "black/white derivation: an opaque color keeps its color and alpha 255")
        check(Array(out[8..<12]) == [0, 128, 0, 128], "black/white derivation: 50 % green → premultiplied (0, 128, 0, 128), got \(Array(out[8..<12]))")
        check(Array(out[12..<16]) == [64, 64, 64, 64], "black/white derivation: 25 % white → (64, 64, 64, 64), got \(Array(out[12..<16]))")
    }

    private static func blankFrames() {
        func verdict(_ pattern: String) -> WebMotionBlankFrames.Verdict {
            WebMotionBlankFrames.verdict(blank: pattern.map { $0 == "_" })
        }
        check(!verdict("____").passed, "empty frames: every frame empty fails")
        check(verdict("__xxx__").passed, "empty frames: empty at the start and the end passes (fade in / out)")
        let flicker = verdict("xx_xx")
        check(!flicker.passed && flicker.failingFrame == 2, "empty frames: one empty frame between drawn frames fails at frame 2")
        check(!verdict("x__x").passed, "empty frames: a two-frame gap fails")
        check(verdict("x___x").passed, "empty frames: a three-frame gap mid-motion passes (a deliberate cut)")
        check(verdict("xxxx").detail == "No empty frames.", "empty frames: nothing empty says so")
    }

    private static func lockTags() {
        let tags = WebMotionPageHTML.lockTags
        let doctype = WebMotionPageHTML.locked("<!-- note -->\n<!DOCTYPE html><html><head></head></html>")
        check(doctype.hasPrefix("<!-- note -->\n<!DOCTYPE html>" + tags), "lock tags go right after a doctype preceded by comments")
        check(WebMotionPageHTML.locked("<script>x()</script><!doctype html>").hasPrefix(tags),
              "lock tags go first when markup comes before any doctype (nothing runs ahead of them)")
        check(WebMotionPageHTML.locked("\u{FEFF}<!doctype html><p>").hasPrefix("\u{FEFF}<!doctype html>" + tags),
              "a byte-order mark before the doctype is skipped")
        check(!tags.contains("\n"), "lock tags add no line break (the page's error line numbers stay its own)")
        for directive in ["default-src 'none'", "connect-src 'none'", "worker-src 'none'", "frame-src 'none'", "font-src 'none'"] {
            check(WebMotionPageHTML.contentSecurityPolicy.contains(directive), "the page's CSP has \(directive)")
        }
    }

    private static func requestBounds() {
        func request(width: Int = 320, height: Int = 180, duration: Double = 1, fps: Int = 12, parameters: String = "{}",
                     output: String = "/tmp/x.mov") -> WebMotionRequest {
            WebMotionRequest(html: "<p>", parametersJSON: parameters, duration: duration, width: width, height: height, fps: fps,
                             outputPath: output)
        }
        check(request().problems().isEmpty, "a 320×180, 1 s, 12 fps request is in bounds")
        check(request(width: 3840, height: 2160).problems().isEmpty && request(width: 2160, height: 3840).problems().isEmpty,
              "3840×2160 is the cap, either orientation")
        check(!request(width: 3842, height: 2160).problems().isEmpty, "wider than 3840 is refused")
        check(!request(width: 321).problems().isEmpty, "an odd width is refused")
        check(!request(duration: 60.5).problems().isEmpty && request(duration: 60).problems().isEmpty, "60 s is the longest")
        check(!request(duration: 0).problems().isEmpty, "zero duration is refused")
        check(!request(fps: 0).problems().isEmpty, "zero fps is refused")
        check(!request(parameters: "[1]").problems().isEmpty, "parameters that are not a JSON object are refused")
        check(!request(output: "relative.mov").problems().isEmpty, "a relative output path is refused")
        check(WebMotionLimits.standard(frames: 96).total == 252 && WebMotionLimits.standard(frames: 7200).total == 1800,
              "the total time limit grows with the frames and stops at 30 minutes")
    }

    private static func memoryPolicy() {
        let gb: UInt64 = 1 << 30
        let policy = WebMotionMemoryPolicy.standard(physicalMemory: 16 * gb)
        check(policy.budget == 3 * gb && policy.warningBudget == gb, "16 GB Mac: 3 GB budget, 1 GB while memory is low")
        check(WebMotionMemoryPolicy.standard(physicalMemory: 8 * gb).budget == 2 * gb, "8 GB Mac: a quarter of memory")
        check(policy.verdict(pressure: .normal, footprint: 500 << 20) == .keepGoing, "500 MB at normal pressure keeps going")
        check(policy.verdict(pressure: .normal, footprint: 4 * gb) == .overBudget(limit: 3 * gb), "over budget is stopped")
        check(policy.verdict(pressure: .warning, footprint: 2 * gb) == .overWarningBudget(limit: gb),
              "low memory: over the smaller budget is stopped")
        check(policy.verdict(pressure: .warning, footprint: 500 << 20) == .keepGoing, "low memory: a normal render keeps going")
        check(policy.verdict(pressure: .critical, footprint: 0) == .machineCritical, "out of memory: the render is stopped")
    }
}
