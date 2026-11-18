import Foundation
import SrtFlowMCPKit

// MARK: - add_clips: land one source second (the hit) on one timeline second (hit_at)
//
// What this owns (MCP-43, 2026-11-18): where a clip starts, and from which source second, so that its hit lands on hit_at, for
// every source add_clips takes. The hit is `hit` when the AI names it (a source second, "9.66 of the music on 7.30"); otherwise
// a made sound effect's preset hit, a library sound effect's measured hit, and for a file or library music the strongest accent
// in the part of it the clip uses (AIBeats' whole-song analysis, AIMusicShapeReport.strongest: "the strongest hit on 7.30").
// The rule (`placement`, the only copy; AISoundEffectRequest.placement delegates here): start = hit_at − (hit − source_in);
// before 0:00 the clip starts later in its source by the shortfall, and the hit still lands on hit_at.
// What it does not own: reading clips[i] and the reply (AITimelineTools.addClips), the source window rule (AIClipSourceWindow,
// which still checks the moved source_in), the measuring (MusicShape), where the clip lands on V1 (a lifted track or the magnet
// can move it; the reply's hit_at is read back from the clip).

@MainActor
enum AIClipHit {
    struct Landing: Equatable {
        var start: Double
        var sourceIn: Double
        /// The source second that lands on hit_at.
        var hit: Double
        /// The source_in the AI asked for (nil = none), when the shortfall moved it later.
        var askedSourceIn: Double?
    }

    /// The reason an adjustment gives when hit_at set the start, or moved an asked source_in.
    static let reason = "hit_lands_on_hit_at"

    nonisolated static func placement(hitAt: Double, hit: Double, sourceIn: Double) -> (start: Double, sourceIn: Double) {
        let start = hitAt - (hit - sourceIn)
        return start >= 0 ? (start, sourceIn) : (0, sourceIn - start)
    }

    /// Lands `hit` (or `known`, or the strongest accent of `url` in [source_in, source_out)) on `hitAt`. `duration` is the
    /// source's length; the moved window is still checked by the caller's trim.
    static func land(
        hitAt: Double, hit: Double?, known: Double?, url: URL?, name: String, sourceIn: Double?, sourceOut: Double?,
        duration: Double, index: Int
    ) async throws -> Landing {
        let from = sourceIn ?? 0
        let to = min(sourceOut ?? duration, duration)
        var chosen = hit ?? known
        if chosen == nil {
            chosen = try await strongestAccent(url, name: name, from: from, to: to, index: index)
        }
        let second = chosen ?? from
        // The window's ends with the source boundary tolerance: a hit may be the very end (suction and riser peak at their end,
        // and a made file's hit can sit a millisecond past its encoded length).
        try AIBatchItems.entry("clips", index) {
            guard second.isFinite, second >= from - AIClipEdit.tolerance, second <= to + AIClipEdit.tolerance else {
                throw AIEditLimits.invalid("hit", second, minimum: from, maximum: max(from, to))
            }
        }
        let placed = placement(hitAt: hitAt, hit: second, sourceIn: from)
        let moved = sourceIn != nil && abs(placed.sourceIn - from) > 1e-9
        return Landing(start: placed.start, sourceIn: placed.sourceIn, hit: second, askedSourceIn: moved ? sourceIn : nil)
    }

    private static func strongestAccent(_ url: URL?, name: String, from: Double, to: Double, index: Int) async throws -> Double {
        let noAccent = AIToolError("clips[\(index)]: \(name) has no clear accent between \(seconds(from)) and \(seconds(to)) s; "
            + "give hit (the source second to land on hit_at).")
        guard let url else { throw noAccent }
        let music: AIBeats.Music
        do { music = try await AIBeats.music(of: url, from: from, to: to) } catch {
            throw AIToolError("clips[\(index)]: SkyCut could not find an accent in \(name) (\(error.localizedDescription)); give hit.")
        }
        guard let accent = AIMusicShapeReport.strongest(music.shape, from: from, to: to) else { throw noAccent }
        return accent.time
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.2f", value) }

    // MARK: The reply

    /// hit_at and hit in a clip's reply, read back from where the clip landed. An adjustment of start or source_in that the hit
    /// caused says so (AIParameterReport only knows its generic reasons).
    static func report(_ entry: inout [String: JSONValue], landing: Landing, clip: EditClip) {
        entry["hit_at"] = AIFormat.seconds(clip.timelineStart + landing.hit - clip.sourceStart)
        entry["hit"] = AIFormat.seconds(landing.hit)
        guard let adjustments = entry["adjustments"]?.arrayValue else { return }
        entry["adjustments"] = .array(adjustments.map { adjustment in
            guard case .object(var fields) = adjustment, let parameter = fields["parameter"]?.stringValue,
                  parameter == "start" || (parameter == "source_in" && landing.askedSourceIn != nil) else { return adjustment }
            fields["reason"] = .string(reason)
            return .object(fields)
        })
    }
}
