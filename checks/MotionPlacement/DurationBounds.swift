import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// An over-long motion duration or frame rate is refused with a readable error before any job, renderer, edit or undo step:
// set_motion's top-level duration and its reserved parameters.duration, and records read back from a project file (opening
// it starts cache recovery; set_motion, template reuse and the inspector read the same record). Each of these quit SkyCut
// on an Int overflow before the fix (docs/bugfixes/2026-11-19-web-motion-huge-duration-quits-app.md).
@MainActor func runMotionDurationBoundsChecks(_ fixture: MotionFixture) async throws {
    try await aiCallsRefuseHugeDurations(fixture)
    try await storedRecordsRefuseHugeTiming(root: fixture.root.appendingPathComponent("huge-timing"))
}

private let durationProblem = "The duration must be more than 0 and at most 60 seconds."
private let rateProblem = "The frame rate must be 1–120."

@MainActor private func aiCallsRefuseHugeDurations(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    guard let id = project.state.allClips.first(where: { $0.webMotion != nil })?.id.uuidString else {
        throw AIToolError("The duration bounds checks need a placed web-motion clip")
    }
    fixture.resetUndo()
    let before = project.state
    // Full access, so a valid new page would render at once: the refusal must come from the bounds, not from approval.
    AIAccessStore.shared.setMode(.full)
    defer { AIAccessStore.shared.setMode(.ask) }
    let calls: [(String, [String: JSONValue])] = [
        ("top-level duration", ["clip_id": .string(id), "duration": 1e20]),
        ("reserved parameters.duration", ["clip_id": .string(id), "parameters": ["duration": 1e20]]),
        ("a new page's duration", ["page": .string(MotionFixture.page + "\n<!-- huge duration -->"), "duration": 1e20, "at": 1]),
        ("a duration written as text", ["clip_id": .string(id), "duration": "1e300"]),
    ]
    try await withRendererSentinel(root: fixture.root) { marker in
        for (label, values) in calls {
            let message = await refusal { try await fixture.call(values) }
            motionRequire(message?.contains(durationProblem) == true, "set_motion \(label) 10^20 s is refused in plain words: \(message ?? "accepted")")
            motionRequire(project.state == before && !project.ownUndoManager.canUndo, "set_motion \(label): no edit and no undo step")
        }
        motionRequire(AIJobs.shared.running.filter { $0.kind == .motion }.isEmpty, "huge durations start no motion job")
        motionRequire(!FileManager.default.fileExists(atPath: marker.path), "huge durations never start the renderer")
    }
}

/// A project file whose web-motion records were damaged outside SkyCut: an over-long duration, and a frame rate whose frame
/// count overflows Int. Their movies are missing, so opening the file starts recovery at once.
@MainActor private func storedRecordsRefuseHugeTiming(root: URL) async throws {
    let writer = try MotionFixture(root: root)
    func damaged(_ name: String, at start: Double, duration: Double, fps: Int) throws -> EditClip {
        var record = writer.record
        record.duration = duration
        record.fps = fps
        var clip = EditClip(sourceURL: root.appendingPathComponent("SkyCut/Motion/\(name).mov"), sourceDuration: 0.5, timelineStart: start)
        clip.webMotion = try WebMotionParameters.normalized(record)
        return clip
    }
    let long = try damaged("damaged-long", at: 0, duration: 1e20, fps: writer.record.fps)
    let fast = try damaged("damaged-fast", at: 2, duration: 3, fps: Int.max)
    let longRecord = long.webMotion, fastRecord = fast.webMotion
    writer.project.applyDocumentRepair { $0.overlayTracks.append(EditLane(clips: [long, fast])) }
    let url = try requireDocumentURL(writer.project)
    motionRequire(writer.project.saveNow(), "the damaged-record project saves")
    motionRequire(OpenProjects.shared.close(writer.project), "the damaged-record project closes before it is opened again")

    try await withRendererSentinel(root: root) { marker in
        guard let project = await OpenProjects.shared.open(url, placement: .background) else {
            throw AIToolError(OpenProjects.shared.failure ?? "The damaged-record project did not open")
        }
        defer { _ = OpenProjects.shared.close(project) }
        project.ownUndoManager.groupsByEvent = false
        AISession.shared.setViewMode(.background, for: project)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !recoveryFinished(project) { try await Task.sleep(for: .milliseconds(50)) }
        let opened = project.state
        motionRequire(recoveryFinished(project) && opened.clip(with: long.id)?.webMotion == longRecord
                        && opened.clip(with: fast.id)?.webMotion == fastRecord,
                      "opening the file keeps both damaged records and ends recovery")
        let notice = project.notice ?? ""
        motionRequire((notice.contains(durationProblem) || notice.contains(rateProblem)) && !notice.contains("AIToolError"),
                      "recovery says in plain words why the motion cannot be rebuilt: \(notice)")

        let context = AICallContext(session: "motion-duration-bounds", client: "MotionPlacementCheck",
                                    project: project.shortID, stopsWith: project.shortID)
        func call(_ values: [String: JSONValue]) async throws -> AIToolResult {
            try await AICallContext.$current.withValue(context) { try await AIMotionTool.set(AIToolArguments(.object(values)), project) }
        }
        let aiCalls: [(String, [String: JSONValue], String)] = [
            ("a parameter edit of the long record", ["clip_id": .string(long.id.uuidString), "parameters": ["text": "EDIT"]], durationProblem),
            ("a parameter edit of the fast record", ["clip_id": .string(fast.id.uuidString), "parameters": ["text": "EDIT"]], rateProblem),
            ("template reuse of the long record", ["template": .string("project:\(long.id.uuidString.lowercased())"), "at": 6], durationProblem),
        ]
        for (label, values, expected) in aiCalls {
            let message = await refusal { try await call(values) }
            motionRequire(message?.contains(expected) == true, "set_motion \(label) is refused in plain words: \(message ?? "accepted")")
        }
        let inspector = WebMotionEditorModel(project: project, clip: opened.clip(with: fast.id)!)
        let rendered = await inspector.render()
        motionRequire(!rendered && inspector.error?.contains(rateProblem) == true,
                      "the inspector refuses to re-render the fast record: \(inspector.error ?? "rendered")")
        let card = WebMotionPresetModel(project: project)
        let added = await card.add(WebMotionPresetRequest(templateID: "project:\(long.id.uuidString.lowercased())", at: 6, project: project))
        motionRequire(!added && card.error?.contains(durationProblem) == true,
                      "adding the long record's card is refused: \(card.error ?? "added")")
        motionRequire(project.state == opened && !project.ownUndoManager.canUndo, "the damaged records change nothing and add no undo step")
        motionRequire(AIJobs.shared.running.filter { $0.kind == .motion }.isEmpty && !FileManager.default.fileExists(atPath: marker.path),
                      "opening and using the damaged records never starts a motion job or the renderer")
    }
}

/// The refusal's text, or nil when the call was accepted. AI calls throw `AIToolError`; a reply marked as an error counts too.
@MainActor private func refusal(_ body: () async throws -> AIToolResult) async -> String? {
    do {
        let reply = try await body()
        return reply.isError ? (reply.payload["error"]?.stringValue ?? "\(reply.payload)") : nil
    } catch let error as AIToolError {
        return error.message
    } catch {
        return WebMotionUIError.message(error)
    }
}

@MainActor private func requireDocumentURL(_ project: VideoEditProject) throws -> URL {
    guard let url = project.documentURL else { throw AIToolError("The damaged-record fixture has no project file") }
    return url
}
