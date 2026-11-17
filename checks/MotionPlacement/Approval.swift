import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Approval must happen before a task or helper starts, with tokens bound to the exact request.
@MainActor func runMotionApprovalChecks(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    AIAccessStore.shared.setMode(.ask)
    let page = MotionFixture.page + "\n<!-- newly written page -->"
    var values: [String: JSONValue] = ["page": .string(page), "name": "Approved page", "parameters": ["text": "APPROVED", "color": "#44bb99"],
                                     "duration": 0.5, "hit": 0.25, "at": 5]
    let before = project.state
    let running = AIJobs.shared.running.map(\.id)
    let files = try FileManager.default.contentsOfDirectory(atPath: WebMotionActions.cacheDirectory(for: project).path).sorted()
    fixture.resetUndo()
    let first = try await fixture.call(values)
    motionRequire(first.payload["status"] == "needs_confirmation" && !first.isError, "request-approval mode asks before new page code runs")
    guard let token = first.payload["confirm_token"]?.stringValue else { throw AIToolError("New-page approval returned no token") }
    let repeated = try await fixture.call(values)
    motionRequire(repeated.payload["confirm_token"]?.stringValue == token, "the same pending request returns the same approval token")
    var changed = values
    changed["parameters"] = ["text": "CHANGED", "color": "#44bb99"]
    changed["confirm_token"] = .string(token)
    let refused = try await fixture.call(changed)
    motionRequire(refused.payload["status"] == "needs_confirmation" && refused.payload["confirm_token_refused"] != nil,
                  "approval for one parameter set cannot authorize another")
    motionRequire(project.state == before && !project.ownUndoManager.canUndo && AIJobs.shared.running.map(\.id) == running,
                  "asking, retrying and refusing a token do not edit or start a motion task")
    motionRequire(try FileManager.default.contentsOfDirectory(atPath: WebMotionActions.cacheDirectory(for: project).path).sorted() == files,
                  "no cache file is created before approval")

    values["confirm_token"] = .string(token)
    AIMotionTool.answerWithin = 0
    let accepted = try await fixture.completed(fixture.call(values))
    motionRequire(!accepted.failed && project.state.allClips.count == before.allClips.count + 1,
                  "the exact approved call renders and adds one clip")
    let approved = project.state.allClips.first { $0.webMotion?.page == page }!
    motionRequire(approved.webMotion?.width == 320 && approved.webMotion?.height == 180,
                  "an AI page uses the actual project's 320 by 180 canvas")
    project.ownUndoManager.undo()
    motionRequire(project.state == before && !project.ownUndoManager.canUndo, "one undo removes the accepted page placement")
    project.ownUndoManager.redo()

    let parameterChange = try await fixture.completed(fixture.call(["clip_id": .string(approved.id.uuidString), "parameters": ["text": "REVISED"]]))
    motionRequire(!parameterChange.failed && parameterChange.payload["status"] != "needs_confirmation",
                  "parameters of an approved stored page re-render without another question")

    AIAccessStore.shared.setMode(.full)
    let full = try await fixture.completed(fixture.call(["page": .string(MotionFixture.page + "\n<!-- full access page -->"),
                                                       "parameters": ["text": "FULL ACCESS", "color": "#bb7799"], "duration": 0.5, "at": 6]))
    motionRequire(!full.failed && full.payload["clip_id"] != nil && full.payload["status"] != "needs_confirmation",
                  "full access renders a new page without asking")
    AIAccessStore.shared.setMode(.ask)
    AIMotionTool.answerWithin = 25
    try await rejectedBeforeRender(fixture)
}

@MainActor private func rejectedBeforeRender(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    let id = project.state.allClips.first!.id.uuidString
    let before = project.state
    let invalid: [[String: JSONValue]] = [
        ["clip_id": .string(id), "track": "V1"],
        ["clip_id": .string(id), "at": 1, "hit_at": 2],
        ["clip_id": .string(id), "hit": 0.4, "hit_at": 0.1],
        ["clip_id": .string(id), "duration": 0],
        ["clip_id": .string(id), "parameters": "bad object"]
    ]
    for (index, values) in invalid.enumerated() {
        do {
            _ = try await fixture.call(values)
            motionRequire(false, "invalid request \(index + 1) must be refused before rendering")
        } catch {
            motionRequire(project.state == before, "invalid request \(index + 1) changes no timeline state")
        }
    }
    motionRequire(AIJobs.shared.running.filter { $0.kind == .motion }.isEmpty, "invalid requests leave no render job running")
}
