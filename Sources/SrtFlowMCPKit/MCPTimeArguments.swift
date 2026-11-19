import Foundation

// MARK: - Times an AI passes: one bound for every tool
//
// What it owns: the supported timeline (0 to 86,400 seconds, one day: the bound the official-film records and their save_project
// schema already used), which parameters of which tools are times in seconds (a timeline time, a file second, a duration), and
// `firstOutOfBounds`, which names the first time in a call that is not a finite number inside that range. The App's router
// refuses such a call before it queues, starts a round or opens an undo group (`AIEditLimits.timeRefusal`).
// What it does not own: each tool's own, narrower rule (a clip's source window, a transition's 0.1–3 s, web motion's 60 s, a
// recording's 1–14,400 s). The tools still check those when they read their arguments (AIToolArguments); this only keeps
// values no tool can mean from reaching them.
// Why: a finite but huge time (10^20 s, a typo or a unit mix-up) was stored with an undo step and quit SkyCut at the next export
// or look (docs/bugfixes/2026-11-19-huge-times-in-timeline-tools.md). Every number in the catalog is either listed here or known
// not to be a time; checks/ParameterLimits/TimeBoundChecks.swift keeps both lists whole and calls every listed one.
// Two edges (2026-11-19, docs/bugfixes/2026-11-19-time-bound-refuses-relative-keyframes-and-timeline-end.md): a project whose
// timeline the tools made run past the day (a title at 86,400 s) keeps every time inside it usable (`allowed`, given the
// project's end), and set_keyframes' `relative: true` times are clip fractions with their own narrow rule (`relativeFractions`).
public enum MCPTimeArguments {
    /// One day of seconds: the longest timeline SkyCut supports.
    public static let maximumSeconds: Double = 86_400
    public static let seconds: ClosedRange<Double> = 0...maximumSeconds
    /// The clip fractions set_keyframes takes with `relative: true`: a hair outside 0–1 (a computed fraction's rounding) is the
    /// clip's edge, which the tool clamps it to (AIKeyframes).
    public static let relativeFractions: ClosedRange<Double> = -0.001...1.001

    /// The range every listed time of a call must be in: the supported timeline, or up to the project's own end when that
    /// already runs past the day (`timelineEnd`: the project the call lands on, nil when it has none); clip fractions for
    /// set_keyframes' times with `relative: true` (read as the tools read a yes / no, `JSONValue.flagValue`).
    public static func allowed(tool: MCPToolName, arguments: JSONValue, timelineEnd: Double? = nil) -> ClosedRange<Double> {
        if tool == .setKeyframes, arguments["relative"]?.flagValue == true { return relativeFractions }
        guard let timelineEnd, timelineEnd.isFinite, timelineEnd > maximumSeconds else { return seconds }
        return 0...timelineEnd
    }

    /// The first time-valued argument outside `allowed`: where (`clips[0].start`, `times[2]`), the number as read
    /// (it may be NaN or infinite when it was written as text) and the range it is outside.
    public struct Finding: Equatable, Sendable {
        public let path: String
        public let requested: Double
        public let allowed: ClosedRange<Double>

        /// The list and entry a path starts in (`clips[0].start` → clips, 0); nil for a top-level parameter.
        public var entry: (list: String, index: Int)? {
            guard let open = path.firstIndex(of: "["), let close = path[open...].firstIndex(of: "]"),
                  let index = Int(path[path.index(after: open)..<close]) else { return nil }
            return (String(path[..<open]), index)
        }
    }

    /// The tool's time parameters as schema paths: `a.b` is a field of an object, `list[]` every entry of a list
    /// (`lines[].start`; `times[]` alone is a list of times). Exhaustive, so a new tool decides here.
    public static func paths(for tool: MCPToolName) -> [String] {
        switch tool {
        case .look: return ["time", "times[]", "from", "source_in", "source_out"]
        case .listen: return ["from", "to", "source_in", "source_out", "min_silence"]
        case .inspectVideo: return ["from", "to", "min_silence"]
        case .transcribe: return ["from", "to", "source_in", "source_out"]
        case .addVoiceover: return ["lines[].start"]
        case .syncVoiceover: return ["paragraphs[].from", "paragraphs[].to", "start"]
        case .manageVoices: return ["start", "end"]
        case .recordScreen: return ["duration", "countdown"]
        case .generateMedia: return ["duration", "start_time", "end_time"]
        case .addClips:
            return ["clips[].start", "clips[].source_in", "clips[].source_out", "clips[].hit", "clips[].hit_at", "clips[].sound_effect.duration"]
        case .editClip: return clipTimes
        case .editClips: return clipTimes.map { "clips[]." + $0 }
        case .setKeyframes: return ["position[].time", "scale[].time", "rotation[].time", "opacity[].time"]
        case .splitClip, .seek: return ["time"]
        case .freezeFrame: return ["time", "duration"]
        case .cutSpeech: return ["keep[].start", "keep[].end", "remove[].start", "remove[].end", "pause_left", "remove_pauses"]
        case .duplicateItems: return ["start"]
        case .setTransition: return ["duration"]
        case .setText: return textTimes
        case .setTexts: return textTimes.map { "texts[]." + $0 }
        case .setMotion: return ["at", "hit_at", "duration", "hit"]
        case .setShape: return shapeTimes
        case .setShapes: return shapeTimes.map { "shapes[]." + $0 }
        case .setFilter: return ["start", "duration"]
        case .setCanvas: return ["duration"]
        case .getSubtitles: return ["start", "end"]
        case .editSubtitles: return ["add[].start", "add[].end", "changes[].start", "changes[].end"]
        case .getJob: return ["wait_seconds"]
        case .skycutGuide, .getStatus, .setView, .openFolder, .readDocument, .recipes, .saveRecipe, .manageFiles, .openProject,
             .newProject, .closeProject, .saveProject, .getTimeline, .findAudio, .listVoices, .changeVoice, .listCharacters,
             .getCharacter, .manageCharacters, .upscaleClip, .setTrack, .cutToBeat, .deleteItems, .generateSubtitles,
             .translateSubtitles, .exportVideo, .exportSubtitles, .compressVideos, .burnSubtitles, .convertSubtitles, .cancelJob,
             .undo, .getSettings, .setSettings:
            return []
        }
    }

    private static let clipTimes = ["start", "source_in", "source_out", "fade_in", "fade_out", "entrance_duration", "exit_duration",
                                    "markers[].time", "volume_curve[].time"]
    private static let textTimes = ["start", "duration", "hit_at", "animation_in_duration", "animation_out_duration", "number.delay",
                                    "number.seconds"]
    private static let shapeTimes = ["start", "duration", "animation_in_duration", "animation_out_duration"]

    /// The first time in `arguments` that is not a finite number inside `allowed` (`timelineEnd`: the end of the project the call
    /// lands on), in the order of `paths(for:)`. Numbers written as text count ("1e20", "nan", "inf"); other types are left to the
    /// tool, which reports them.
    public static func firstOutOfBounds(tool: MCPToolName, arguments: JSONValue, timelineEnd: Double? = nil) -> Finding? {
        let range = allowed(tool: tool, arguments: arguments, timelineEnd: timelineEnd)
        for path in paths(for: tool) {
            if let found = first(in: arguments, path.split(separator: ".").map(String.init)[...], at: "", range: range) { return found }
        }
        return nil
    }

    private static func first(in value: JSONValue, _ steps: ArraySlice<String>, at path: String, range: ClosedRange<Double>) -> Finding? {
        guard let step = steps.first else {
            guard let number = number(value), !range.contains(number) else { return nil }
            return Finding(path: path, requested: number, allowed: range)
        }
        let isList = step.hasSuffix("[]")
        let key = isList ? String(step.dropLast(2)) : step
        guard let child = value[key], !child.isNull else { return nil }
        let here = path.isEmpty ? key : path + "." + key
        guard isList else { return first(in: child, steps.dropFirst(), at: here, range: range) }
        for (index, item) in (child.arrayValue ?? []).enumerated() {
            if let found = first(in: item, steps.dropFirst(), at: "\(here)[\(index)]", range: range) { return found }
        }
        return nil
    }

    /// A number, or text that reads as one: the App's argument reader takes "3.5" for 3.5 too.
    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
