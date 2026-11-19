import Foundation
import SrtFlowMCPKit

// The catalog side of the time-bound checks (TimeBoundChecks.swift): every number in every tool's parameters is either a time
// listed in MCPTimeArguments or named in `notTimes` below, and every listed time exists. A new time parameter that nobody listed
// fails here instead of reaching a tool unbounded (docs/bugfixes/2026-11-19-huge-times-in-timeline-tools.md).
// Batch tools are read through their validation schemas (their catalog items name only the id); the official-film fields of
// save_project / generate_media are validated by the film readers with the same bound and are not walked here.
enum TimeBoundCatalog {
    /// Numbers that are not times: counts, levels, fractions, degrees, ids, frame counts.
    static let notTimes: [MCPToolName: Set<String>] = {
        let clip: Set<String> = ["animation_intensity", "crop.bottom", "crop.left", "crop.right", "crop.top", "focus_x", "focus_y", "opacity",
                                 "region.height", "region.width", "region.x", "region.y", "rotation", "scale", "sound_scene.distance",
                                 "sound_scene.distortion", "sound_scene.intensity", "sound_scene.room_size", "sound_scene.tone", "speed",
                                 "voice_band_db", "volume_curve[].db", "volume_db", "x", "y"]
        let text: Set<String> = ["animation_intensity", "box_width", "font_size", "letter_spacing", "number.decimals", "number.from",
                                 "number.to", "rotation", "stroke_width", "x", "y"]
        let shape: Set<String> = ["height", "line_width", "rotation", "strength", "sweep", "width", "x", "y"]
        let style: Set<String> = ["style.highlight_scale", "style.line_spacing", "style.margin", "style.max_width", "style.outline_width",
                                  "style.size"]
        func items(_ list: String, _ fields: Set<String>) -> Set<String> { Set(fields.map { "\(list)[].\($0)" }) }
        return [
            .openFolder: ["max_files"], .readDocument: ["from_char", "max_chars"], .saveProject: ["expected_revision"], .look: ["count"],
            .listen: ["silence_db"], .inspectVideo: ["silence_db"], .transcribe: ["max_chars"], .findAudio: ["max_results"],
            .addVoiceover: ["max_lines", "speed"], .recordScreen: ["display", "rect.height", "rect.width", "rect.x", "rect.y"],
            .generateMedia: ["camera_angle.rotate", "camera_angle.tilt", "camera_angle.zoom", "seed"], .listCharacters: ["limit"],
            .addClips: items("clips", ["sound_effect.brightness", "sound_effect.pitch", "sound_effect.size", "sound_effect.variation",
                                       "sound_effect.volume_db"]),
            .editClip: clip, .editClips: items("clips", clip),
            .setKeyframes: ["opacity[].value", "position[].x", "position[].y", "rotation[].degrees", "scale[].value"],
            .setTrack: ["duck_others_db", "volume_db"], .cutSpeech: ["silence_db"], .cutToBeat: ["beats_per_clip"],
            .setTransition: ["frames", "gain_db"], .setText: text, .setTexts: items("texts", text),
            .setMotion: ["fields[].maximum", "fields[].minimum"], .setShape: shape,
            .setShapes: items("shapes", shape.union(["length"])), .setFilter: ["strength"], .setCanvas: ["fps"],
            .generateSubtitles: ["max_lines"], .getSubtitles: ["limit"], .editSubtitles: style, .burnSubtitles: style, .undo: ["steps"],
            .setSettings: ["daily_ai_credit_limit", "optimized_media_cache_gb"],
        ]
    }()

    /// The schema a call is read against: batch tools through their single tool's full parameters.
    static func schema(for tool: MCPToolName) -> JSONValue {
        MCPBatchTools.validationSchema(for: tool) ?? tool.definition.inputSchema
    }

    /// Every number path of a schema (`a.b`, `list[].b`, `times[]`); an `anyOf` with a number counts.
    static func numberPaths(_ schema: JSONValue, at path: String = "") -> Set<String> {
        var found: Set<String> = []
        let named = schema["type"]?.stringValue.map { [$0] } ?? (schema["type"]?.arrayValue ?? []).compactMap(\.stringValue)
        let types = named + (schema["anyOf"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue }
        if !path.isEmpty, types.contains("number") || types.contains("integer") { found.insert(path) }
        for (key, child) in schema["properties"]?.objectValue ?? [:] {
            found.formUnion(numberPaths(child, at: path.isEmpty ? key : "\(path).\(key)"))
        }
        if let items = schema["items"] { found.formUnion(numberPaths(items, at: path + "[]")) }
        return found
    }

    /// What is wrong with the two lists for this tool (empty = whole): unlisted numbers, listed paths that are not numbers,
    /// and paths on both lists.
    static func problems(_ tool: MCPToolName) -> [String] {
        let numbers = numberPaths(schema(for: tool))
        let times = Set(MCPTimeArguments.paths(for: tool))
        let other = notTimes[tool] ?? []
        var found: [String] = []
        for path in numbers.subtracting(times).subtracting(other).sorted() {
            found.append("\(tool.rawValue).\(path) is a number on no list: a time goes into MCPTimeArguments.paths, anything else into notTimes")
        }
        for path in times.union(other).subtracting(numbers).sorted() { found.append("\(tool.rawValue).\(path) is listed but is not a number in the schema") }
        for path in times.intersection(other).sorted() { found.append("\(tool.rawValue).\(path) is on both lists") }
        return found
    }

    /// The concrete argument path the router names for a schema path: the first entry of each list (`clips[].start` → clips[0].start).
    static func concrete(_ path: String) -> String { path.replacingOccurrences(of: "[]", with: "[0]") }

    /// `arguments` with `value` written at the schema path, inside the first entry of each list (made when missing).
    static func setting(_ value: JSONValue, at path: String, in arguments: JSONValue) -> JSONValue {
        set(value, steps: path.split(separator: ".").map(String.init)[...], in: arguments)
    }

    private static func set(_ value: JSONValue, steps: ArraySlice<String>, in node: JSONValue) -> JSONValue {
        guard let step = steps.first else { return value }
        var object = node.objectValue ?? [:]
        guard step.hasSuffix("[]") else {
            object[step] = set(value, steps: steps.dropFirst(), in: object[step] ?? .object([:]))
            return .object(object)
        }
        let key = String(step.dropLast(2))
        var list = object[key]?.arrayValue ?? []
        if steps.count == 1 {
            list = [value]
        } else {
            let first = list.first ?? .object([:])
            list = [set(value, steps: steps.dropFirst(), in: first)] + list.dropFirst()
        }
        object[key] = .array(list)
        return .object(object)
    }
}
