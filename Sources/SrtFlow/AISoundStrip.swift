import Foundation
import SrtFlowMCPKit

// MARK: - The sound under a contact sheet, as plain values (look sound=…, inspect_video's evidence sheet; MCP-66)
//
// What it holds: a window of the timeline (from / to, seconds) at the project frame rate, one row per sound drawn (the mix, or a
// group of tracks named like listen's layers) with each project frame's level and true peak, where each sound starts inside the
// window, and where each frame of the sheet lies (marks, in tile order: #1, #2, …).
// Pure rules: the window for a set of frame times, the columns for a picture width (a pixel shows the frames under it: their mean
// level and their highest peak), and the summary the AI reads next to the picture (each row's loudest frame and true peak, the
// starts). The loudest frame and the peak follow listen mix=true (AIListenMixReport): the start of the frame with the highest mean
// square, the highest true peak in dBTP to a tenth.
// Who fills it: AISoundStripMeasure (look: the engine's offline render; inspect_video: the frames its report measured). Who draws
// it: AISoundStripDrawing. Who reads the AI's request: AISoundStripRequest.
// Why: the AI matched a hit to a frame or a cut by reading listen's numbers against look's frames by hand. It says how loud and
// when, never what a sound is. Contract: docs/architecture/ai-control-mcp.md section 4 item 12.

struct AISoundStrip: Sendable {
    /// One project frame of one row.
    struct Level: Sendable, Equatable {
        /// Mean square over the frame (both channels averaged).
        var meanSquare: Double
        /// True peak over the frame (linear; above 1 is over full scale).
        var peak: Float
    }

    /// Where a clip's sound starts inside the window.
    struct Start: Sendable, Equatable {
        var time: Double
        /// The clip's short id (AIShortIDs), as get_timeline writes it.
        var clip: String
        /// The track in the AI's names (V1 is the main track).
        var track: String
        var name: String
    }

    struct Row: Sendable {
        /// "mix", or the tracks the row holds in the AI's names ("A1", "V1+V2", "rest").
        var name: String
        /// One per project frame from `firstFrame` on.
        var levels: [Level]
        var starts: [Start]
    }

    /// A pixel column: the frames under it.
    struct Column: Sendable, Equatable {
        var meanSquare: Double
        var peak: Float
    }

    static let mixName = "mix"
    /// How many starts the JSON lists (the picture draws them all; the rest are counted).
    static let maxListedStarts = 24

    var grid: MixFrameGrid
    /// The timeline frame the levels start at.
    var firstFrame: Int
    var from: Double
    var to: Double
    var rows: [Row]
    /// Levels after the export limiter (inspect_video: the delivered sound) or before it (look: the master bus, as listen mix=true).
    var afterLimiter: Bool
    /// The limiter's ceiling (linear true peak): peaks above it are drawn red.
    var ceiling: Float
    /// The sheet's frames in tile order (#1, #2, …), timeline seconds.
    var marks: [Double] = []

    // MARK: Window

    /// The seconds a strip spans for frames at `times`: from the first to the last frame's end with room either side (half the
    /// spacing between frames, at least one frame, at most a second; one frame alone gets a second either side), inside the
    /// timeline. nil when there is nothing to span.
    static func window(times: [Double], duration: Double, grid: MixFrameGrid) -> ClosedRange<Double>? {
        guard let first = times.min(), let last = times.max(), duration > 0 else { return nil }
        let frame = 1 / Double(grid.fps)
        let spacing = times.count > 1 ? (last - first) / Double(times.count - 1) : 2
        let room = min(1, max(frame, spacing / 2))
        let from = max(0, first - room)
        let to = min(duration, last + frame + room)
        return to > from ? from...to : nil
    }

    /// The timeline frames a window covers (the frame holding its start up to the one holding its end), inside `total` frames.
    static func frames(of window: ClosedRange<Double>, grid: MixFrameGrid, total: Int) -> Range<Int> {
        let first = min(max(0, grid.frame(containing: window.lowerBound)), max(0, total - 1))
        let end = min(total, max(first + 1, grid.frame(endingAt: window.upperBound)))
        return first ..< end
    }

    // MARK: Columns

    /// Where `time` falls on a picture `width` pixels wide (0 at `from`, `width` at `to`).
    func x(of time: Double, width: Int) -> Double {
        Double(width) * (time - from) / max(1e-9, to - from)
    }

    /// `row` drawn `width` pixels wide: each column holds the frames under it (their mean level and their highest peak), at least
    /// the one frame its middle falls in; nil where no measured frame is.
    func columns(of row: Row, width: Int) -> [Column?] {
        guard width > 0 else { return [] }
        guard to > from, !row.levels.isEmpty else { return Array(repeating: nil, count: width) }
        let span = to - from
        return (0..<width).map { x in
            let start = from + span * Double(x) / Double(width)
            let end = from + span * Double(x + 1) / Double(width)
            let middle = grid.frame(containing: (start + end) / 2) - firstFrame
            let lower = max(0, min(middle, grid.frame(containing: start) - firstFrame))
            let upper = min(row.levels.count - 1, max(middle, grid.frame(endingAt: end) - 1 - firstFrame))
            guard lower <= upper, lower < row.levels.count, upper >= 0 else { return nil }
            let slice = row.levels[lower...upper]
            return Column(meanSquare: slice.reduce(0) { $0 + $1.meanSquare } / Double(slice.count), peak: slice.map(\.peak).max() ?? 0)
        }
    }

    // MARK: What the AI reads

    /// Every start once (a start shows in the mix row and in its own track's row), in time order.
    var allStarts: [Start] {
        var seen = Set<String>()
        return rows.flatMap(\.starts).filter { seen.insert("\($0.clip)@\($0.time)").inserted }.sorted { $0.time < $1.time }
    }

    /// The window, each row's loudest frame and true peak, and the starts (at most `maxListedStarts`, the rest counted).
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "from": AIFormat.seconds(from), "to": AIFormat.seconds(to), "frame_rate": .number(Double(grid.fps)),
            "levels": .string(afterLimiter ? "after the export limiter (as delivered)" : "before the export limiter, as listen mix=true"),
            "rows": .array(rows.map(rowSummary))
        ]
        let starts = allStarts
        object["starts"] = .array(starts.prefix(Self.maxListedStarts).map {
            ["at": AIFormat.seconds($0.time), "clip": .string($0.clip), "track": .string($0.track), "name": .string($0.name)]
        })
        if starts.count > Self.maxListedStarts { object["more_starts"] = .number(Double(starts.count - Self.maxListedStarts)) }
        return .object(object)
    }

    private func rowSummary(_ row: Row) -> JSONValue {
        var entry: [String: JSONValue] = ["row": .string(row.name)]
        guard let loudest = row.levels.indices.max(by: { row.levels[$0].meanSquare < row.levels[$1].meanSquare }),
              row.levels[loudest].meanSquare > 0 else {
            entry["silent"] = true
            return .object(entry)
        }
        entry["loudest_at"] = AIFormat.seconds(grid.seconds(ofFrame: firstFrame + loudest))
        entry["peak_db"] = .number((TruePeak.decibels(row.levels.map(\.peak).max() ?? 0) * 10).rounded() / 10)
        return .object(entry)
    }
}
