import Foundation
import SrtFlowMCPKit

// MARK: - The AI's side of saved versions: name the version from before the round, go back with `undo version=`, list them
//
// What it covers: the router's hook after a call that changed the project (`reporting`: the round's first change names the version
// that holds the round's starting point, with a note to tell the user), `undo version=<id>` (`goBack`: one undo step, the state being
// left saved first, the parameter contract's errors), and the versions in `get_status` (`statusJSON`).
// What it doesn't: when versions are saved (AIRound), writing / reading / pruning them (ProjectVersionStore, ProjectVersionFiles).
// Long-term rules: docs/architecture/project-versions.md; the AI contract: docs/architecture/ai-control-mcp.md section 5.

@MainActor
enum AIRoundVersions {
    /// How many versions get_status lists (newest first); undo's error lists every one there is.
    static let listedInStatus = 10

    /// After a call that changed the project (and after a never-saved project got its file, so the starting point has a place):
    /// make sure the round's starting point is saved, and on the round's first change tell the AI what it is called.
    static func reporting(_ project: VideoEditProject, in result: AIToolResult) -> AIToolResult {
        let round = AISession.shared.round(for: project)
        round.settleBeforeVersion()
        guard round.changeCount == 1, let id = round.beforeVersion, case .object(var payload) = result.payload else { return result }
        payload["before_round_version"] = [
            "id": .string(id),
            "note": .string("SkyCut saved the project as \(id) before this round of edits. Tell the user; undo version=\(id) "
                + "puts the whole project back to it in one step.")
        ]
        var reported = result
        reported.payload = .object(payload)
        return reported
    }

    /// `undo version=<id>`: the whole project back to a saved version, as one undo step.
    static func goBack(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let requested = try args.requiredString("version").trimmingCharacters(in: .whitespaces)
        if try args.bool("round") == true || args.has("steps") {
            throw AIToolError("Pass only one of steps, round and version. Nothing was changed.")
        }
        let wentBack: ProjectVersionStore.WentBack
        do {
            wentBack = try await ProjectVersionStore.for(project).goBack(to: requested)
        } catch let error as ProjectVersionStore.GoBackError {
            throw toolError(error, project: project)
        }
        var payload: [String: JSONValue] = ["undone": "version", "version": .string(wentBack.version.id)]
        if let saved = wentBack.savedBefore { payload["saved_before_going_back"] = .string(saved.id) }
        if !wentBack.changed { payload["note"] = "The project already matched this version; nothing changed." }
        return .ok(.object(payload), changed: wentBack.changed)
    }

    /// The parameter contract's error (docs/architecture/mcp-edit-parameters.md): what was asked, what exists, what to use instead.
    private static func toolError(_ error: ProjectVersionStore.GoBackError, project: VideoEditProject) -> AIToolError {
        switch error {
        case .unknown(let requested, let allowed):
            var details: [String: JSONValue] = [
                "status": "invalid_parameter", "parameter": "version", "requested": .string(requested),
                "allowed": .array(allowed.map(JSONValue.string)), "retryable": false
            ]
            let message: String
            if allowed.isEmpty {
                message = "This project has no saved versions yet. Nothing was changed."
                details["suggestion"] = .string("SkyCut saves a version when a round of AI edits changes a saved project; "
                    + "undo round=true reverts the current round.")
            } else {
                let before = AISession.shared.round(for: project).beforeVersion
                let suggested = before.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed[0]
                details["suggested"] = .string(suggested)
                message = "There is no saved version \(requested) for this project; it has \(allowed.joined(separator: ", ")). "
                    + "Nothing was changed."
            }
            return AIToolError(message, details: details)
        case .unreadable(let id, let reason):
            return AIToolError("SkyCut could not read version \(id): \(reason) Nothing was changed.")
        case .projectChanged:
            return AIToolError("The project was replaced while the version was loading. Nothing was changed; check get_status.")
        }
    }

    /// get_status: the project's newest versions and this round's starting point.
    static func statusJSON(_ project: VideoEditProject) -> [String: JSONValue] {
        let store = ProjectVersionStore.for(project)
        store.refresh()
        var info: [String: JSONValue] = [:]
        if !store.versions.isEmpty {
            info["versions"] = .array(store.versions.prefix(listedInStatus).map { version in
                ["id": .string(version.id), "kind": .string(version.kind?.rawValue ?? "saved"),
                 "saved_at": .string(ISO8601DateFormatter().string(from: version.savedAt))]
            })
        }
        if let id = AISession.shared.round(for: project).beforeVersion { info["before_round_version"] = .string(id) }
        return info
    }
}
