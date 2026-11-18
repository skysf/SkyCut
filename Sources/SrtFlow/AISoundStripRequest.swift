import Foundation
import SrtFlowMCPKit

// MARK: - look sound=[…]: which rows to draw under the timeline frames, over which seconds (MCP-66)
//
// What it does: reads the AI's `sound` (a list of rows: "mix", a track "A1", tracks joined by + "V1+V2", or "rest"; true means
// ["mix"]) in the order given, at most `maxRows`. Track rows are parsed and checked exactly as listen mix=true checks its layers
// (AIListenMixPlan.layers: one parsing, one set of messages). The window is the clip's seconds when the look spreads its frames
// over clip_id, otherwise the frames' times with room either side (AISoundStrip.window). Where each sound starts comes from the
// timeline's audio configuration (AudioEngineConfig, the segments the engine plays): each audible segment that starts inside the
// window, on the row's tracks (the mix row has them all).
// Runs on the main actor before the look lets its line go (it reads only the state the look already took).
// What it does not do: measuring (AISoundStripMeasure), drawing (AISoundStripDrawing). Only timeline looks draw sound.

struct AISoundStripRequest: Sendable {
    struct Row: Sendable {
        var name: String
        /// Index into `layers`; nil is the mix.
        var layer: Int?
        var starts: [AISoundStrip.Start]
    }

    static let maxRows = 4

    var rows: [Row]
    var layers: [AudioStemLayer]
    var grid: MixFrameGrid
    var window: ClosedRange<Double>

    /// The rows `sound` asks for, or nil when it asks for none.
    static func parse(
        _ args: AIToolArguments, state: TimelineState, times: [Double], clipSpan: ClosedRange<Double>?
    ) throws -> AISoundStripRequest? {
        guard let specs = try specs(args) else { return nil }
        guard !specs.isEmpty else {
            throw AIToolError("sound needs at least one row: mix, a track like A1, tracks joined by + like V1+V2, or rest.")
        }
        guard specs.count <= maxRows else {
            throw AIToolError("sound draws at most \(maxRows) rows; join tracks with + (A1+A2) or use rest.")
        }
        var mix = false
        var trackSpecs: [String] = []
        var order: [Int?] = []
        for spec in specs {
            if spec.trimmingCharacters(in: .whitespaces).lowercased() == AISoundStrip.mixName {
                guard !mix else { throw AIToolError("mix is in sound more than once.") }
                mix = true
                order.append(nil)
            } else {
                order.append(trackSpecs.count)
                trackSpecs.append(spec)
            }
        }
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        let layers = trackSpecs.isEmpty ? [] : try AIListenMixPlan.layers(trackSpecs, config: config, state: state)
        let grid = MixFrameGrid(fps: state.frameRate.fps)
        let span = clipSpan.flatMap { span -> ClosedRange<Double>? in
            let from = max(0, span.lowerBound), to = min(state.duration, span.upperBound)
            return to > from ? from...to : nil
        }
        guard let window = span ?? AISoundStrip.window(times: times, duration: state.duration, grid: grid) else {
            throw AIToolError("There is no stretch of the timeline to draw the sound of.")
        }
        let ids = AIShortIDs(state: state)
        let rows = order.map { index -> Row in
            let tracks = index.map { layers[$0].tracks }
            return Row(name: index.map { layers[$0].name } ?? AISoundStrip.mixName, layer: index,
                       starts: starts(config, tracks: tracks, window: window, state: state, ids: ids))
        }
        return AISoundStripRequest(rows: rows, layers: layers, grid: grid, window: window)
    }

    /// sound is drawn only under timeline frames.
    static func refuseOutsideTimeline(_ args: AIToolArguments) throws {
        guard args.has("sound") else { return }
        let elsewhere = try args.bool("shots") == true || args.bool("text_scan") == true || args.has("files") || args.has("file")
        if elsewhere {
            throw AIToolError("sound draws the timeline's sound under timeline frames: leave out file, files, shots and text_scan "
                + "(listen measures a file's sound).")
        }
    }

    /// `sound` as a list of row names; true is ["mix"], false or absent is none.
    private static func specs(_ args: AIToolArguments) throws -> [String]? {
        if case .bool(let flag)? = args.raw["sound"] { return flag ? [AISoundStrip.mixName] : nil }
        return try args.stringArray("sound")
    }

    /// Each audible segment that starts inside `window` on `tracks` (indices into the configuration; nil = every track).
    static func starts(
        _ config: AudioEngineConfig, tracks: [Int]?, window: ClosedRange<Double>, state: TimelineState, ids: AIShortIDs
    ) -> [AISoundStrip.Start] {
        let kept = tracks.map(Set.init)
        return config.tracks.indices.filter { kept?.contains($0) ?? true }.flatMap { index in
            let track = config.tracks[index]
            return track.segments.filter { window.contains($0.start) }.map { segment in
                AISoundStrip.Start(time: segment.start, clip: ids.short(segment.clipID), track: AIListenMixPlan.aiName(track),
                                   name: state.clip(with: segment.clipID)?.name ?? segment.url.lastPathComponent)
            }
        }.sorted { $0.time < $1.time }
    }
}
