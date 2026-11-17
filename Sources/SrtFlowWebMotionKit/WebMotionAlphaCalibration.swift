import Foundation

// MARK: - The calibration page drawn before every render (pure)
//
// Owns: the page and what its pixels must read for the transparent background to count as right. The helper draws it
// with the same locked configuration and zoom as the real page; a wrong result on the fast path (WebKit's non-public
// "draw no background" switch) makes `.auto` switch to the public black-and-white path (user, 2026-11-16).
// Does not own: drawing it (the helper). docs/architecture/web-motion-renderer.md「透明背景」.

public enum WebMotionAlphaCalibration {
    /// Four 16-px patches in one row, drawn at 1×: nothing / 50 % green / opaque red / 25 % white.
    public static let cssWidth = 64.0
    public static let cssHeight = 16.0

    public static let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        div{position:absolute;top:0;width:16px;height:16px}
        </style></head><body>
        <div style="left:16px;background:rgba(0,255,0,0.5)"></div>
        <div style="left:32px;background:#ff0000"></div>
        <div style="left:48px;background:rgba(255,255,255,0.25)"></div>
        <script>window.motion={frame(){}};</script>
        </body></html>
        """

    /// What each patch's center must read (premultiplied BGRA ± tolerance).
    struct Expectation {
        let name: String
        let x: Int
        let b: Int, g: Int, r: Int, a: Int
    }

    static let tolerance = 3
    static let expectations = [
        Expectation(name: "clear", x: 8, b: 0, g: 0, r: 0, a: 0),
        Expectation(name: "green 50%", x: 24, b: 0, g: 128, r: 0, a: 128),
        Expectation(name: "red", x: 40, b: 0, g: 0, r: 255, a: 255),
        Expectation(name: "white 25%", x: 56, b: 64, g: 64, r: 64, a: 64),
    ]

    /// nil when the patches read as transparent, half, opaque and quarter as they should; otherwise what was wrong.
    public static func problem(_ frame: WebMotionFrameBytes) -> String? {
        guard frame.width == Int(cssWidth), frame.height == Int(cssHeight) else {
            return "The calibration snapshot is \(frame.width)×\(frame.height), not \(Int(cssWidth))×\(Int(cssHeight))."
        }
        for want in expectations {
            let got = frame.pixel(x: want.x, y: Int(cssHeight) / 2)
            let pairs = [(Int(got.b), want.b), (Int(got.g), want.g), (Int(got.r), want.r), (Int(got.a), want.a)]
            if pairs.contains(where: { abs($0.0 - $0.1) > tolerance }) {
                return "The \(want.name) patch reads BGRA (\(got.b), \(got.g), \(got.r), \(got.a)); "
                    + "expected (\(want.b), \(want.g), \(want.r), \(want.a)) ± \(tolerance)."
            }
        }
        return nil
    }

    /// The measured patches, for the result's record.
    public static func summary(_ frame: WebMotionFrameBytes) -> String {
        guard frame.width == Int(cssWidth), frame.height == Int(cssHeight) else { return "no calibration snapshot" }
        return expectations.map { want in
            let got = frame.pixel(x: want.x, y: Int(cssHeight) / 2)
            return "\(want.name) (\(got.b),\(got.g),\(got.r),\(got.a))"
        }.joined(separator: ", ")
    }
}
