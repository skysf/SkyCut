import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// A failed page must retain the existing movie; a missing successful movie must be recovered through document revalidation.
@MainActor func runMotionFailureRecoveryChecks(_ fixture: MotionFixture) async throws {
    try await sourceLaneRaces(root: fixture.root)
    try await staleRenderKeepsUserEdit(fixture)
    let project = fixture.project
    let original = project.state.allClips.first!
    let before = project.state
    fixture.resetUndo()
    AIAccessStore.shared.setMode(.full)
    let broken = #"<script>window.motion={frame(t){throw new Error('G26 verbatim page failure')}};</script>"#
    let failed = try await fixture.completed(fixture.call(["clip_id": .string(original.id.uuidString), "page": .string(broken),
                                                         "duration": 0.5]))
    motionRequire(failed.failed && failed.payload["error"]?.stringValue?.contains("G26 verbatim page failure") == true,
                  "a page's error comes back verbatim through the real AI call")
    let checks = failed.payload["checks"]?.arrayValue ?? []
    motionRequire(checks.count == 6 && checks.contains { $0["name"] == "no_page_errors" && $0["passed"] == false },
                  "rejection reports all six page-check states and the failed page-errors check")
    motionRequire(project.state == before && !project.ownUndoManager.canUndo, "failed rendering changes no clip and creates no undo step")
    motionRequire(FileManager.default.fileExists(atPath: original.sourceURL.path), "failure keeps the preceding checked movie intact")
    AIAccessStore.shared.setMode(.ask)

    motionRequire(project.saveNow(), "the project containing web pages saves before cache recovery")
    let webURLs = Set(project.state.allClips.filter { $0.webMotion != nil }.map(\.sourceURL))
    try FileManager.default.removeItem(at: original.sourceURL)
    fixture.resetUndo()
    project.revalidateMediaLocations()
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
        if webURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }), recoveryFinished(project) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    motionRequire(webURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                  "ordinary document revalidation regenerates deleted web-motion caches")
    motionRequire(recoveryFinished(project)
                  && project.state.clip(with: original.id)?.webMotion?.provenance == original.webMotion?.provenance,
                  "recovery finishes without changing the provenance of identical pixels")
    motionRequire(project.missingMedia.isEmpty && project.state.mediaURLs.isEmpty,
                  "a deleted motion cache never becomes imported missing media")
    motionRequire(!project.ownUndoManager.canUndo, "automatic cache recovery is document repair, not a user undo step")
    motionRequire(project.state.clip(with: original.id)?.id == original.id,
                  "cache recovery keeps the clip's identity")
}

@MainActor func recoveryFinished(_ project: VideoEditProject) -> Bool {
    let key = "recovery:\(project.documentGeneration)"
    guard WebMotionActivity.claim(key) else { return false }
    WebMotionActivity.release(key)
    return true
}

@MainActor private func staleRenderKeepsUserEdit(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    let original = project.state.allClips.first!
    var requested = original.webMotion!
    var parameters = WebMotionParameters.object(requested.parametersJSON)
    parameters["color"] = "#1177ee"
    requested.parametersJSON = try WebMotionParameters.canonical(parameters)
    let key = "\(project.documentGeneration):\(original.id.uuidString)"
    let task = Task { try await WebMotionActions.place(record: requested, replacing: original.id, project: project) }
    let deadline = Date().addingTimeInterval(5)
    var captured = false
    // claim/release is synchronous on the main actor: a successful probe cannot overlap the service's claim.
    // Once the real service owns the key, it has captured the clip and is waiting on its renderer.
    while Date() < deadline {
        if !WebMotionActivity.claim(key) { captured = true; break }
        WebMotionActivity.release(key)
        await Task.yield()
    }
    motionRequire(captured, "the stale-render fixture waits until the real service captured the old clip")
    project.applyDocumentRepair { $0.update(original.id) { $0.opacity = 0.625 } }
    let userState = project.state
    do {
        _ = try await task.value
        motionRequire(false, "an old render must not overwrite a clip the user edited during rendering")
    } catch {
        motionRequire(project.state == userState && project.state.clip(with: original.id)?.opacity == 0.625,
                      "a stale render preserves the user's newer clip state")
    }
}


// Moving only vertically need not change any EditClip field. Async source guards must also remember its lane by UUID.
@MainActor private func sourceLaneRaces(root: URL) async throws {
    let fixture = try MotionFixture(root: root.appendingPathComponent("source-lane-races"))
    let project = fixture.project
    defer { _ = OpenProjects.shared.close(project) }
    let placed = try await WebMotionActions.place(record: fixture.record, at: 2, project: project)
    let original = placed.clip
    project.applyDocumentRepair { state in
        state.overlayTracks[0].clips.append(EditClip(sourceURL: original.sourceURL, sourceDuration: original.sourceDuration,
                                                     timelineStart: 20, info: original.info))
        state.overlayTracks.append(EditLane(clips: []))
    }
    let baseline = project.state
    let sourceID = baseline.overlayTracks[0].id
    let destinationID = baseline.overlayTracks[1].id
    func reset() { project.applyDocumentRepair { $0 = baseline }; fixture.resetUndo() }
    func request(_ title: String) throws -> WebMotionClipRecord {
        var record = original.webMotion!
        var values = WebMotionParameters.object(record.parametersJSON)
        values["text"] = .string(title)
        record.parametersJSON = try WebMotionParameters.canonical(values)
        return record
    }
    let key = "\(project.documentGeneration):\(original.id.uuidString)"

    reset()
    let verticalRecord = try request("VERTICAL CHANGE DURING RENDER")
    let vertical = Task { try await WebMotionActions.place(record: verticalRecord, replacing: original.id,
                                                          preferring: .overlay(0), project: project) }
    try await waitForSourceCapture(key)
    project.applyDocumentRepair { $0.relocateClip(original.id, to: .overlay(1), magnet: false) }
    let moved = project.state
    motionRequire(moved.clip(with: original.id) == original, "vertical-only user move leaves the complete EditClip value unchanged")
    motionRequire(sourceLaneID(of: original.id, in: moved) == destinationID, "the user actually moved the clip to another upper lane")
    do {
        _ = try await vertical.value
        motionRequire(false, "an explicitly targeted old render must refuse after a vertical-only user move")
    } catch { motionRequire(true, "a changed source lane refuses the old render") }
    motionRequire(project.state == moved && sourceLaneID(of: original.id, in: project.state) == destinationID,
                  "stale rendering cannot move the user's clip back to its requested lane")
    motionRequire(!project.ownUndoManager.canUndo, "refusing a stale source lane registers no render undo step")

    // A reorder changes the lane index, but the clip remains in the same lane. That is not a stale source.
    reset()
    let reorderedRecord = try request("SAME LANE REORDERED DURING RENDER")
    let reordered = Task { try await WebMotionActions.place(record: reorderedRecord, replacing: original.id,
                                                           preferring: .overlay(0), project: project) }
    try await waitForSourceCapture(key)
    project.applyDocumentRepair { $0.overlayTracks.swapAt(0, 1) }
    let beforeCommit = project.state
    motionRequire(beforeCommit.clip(with: original.id) == original && sourceLaneID(of: original.id, in: beforeCommit) == sourceID,
                  "reordering keeps the same source lane and unchanged clip value")
    do {
        let result = try await reordered.value
        motionRequire(sourceLaneID(of: result.clip.id, in: project.state) == sourceID,
                      "a same-lane reorder remains allowed and follows the stable requested lane")
        project.ownUndoManager.undo()
        motionRequire(project.state == beforeCommit, "one undo restores the render while preserving the user's lane reorder")
    } catch { motionRequire(false, "a stable source lane must survive reordering: \(error)") }

    // Hiding that same source lane during an explicit relocation is also a newer user decision.
    reset()
    let hiddenRecord = try request("SOURCE HIDDEN DURING RENDER")
    let hidden = Task { try await WebMotionActions.place(record: hiddenRecord, replacing: original.id,
                                                        preferring: .overlay(0), project: project) }
    try await waitForSourceCapture(key)
    project.applyDocumentRepair { $0.overlayTracks[0].isHidden = true }
    let hiddenState = project.state
    motionRequire(hiddenState.clip(with: original.id) == original, "hiding the lane also leaves the EditClip value unchanged")
    do {
        _ = try await hidden.value
        motionRequire(false, "an explicitly targeted render must refuse after the user hides its source lane")
    } catch { motionRequire(true, "changed source visibility refuses the old render") }
    motionRequire(project.state == hiddenState && !project.ownUndoManager.canUndo,
                  "a stale render cannot move a hidden source onto a visible lane or add undo")

    // answerWithin=0 returns the job before its MainActor task starts. Capture must begin when the request is parsed.
    reset()
    let previousDeadline = AIMotionTool.answerWithin
    AIMotionTool.answerWithin = 0
    defer { AIMotionTool.answerWithin = previousDeadline }
    let reply = try await fixture.call(["clip_id": .string(original.id.uuidString), "track": "V2",
                                        "parameters": ["text": "VERTICAL MOVE BEFORE JOB START"]])
    let beforeJobStarted = WebMotionActivity.claim(key)
    if beforeJobStarted { WebMotionActivity.release(key) }
    motionRequire(beforeJobStarted && reply.payload["job_id"] != nil,
                  "the pre-start fixture returns the job before the service captures its source lane")
    project.applyDocumentRepair { $0.relocateClip(original.id, to: .overlay(1), magnet: false) }
    let beforeJob = project.state
    motionRequire(beforeJob.clip(with: original.id) == original, "the pre-start vertical move keeps the request's expected clip equal")
    let answer = try await fixture.completed(reply)
    motionRequire(answer.failed, "a request whose source lane changed before its job starts is refused")
    motionRequire(project.state == beforeJob && sourceLaneID(of: original.id, in: project.state) == destinationID
                    && !project.ownUndoManager.canUndo,
                  "pre-start rejection preserves the user's lane without applying an edit")


    // Existing explicit destinations are identities too: the old index must never silently select a different lane.
    for mode in ["reordered", "removed", "hidden"] {
        reset()
        let destinationReply = try await fixture.call(["clip_id": .string(original.id.uuidString), "track": "V3",
                                                       "parameters": ["text": .string("DESTINATION " + mode)]])
        let notStarted = WebMotionActivity.claim(key)
        if notStarted { WebMotionActivity.release(key) }
        motionRequire(notStarted && destinationReply.payload["job_id"] != nil,
                      "destination \(mode): the fixture changes tracks before the real job starts")
        project.applyDocumentRepair { state in
            switch mode {
            case "reordered": state.overlayTracks.swapAt(0, 1)
            case "removed":
                state.overlayTracks.remove(at: 1)
                state.overlayTracks.append(EditLane(clips: []))
            default: state.overlayTracks[1].isHidden = true
            }
        }
        let destinationState = project.state
        let lanesBefore = Set(destinationState.overlayTracks.map(\.id))
        motionRequire(destinationState.clip(with: original.id) == original
                        && sourceLaneID(of: original.id, in: destinationState) == sourceID,
                      "destination \(mode): the source clip and its lane identity are unchanged")
        let destinationAnswer = try await fixture.completed(destinationReply)
        motionRequire(!destinationAnswer.failed, "destination \(mode): a stable source can finish rendering")
        let actualLane = sourceLaneID(of: original.id, in: project.state)
        if mode == "reordered" {
            motionRequire(actualLane == destinationID,
                          "pre-start reordering resolves the original requested destination UUID instead of its old index")
        } else {
            motionRequire(actualLane.map { !lanesBefore.contains($0) } == true,
                          "destination \(mode): the missing or hidden requested lane creates a new upper lane")
        }
    }
}

@MainActor private func waitForSourceCapture(_ key: String) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if !WebMotionActivity.claim(key) { return }
        WebMotionActivity.release(key)
        await Task.yield()
    }
    throw AIToolError("The real motion service did not capture its source before the lane-race deadline")
}

private func sourceLaneID(of id: UUID, in state: TimelineState) -> UUID? {
    guard case .overlay(let index)? = state.location(of: id)?.track, state.overlayTracks.indices.contains(index) else { return nil }
    return state.overlayTracks[index].id
}
