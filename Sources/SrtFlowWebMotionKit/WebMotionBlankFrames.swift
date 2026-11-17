import Foundation

// MARK: - "No empty frame" (pure)
//
// Owns: which runs of fully transparent frames fail the check. A title that fades in from nothing legitimately starts
// empty, and one that fades out ends empty, so leading and trailing empty runs pass. What fails is every frame empty, or a
// short empty gap (1–2 frames) between drawn frames: that is the flicker of an image or font not ready when the frame was
// captured (the probe's pitfall 7). A longer gap mid-motion is reported but passes (a deliberate cut to nothing).
// Does not own: deciding that a single frame is empty (`WebMotionPixels.isBlank`).

public enum WebMotionBlankFrames {
    /// Gaps of at most this many empty frames between drawn frames fail.
    public static let flickerLength = 2

    public struct Verdict: Equatable, Sendable {
        public var passed: Bool
        public var detail: String
        public var blank: [Int]
        /// The first frame of the failing run (nil when passed or when every frame is empty).
        public var failingFrame: Int?
    }

    public static func verdict(blank flags: [Bool]) -> Verdict {
        let blank = flags.indices.filter { flags[$0] }
        guard !flags.isEmpty else { return Verdict(passed: false, detail: "No frames were drawn.", blank: []) }
        guard let first = flags.firstIndex(of: false), let last = flags.lastIndex(of: false) else {
            return Verdict(passed: false, detail: "Every frame is empty (fully transparent): nothing was drawn.", blank: blank)
        }
        let runs = emptyRuns(flags, from: first, through: last)
        if let flicker = runs.first(where: { $0.count <= flickerLength }) {
            let what = flicker.count == 1 ? "Frame \(flicker.lowerBound) is" : "Frames \(flicker.lowerBound)–\(flicker.upperBound - 1) are"
            return Verdict(passed: false,
                           detail: "\(what) empty between drawn frames (usually an image or font not ready when the frame "
                               + "was drawn).",
                           blank: blank, failingFrame: flicker.lowerBound)
        }
        var parts: [String] = []
        if first > 0 { parts.append("starts with \(first) empty frame\(first == 1 ? "" : "s")") }
        if last < flags.count - 1 {
            let tail = flags.count - 1 - last
            parts.append("ends with \(tail) empty frame\(tail == 1 ? "" : "s")")
        }
        if !runs.isEmpty { parts.append("\(runs.count) longer empty stretch\(runs.count == 1 ? "" : "es") mid-motion") }
        return Verdict(passed: true, detail: parts.isEmpty ? "No empty frames." : "Passed; " + parts.joined(separator: ", ") + ".",
                       blank: blank)
    }

    /// Runs of empty frames strictly between `first` and `last` (both drawn).
    static func emptyRuns(_ flags: [Bool], from first: Int, through last: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in first...last {
            if flags[index] {
                if start == nil { start = index }
            } else if let open = start {
                runs.append(open..<index)
                start = nil
            }
        }
        return runs
    }
}
