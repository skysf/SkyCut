import Foundation
import SrtFlowMCPKit

// MARK: - Ducking under speech: the result the AI reads (pure)
//
// Owns (MCP-29): set_track duck_others_db's result — which track spoke and how deep the dip is, how many lines and where the
// dips are (timeline seconds), which clips dipped and which already sat that way, which were left alone because they lie inside
// a line, where the volume floor stopped a dip short, and where the lines came from (transcript / pauses; camera sound without
// a transcript, unreadable files). Built from the committed outcome, ids from the committed state.
// Not here: computing any of it (SpeechDuck, SpeechDuckCurve, SpeechDuckPlanner, SpeechDuckLines), the call (AISpeechDuckTool).

enum SpeechDuckReport {
    /// Windows listed in the result; the rest are counted.
    static let maxWindows = 40
    /// A dip this much shallower than asked is reported (the volume floor stopped it).
    static let shortfall = 0.05

    static func json(
        voice: TrackSlot, depth: Double, speech: SpeechDuckPlanner.Speech, windows: [SpeechDuck.Window],
        outcomes: [SpeechDuckPlanner.Outcome], ids: AIShortIDs
    ) -> JSONValue {
        var result: [String: JSONValue] = [
            "track": .string(AITrackName.name(of: voice)),
            "duck_db": .number(depth),
            "lines": .number(Double(speech.lines.count))
        ]
        result["windows"] = .array(windows.prefix(maxWindows).map { .array([AIFormat.seconds($0.from), AIFormat.seconds($0.to)]) })
        if windows.count > maxWindows { result["more_windows"] = .number(Double(windows.count - maxWindows)) }
        var ducked: [JSONValue] = [], unchanged: [JSONValue] = [], inside: [JSONValue] = [], short: [JSONValue] = []
        for outcome in outcomes {
            let entry: [String: JSONValue] = ["id": .string(ids.short(outcome.id)), "track": .string(AITrackName.name(of: outcome.track))]
            switch outcome.result {
            case .ducked(let count, let reached):
                if outcome.changed {
                    ducked.append(.object(entry.merging(["windows": .number(Double(count))]) { $1 }))
                } else {
                    unchanged.append(.string(ids.short(outcome.id)))
                }
                if let reached, reached > depth + shortfall {
                    short.append(.object(entry.merging(["requested_db": .number(depth), "applied_db": AIParameterReport.decibels(reached),
                                                        "reason": "volume_floor"]) { $1 }))
                }
            case .insideLine:
                inside.append(.object(entry))
            case .untouched:
                break
            }
        }
        result["ducked"] = .array(ducked)
        if !unchanged.isEmpty { result["already_at_depth"] = .array(unchanged) }
        if !inside.isEmpty { result["inside_lines"] = .array(inside) }
        if !short.isEmpty { result["adjustments"] = .array(short) }
        var from: [String: JSONValue] = [:]
        if !speech.fromTranscript.isEmpty { from["transcript"] = .array(speech.fromTranscript.map { .string(ids.short($0)) }) }
        if !speech.fromPauses.isEmpty { from["pauses"] = .array(speech.fromPauses.map { .string(ids.short($0)) }) }
        result["lines_from"] = .object(from)
        if !speech.noTranscript.isEmpty { result["no_transcript"] = .array(speech.noTranscript.map { .string(ids.short($0)) }) }
        if !speech.unreadable.isEmpty { result["unreadable"] = .array(speech.unreadable.map { .string(ids.short($0)) }) }
        result["next_step"] = .string(nextStep(speech: speech, inside: !inside.isEmpty))
        return .object(result)
    }

    private static func nextStep(speech: SpeechDuckPlanner.Speech, inside: Bool) -> String {
        var text = "Each dip starts \(seconds(SpeechDuck.attack)) s before a line and is back \(seconds(SpeechDuck.release)) s "
            + "after it; calling again sets it anew (never stacks), duck_others_db 0 takes it out. Check with listen."
        if inside { text += " inside_lines: sounds lying on a line were left alone; move or lower them (edit_clip volume_db)." }
        if !speech.noTranscript.isEmpty {
            text += " no_transcript: that camera sound gave no lines; transcribe it, then call again."
        }
        return text
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
