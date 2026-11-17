import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// A failed page must retain the existing movie; a missing successful movie must be recovered through document revalidation.
@MainActor func runMotionFailureRecoveryChecks(_ fixture: MotionFixture) async throws {
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

@MainActor private func recoveryFinished(_ project: VideoEditProject) -> Bool {
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
