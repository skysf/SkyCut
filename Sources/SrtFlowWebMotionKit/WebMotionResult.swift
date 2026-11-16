import Foundation

// MARK: - What the web-motion helper reports back
//
// Owns: the result of one render (the page checks of MCP-75, the failure text, versions, timing) and the JSON lines the
// helper prints on stdout while it works (`WebMotionEvent`). Does not own: deciding any of it (the helper) or what SkyCut
// does with it (`WebMotionRenderer`). docs/architecture/web-motion-renderer.md.

/// The checks a page must pass before SkyCut accepts its movie (MCP-75), in the order they are reported.
public enum WebMotionCheckName: String, Codable, CaseIterable, Sendable {
    /// The page loaded within the load limit (and its WebKit process did not die).
    case loads
    /// It defines `window.motion.frame(t)`.
    case frameEntry = "frame_entry"
    /// The same t drawn twice (the second time on another page instance, in reverse order) gives the same pixels.
    case sameTwice = "same_twice"
    /// Not every frame is empty, and no 1–2 frame empty gap sits between drawn frames (`WebMotionBlankFrames`).
    case noBlankFrames = "no_blank_frames"
    /// No uncaught error, unhandled rejection, error thrown by `frame(t)`, or blocked network / file access.
    case noPageErrors = "no_page_errors"
    /// No time limit was hit.
    case noTimeout = "no_timeout"
}

public struct WebMotionCheck: Codable, Sendable, Equatable {
    public var name: WebMotionCheckName
    /// nil = not reached (an earlier failure stopped the render).
    public var passed: Bool?
    public var detail: String

    public init(name: WebMotionCheckName, passed: Bool?, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// The first failure, with the page's own error text verbatim (the AI fixes the page with it).
public struct WebMotionFailure: Codable, Sendable, Equatable {
    public var check: WebMotionCheckName
    public var message: String
    /// The render time t (seconds) being drawn when it happened, if any.
    public var time: Double?

    public init(check: WebMotionCheckName, message: String, time: Double?) {
        self.check = check
        self.message = message
        self.time = time
    }
}

public struct WebMotionAlphaReport: Codable, Sendable, Equatable {
    /// `.auto` never appears here: it is the path actually used (`.fast` or `.public`).
    public var path: WebMotionAlphaPath
    /// Why the fast path was not used (nil when it was).
    public var fastPathProblem: String?
    /// The calibration page's measured patches (premultiplied BGRA), for the record.
    public var calibration: String
    /// The backing scale WebKit drew at before the zoom (2 on Retina).
    public var deviceScale: Double

    public init(path: WebMotionAlphaPath, fastPathProblem: String?, calibration: String, deviceScale: Double) {
        self.path = path
        self.fastPathProblem = fastPathProblem
        self.calibration = calibration
        self.deviceScale = deviceScale
    }
}

public enum WebMotionVersion {
    /// Bump whenever the same page, parameters and system can draw different pixels: the clock rules, alpha handling,
    /// zoom / layout, capture or encoding settings. Stored with a rendered clip (the next task), so a bump means "render
    /// again on purpose", never by accident.
    public static let renderer = 1
}

/// What drew the pixels: the same page, parameters and versions draw the same pixels (to store with the clip later).
public struct WebMotionVersions: Codable, Sendable, Equatable {
    public var renderer: Int
    public var macOS: String
    public var macOSBuild: String
    public var webKit: String

    public init(renderer: Int, macOS: String, macOSBuild: String, webKit: String) {
        self.renderer = renderer
        self.macOS = macOS
        self.macOSBuild = macOSBuild
        self.webKit = webKit
    }
}

public struct WebMotionTiming: Codable, Sendable, Equatable {
    public var setupSeconds: Double = 0
    public var loadSeconds: Double = 0
    public var renderSeconds: Double = 0
    public var verifySeconds: Double = 0
    public var finishSeconds: Double = 0
    public var totalSeconds: Double = 0
    /// Frames drawn per second in the main pass.
    public var framesPerSecond: Double = 0
    public var slowestFrameSeconds: Double = 0

    public init() {}
}

public struct WebMotionResult: Codable, Sendable, Equatable {
    public var accepted: Bool
    public var checks: [WebMotionCheck]
    public var failure: WebMotionFailure?
    /// Every page error seen, verbatim (at most `maxPageErrors`).
    public var pageErrors: [String]
    public var frameCount: Int
    /// SHA-256 of each drawn frame's premultiplied BGRA pixels, in frame order (as many as were drawn).
    public var frameHashes: [String]
    public var blankFrames: [Int]
    public var alpha: WebMotionAlphaReport?
    /// Some frame has a translucent or transparent pixel, so the movie carries alpha. False: every frame is fully
    /// opaque and the movie has no alpha channel (the encoder leaves an all-255 alpha out); SkyCut reads it as opaque.
    public var transparent: Bool
    public var versions: WebMotionVersions?
    public var timing: WebMotionTiming
    /// The WebKit processes (WebContent, GPU, Networking) the helper's pages used.
    public var webKitProcesses: [Int32]

    public static let maxPageErrors = 20

    public init(accepted: Bool, checks: [WebMotionCheck], failure: WebMotionFailure?, pageErrors: [String],
                frameCount: Int, frameHashes: [String], blankFrames: [Int], alpha: WebMotionAlphaReport?,
                transparent: Bool = true, versions: WebMotionVersions?, timing: WebMotionTiming, webKitProcesses: [Int32]) {
        self.accepted = accepted
        self.checks = checks
        self.failure = failure
        self.pageErrors = pageErrors
        self.frameCount = frameCount
        self.frameHashes = frameHashes
        self.blankFrames = blankFrames
        self.alpha = alpha
        self.transparent = transparent
        self.versions = versions
        self.timing = timing
        self.webKitProcesses = webKitProcesses
    }

    public func check(_ name: WebMotionCheckName) -> WebMotionCheck? { checks.first { $0.name == name } }
}

/// One line the helper prints on stdout (JSON, newline-terminated). The last line of a finished run is a `.result`.
public struct WebMotionEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// WebKit process ids so far (SkyCut measures their memory and makes sure they end with the helper).
        case processes
        /// Work is moving: SkyCut's no-progress backstop is reset by every event.
        case progress
        case result
    }

    public var kind: Kind
    public var processes: [Int32]?
    public var stage: String?
    public var done: Int?
    public var total: Int?
    public var result: WebMotionResult?

    public init(kind: Kind, processes: [Int32]? = nil, stage: String? = nil, done: Int? = nil, total: Int? = nil,
                result: WebMotionResult? = nil) {
        self.kind = kind
        self.processes = processes
        self.stage = stage
        self.done = done
        self.total = total
        self.result = result
    }

    /// The exact bytes of one stdout line.
    public func line() -> Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// The helper's exit codes (SkyCut reads the result line first; the code is the backstop).
public enum WebMotionExitCode {
    public static let accepted: Int32 = 0
    /// The page failed a check (the result says which, with the text).
    public static let rejected: Int32 = 1
    /// The request was out of bounds.
    public static let invalidRequest: Int32 = 2
    /// A time limit was hit.
    public static let timeLimit: Int32 = 3
    /// The renderer could not do its job (a lock unavailable, the encoder failed, WebKit missing).
    public static let internalFailure: Int32 = 4
}
