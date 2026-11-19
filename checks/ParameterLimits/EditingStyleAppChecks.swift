import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The film records the editing style the AI followed (SS5 plan 5.5, FL-15; docs/architecture/ai-control-mcp.md item 32) through the
// real App objects: after a session read a style for a project, that session's next real change (edit_clip) carries the record in
// the same undo step, so one undo takes both back; another session's change, a change outside an AI call and a call that changes
// nothing record nothing; get_timeline reports editing_style. No Sky Studio, keys or files involved.
@MainActor enum EditingStyleAppChecks {
    static func run(_ fixture: ParameterFixture, require: (Bool, String) -> Void) async throws {
        fixture.reset()
        let project = fixture.project
        let undo = project.effectiveUndoManager!
        let record = EditingStyleRecord(id: "film-trailer", source: "sky_studio", version: "1.0", sha256: String(repeating: "a", count: 64))
        AIEditingStyleStamp.noteRead(record, session: "style-session", project: project.shortID)
        let reader = AICallContext(session: "style-session", client: "AI", project: project.shortID, stopsWith: project.shortID)
        let other = AICallContext(session: "another-session", client: "AI", project: project.shortID, stopsWith: project.shortID)

        _ = try await AICallContext.$current.withValue(other) { try await fixture.edit(["opacity": 0.5]) }
        require(project.state != fixture.before && project.state.editingStyle == nil, "another session's change records nothing")
        fixture.reset()
        project.perform { $0.minimumDuration = 30 }
        require(project.state.minimumDuration == 30 && project.state.editingStyle == nil, "a change outside an AI call records nothing")
        fixture.reset()
        _ = AICallContext.$current.withValue(reader) { project.perform { _ in } }
        require(project.state == fixture.before && !undo.canUndo, "a call that changes nothing records nothing")

        _ = try await AICallContext.$current.withValue(reader) { try await fixture.edit(["opacity": 0.5]) }
        require(project.state.editingStyle == record, "the session's next change records the style it read")
        let timeline = AITimelineTools.timeline(project).payload
        require(timeline["editing_style"]?["id"]?.stringValue == "film-trailer" && timeline["editing_style"]?["version"]?.stringValue == "1.0",
                "get_timeline reports editing_style with its version")
        undo.undo()
        require(project.state == fixture.before && !undo.canUndo, "one undo takes the change and the record back together")
        fixture.reset()
        print("PASS: a film records the editing style in the AI's change, as one undo step")
    }
}
