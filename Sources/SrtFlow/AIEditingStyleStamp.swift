import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - The film records the editing style the AI followed (SS5 plan 5.5, FL-15)
//
// What this owns: the style each AI session last read for each project (`recipes` with an id: a Sky Studio style, a preset or the
// user's own; never the shared rules alone), and putting it into that project's TimelineState in the session's next change to the
// project. It is stamped inside the change's own `perform` (VideoEditProject), so it is the same undo step as the change and no
// read-only tool ever writes the user's file; a call that changes nothing, another session's call, a user's edit or a later
// asynchronous landing never stamp. A Sky Studio style's record pins its version (AIRecipeSkyStudio reads that version for this
// film again); presets and the user's own are recorded with SkyCut's version and the text's checksum, never pinned.
// Also what get_timeline says about it (`report`: the record and, for a pinned style, a newer version Sky Studio lists).
// Not this file: the record's shape (EditingStyleRecord, SrtFlowCore), reading a style (AIRecipeSkyStudio).

@MainActor
enum AIEditingStyleStamp {
    private struct ReadKey: Hashable {
        var session: String?
        var project: String
    }

    private static var reads: [ReadKey: EditingStyleRecord] = [:]

    /// `recipes` read this style for `project` in this session (AICallContext.current?.session).
    static func noteRead(_ record: EditingStyleRecord, session: String?, project: String) {
        reads[ReadKey(session: session, project: project)] = record
    }

    /// `VideoEditProject.perform`'s final state for a change that changes something: during an AI call on `project` whose session
    /// read a style for it, the state carries that style's record (the same undo step as the change).
    static func stamped(_ next: TimelineState, project: String) -> TimelineState {
        guard let context = AICallContext.current, context.project == project,
              let record = reads[ReadKey(session: context.session, project: project)], next.editingStyle != record else { return next }
        var stamped = next
        stamped.editingStyle = record
        return stamped
    }

    /// get_timeline's `editing_style`: what the film was cut with; `newer_version` when a pinned Sky Studio style has a newer one
    /// in the list on this Mac (asked by recipes, never here).
    static func report(_ state: TimelineState) -> JSONValue? {
        guard let record = state.editingStyle else { return nil }
        var object: [String: JSONValue] = ["id": .string(record.id), "source": .string(record.source), "sha256": .string(record.sha256)]
        if let version = record.version { object["version"] = .string(version) }
        if let skycut = record.skycutVersion { object["skycut_version"] = .string(skycut) }
        if record.isPinned, let newest = SkyStudioStyles.shared.listing.styles.first(where: { $0.id == record.id })?.version,
           newest != record.version {
            object["newer_version"] = .string(newest)
        }
        return .object(object)
    }
}
