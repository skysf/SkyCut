import Foundation

// MARK: - What SkyCut asks the web-motion helper to render
//
// Owns: the request SkyCut sends to `skycut-web-motion` (JSON on its stdin), the fixed caps, and the validation both
// sides run (`problems()`): a request SkyCut accepts is one the helper accepts, and the helper re-checks it anyway.
// Does not own: how a page is drawn (the helper), how SkyCut launches and watches the helper (`WebMotionRenderer`).
// Long-term rules: docs/architecture/web-motion-renderer.md.

/// How the transparent background is produced (decided by the user 2026-11-16, "按建议").
public enum WebMotionAlphaPath: String, Codable, Sendable, Equatable {
    /// Fast path first (WebKit draws no background, a non-public switch); a calibration page checks the alpha before
    /// every render and the render switches to `.public` by itself when it is wrong.
    case auto
    /// Only the fast path; a wrong calibration fails the render instead of switching.
    case fast
    /// Only public API: each frame drawn over black and over white, alpha derived from the difference (half speed).
    case `public`
}

/// The time limits. When one is hit the whole helper exits (and SkyCut kills it if it does not).
public struct WebMotionLimits: Codable, Sendable, Equatable {
    /// One page instance: load, fonts, `motion.ready`, first validation.
    public var load: Double
    /// One frame's JavaScript: the clock, `motion.frame(t)`, settling animations.
    public var script: Double
    /// One snapshot.
    public var snapshot: Double
    /// The whole helper run.
    public var total: Double

    public init(load: Double, script: Double, snapshot: Double, total: Double) {
        self.load = load
        self.script = script
        self.snapshot = snapshot
        self.total = total
    }

    /// The defaults for a render of `frames` frames: an endless loop in a frame stops within `script` seconds; the
    /// total grows with the length (heavy pages measured 5–25 frames/s on a busy M1) and is capped at 30 minutes.
    public static func standard(frames: Int) -> WebMotionLimits {
        WebMotionLimits(load: 15, script: 4, snapshot: 15, total: min(1_800, 60 + 2 * Double(max(frames, 1))))
    }
}

public struct WebMotionRequest: Codable, Sendable, Equatable {
    /// The page's full HTML. Loaded with `loadHTMLString(_:baseURL: nil)`: no file URL, no origin.
    public var html: String
    /// A JSON object, injected as `window.MOTION_PARAMS` before any page script runs.
    public var parametersJSON: String
    /// Seconds of motion; frames = round(duration × fps).
    public var duration: Double
    /// Output size in pixels (the snapshot size, fixed by the renderer: the page cannot change it).
    public var width: Int
    public var height: Int
    /// The page's viewport height in CSS px; the width follows the output's aspect ratio. 1080 by default: SkyCut's text
    /// sizes are defined on a 1080-high canvas (docs/architecture/text-overlays.md), so a page's px match them.
    public var layoutHeight: Double
    public var fps: Int
    /// Seeds `Math.random` and `crypto.getRandomValues` (re-seeded from this and t at every frame).
    public var seed: UInt32
    /// What `Date.now()` returns at t = 0 (ms since 1970).
    public var clockEpochMilliseconds: Double
    /// How many page instances draw frames in turn inside the one helper process (3 measured 2–2.5× faster than 1).
    public var workers: Int
    /// How many frames are drawn a second time, on another page instance, for the "same t, same image" check.
    public var samples: Int
    public var alpha: WebMotionAlphaPath
    public var limits: WebMotionLimits
    /// Where the helper writes the movie (SkyCut passes a work path and moves the file into place after a pass).
    public var outputPath: String

    public init(html: String, parametersJSON: String, duration: Double, width: Int, height: Int, fps: Int,
                outputPath: String, layoutHeight: Double = WebMotionCaps.referenceLayoutHeight,
                seed: UInt32 = WebMotionCaps.defaultSeed,
                clockEpochMilliseconds: Double = WebMotionCaps.defaultClockEpochMilliseconds,
                workers: Int = WebMotionCaps.defaultWorkers, samples: Int = WebMotionCaps.defaultSamples,
                alpha: WebMotionAlphaPath = .auto, limits: WebMotionLimits? = nil) {
        self.html = html
        self.parametersJSON = parametersJSON
        self.duration = duration
        self.width = width
        self.height = height
        self.fps = fps
        self.outputPath = outputPath
        self.layoutHeight = layoutHeight
        self.seed = seed
        self.clockEpochMilliseconds = clockEpochMilliseconds
        self.workers = workers
        self.samples = samples
        self.alpha = alpha
        let count = WebMotionRequest.frameCount(duration: duration, fps: fps)
        self.limits = limits ?? .standard(frames: count)
    }

    public static func frameCount(duration: Double, fps: Int) -> Int {
        guard duration.isFinite, duration > 0, fps > 0 else { return 0 }
        return Int((duration * Double(fps)).rounded())
    }

    public var frameCount: Int { WebMotionRequest.frameCount(duration: duration, fps: fps) }

    /// Seconds into the motion of frame `index`.
    public func time(ofFrame index: Int) -> Double { Double(index) / Double(fps) }

    /// The viewport width in CSS px (may be fractional on portrait canvases, e.g. 607.5 for 1080 × 1920).
    public var layoutWidth: Double { layoutHeight * Double(width) / Double(height) }

    /// Device pixels per CSS px: the page's `devicePixelRatio`.
    public var pixelRatio: Double { Double(height) / layoutHeight }

    /// Every way this request is out of bounds, in plain English (empty = fine).
    public func problems() -> [String] {
        var found: [String] = []
        let caps = WebMotionCaps.self
        if html.isEmpty { found.append("The page HTML is empty.") }
        if html.utf8.count > caps.maxHTMLBytes { found.append("The page is larger than \(caps.maxHTMLBytes / 1_048_576) MB.") }
        if parametersJSON.utf8.count > caps.maxParameterBytes {
            found.append("The parameters are larger than \(caps.maxParameterBytes / 1024) KB.")
        } else if (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) as? [String: Any] == nil {
            found.append("The parameters must be a JSON object.")
        }
        if !(duration.isFinite && duration > 0 && duration <= caps.maxDuration) {
            found.append("The duration must be more than 0 and at most \(Int(caps.maxDuration)) seconds.")
        }
        if !(caps.fpsRange ~= fps) { found.append("The frame rate must be \(caps.fpsRange.lowerBound)–\(caps.fpsRange.upperBound).") }
        if duration.isFinite, duration > 0, caps.fpsRange ~= fps, frameCount < 1 { found.append("The motion is shorter than one frame.") }
        found += sizeProblems()
        if !(layoutHeight.isFinite && caps.layoutHeightRange ~= layoutHeight) {
            found.append("The layout height must be \(Int(caps.layoutHeightRange.lowerBound))–\(Int(caps.layoutHeightRange.upperBound)) CSS px.")
        }
        if !clockEpochMilliseconds.isFinite { found.append("The clock epoch must be a finite number.") }
        if !(caps.workerRange ~= workers) { found.append("Workers must be \(caps.workerRange.lowerBound)–\(caps.workerRange.upperBound).") }
        if !(caps.sampleRange ~= samples) { found.append("Samples must be \(caps.sampleRange.lowerBound)–\(caps.sampleRange.upperBound).") }
        found += limitProblems()
        if !outputPath.hasPrefix("/") || !outputPath.lowercased().hasSuffix(".mov") {
            found.append("The output path must be an absolute .mov path.")
        }
        return found
    }

    private func sizeProblems() -> [String] {
        let caps = WebMotionCaps.self
        guard width >= caps.minSide, height >= caps.minSide, width % 2 == 0, height % 2 == 0,
              max(width, height) <= caps.maxLongSide, min(width, height) <= caps.maxShortSide else {
            return ["The size must be even, at least \(caps.minSide) px a side and at most "
                + "\(caps.maxLongSide)×\(caps.maxShortSide) (either orientation)."]
        }
        return []
    }

    private func limitProblems() -> [String] {
        let caps = WebMotionCaps.self
        let pairs: [(String, Double, ClosedRange<Double>)] = [
            ("load", limits.load, caps.loadLimitRange), ("script", limits.script, caps.scriptLimitRange),
            ("snapshot", limits.snapshot, caps.snapshotLimitRange), ("total", limits.total, caps.totalLimitRange),
        ]
        return pairs.compactMap { name, value, range in
            value.isFinite && range ~= value ? nil
                : "The \(name) time limit must be \(range.lowerBound)–\(range.upperBound) seconds."
        }
    }
}

/// The fixed caps (the page cannot change them).
public enum WebMotionCaps {
    public static let maxLongSide = 3840
    public static let maxShortSide = 2160
    public static let minSide = 16
    public static let maxDuration = 60.0
    public static let fpsRange = 1...120
    public static let maxHTMLBytes = 2 * 1_048_576
    public static let maxParameterBytes = 256 * 1024
    public static let referenceLayoutHeight = 1080.0
    public static let layoutHeightRange = 120.0...4320.0
    public static let workerRange = 1...4
    public static let defaultWorkers = 3
    public static let sampleRange = 1...32
    public static let defaultSamples = 8
    public static let defaultSeed: UInt32 = 1
    /// 2026-01-01T00:00:00Z.
    public static let defaultClockEpochMilliseconds = 1_767_225_600_000.0
    public static let loadLimitRange = 1.0...120.0
    public static let scriptLimitRange = 0.5...60.0
    public static let snapshotLimitRange = 1.0...120.0
    public static let totalLimitRange = 5.0...3_600.0
}
