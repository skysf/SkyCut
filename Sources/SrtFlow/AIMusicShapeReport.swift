import Foundation
import SrtFlowMCPKit

// MARK: - What the AI reads about a piece of music: accents, stops, where it ends (pure)
//
// What this owns: a song's shape (MusicShape, source seconds) → the fields listen beats=true adds next to the beats, for the
// part that is asked for (a clip's window, a file's source_in / source_out), with times through the caller's mapping (a clip's
// timeline seconds, a file's own seconds), the same way AIBeats.json lists the beats (MCP-43, 2026-11-18):
// - accents: every audible accent as [second, strength], in time order (strength: how far it stands out, about 3 barely,
//   10 and more a big hit; it compares within one piece). At most `maxAccents`: past that the weakest go, more_accents counts them.
// - strongest_accents: the seconds of the five strongest, strongest first.
// - stops: [from, to] where the piece stops by itself and comes back, cut to the window.
// - ends_at: where the piece's own sound is over, when that falls inside the window.
// And the strongest accent of a window, add_clips' default hit (AIClipHit).
// What it does not own: the measuring (MusicShape), reading and caching (AIBeats).

enum AIMusicShapeReport {
    static let maxAccents = 240
    static let strongestCount = 5

    static func json(
        _ shape: MusicShape.Analysis, sourceFrom: Double, sourceTo: Double, timeline: (Double) -> Double
    ) -> [String: JSONValue] {
        let inside = accents(shape, from: sourceFrom, to: sourceTo)
        let kept = inside.sorted { $0.strength > $1.strength }.prefix(maxAccents)
        func second(_ time: Double) -> JSONValue { .number((timeline(time) * 100).rounded() / 100) }
        var object: [String: JSONValue] = [
            "accents": .array(kept.sorted { $0.time < $1.time }.map { .array([second($0.time), .number(($0.strength * 10).rounded() / 10)]) }),
            "strongest_accents": .array(kept.prefix(strongestCount).map { second($0.time) }),
            "stops": .array(shape.stops.compactMap { stop -> JSONValue? in
                let from = max(stop.from, sourceFrom)
                let to = min(stop.to, sourceTo)
                return to - from >= MusicLevels.step - 1e-9 ? .array([second(from), second(to)]) : nil
            })
        ]
        if inside.count > maxAccents { object["more_accents"] = .number(Double(inside.count - maxAccents)) }
        if let end = shape.end, end > sourceFrom, end <= sourceTo + 0.001 { object["ends_at"] = second(end) }
        return object
    }

    /// The strongest accent in source [from, to): what hit_at lands when no hit is given.
    static func strongest(_ shape: MusicShape.Analysis, from: Double, to: Double) -> MusicShape.Accent? {
        accents(shape, from: from, to: to).max { $0.strength < $1.strength }
    }

    private static func accents(_ shape: MusicShape.Analysis, from: Double, to: Double) -> [MusicShape.Accent] {
        shape.accents.filter { $0.time >= from - 0.001 && $0.time < to }
    }
}
