import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Saved versions keep generated source without copying large movies into history. This fixture uses the real helper,
// registry-owned headless projects and ProjectVersionStore; all projects, movies and version files stay under test roots.
@MainActor
func runMotionVersionChecks(_ root: URL) async throws {
    let manager = FileManager.default
    let versionsRoot = ProjectVersionStore.root.resolvingSymlinksInPath().path
    let temporary = manager.temporaryDirectory.resolvingSymlinksInPath().path + "/"
    let fixtureRoot = root.resolvingSymlinksInPath().path + "/"
    guard versionsRoot.hasPrefix(temporary) || versionsRoot.hasPrefix(fixtureRoot) || versionsRoot.hasPrefix("/private/tmp/") else {
        throw AIToolError("Motion version checks require an isolated temporary versions root")
    }
    try await laneOnlyMoveVersions(root)
    let fixture = try MotionFixture(root: root.appendingPathComponent("version-motion"))
    let project = fixture.project
    var historyFolder: URL?
    defer {
        _ = OpenProjects.shared.close(project)
        if let historyFolder { try? manager.removeItem(at: historyFolder) }
    }
    motionRequire(OpenProjects.shared.isHeadless(project), "motion versions run without a preview window")
    let placed = try await WebMotionActions.place(record: fixture.record, at: 2, project: project)
    motionRequire(project.saveNow(), "the original motion project saves normally before its first version")
    let id = placed.clip.id
    let firstMovie = placed.clip.sourceURL
    var store = ProjectVersionStore.for(project)
    historyFolder = store.folder
    guard let folder = historyFolder, let first = store.save(project.state, kind: .afterRound).version else {
        throw AIToolError("The first motion version was not saved")
    }
    motionRequire(first.id == "v1", "motion history starts with v1")
    motionRequire(!manager.fileExists(atPath: folder.appendingPathComponent("SkyCut/Motion").path),
                  "version snapshots do not copy rendered movies into the history folder")
    let saved = try VideoEditProjectIO.makeDecoder().decode(VideoEditProjectFile.self, from: Data(contentsOf: first.url))
    motionRequire(saved.timeline.clip(with: id)?.sourceURL == firstMovie,
                  "a version retains the real project cache reference instead of rewriting it beside history")
    motionRequire(ProjectVersionFiles.canonicalTimeline(ofFile: first.url) == ProjectVersionFiles.canonical(project.state),
                  "file and in-memory canonical comparison use the same motion normalization")
    motionRequire(store.save(project.state, kind: .afterRound) == .unchanged(first),
                  "the same web-motion timeline creates no extra version")

    // Changing only a disposable cache location cannot count as an edit, including after the store lost its in-memory cache.
    let relocated = fixture.root.appendingPathComponent("another-cache-location.mov")
    try manager.copyItem(at: firstMovie, to: relocated)
    project.applyDocumentRepair { $0.update(id) { $0.sourceURL = relocated } }
    motionRequire(ProjectVersionFiles.canonical(saved.timeline) == ProjectVersionFiles.canonical(project.state),
                  "relocated generated movies compare by their source fingerprint")
    ProjectVersionStore.forget(project)
    store = ProjectVersionStore.for(project)
    motionRequire(store.save(project.state, kind: .afterRound) == .unchanged(first),
                  "after a restart a relocated web cache still reuses the newest version")
    ordinaryMediaReferencesStayExact(project.state, root: fixture.root)

    // The real async AI call must report the version before this round after it has saved its edit, just like the router.
    let round = AISession.shared.round(for: project)
    round.beginIfNeeded(project: project)
    let reply = try await fixture.call([
        "clip_id": .string(AIShortIDs(state: project.state).short(id)),
        "parameters": ["text": "VERSION TWO"]
    ])
    let answer = try await fixture.completed(reply)
    motionRequire(!answer.failed, "the version fixture changes a parameter through the real set_motion call")
    motionRequire(answer.payload["before_round_version"]?["id"] == "v1",
                  "async set_motion names the saved version from before its round")
    round.finishRound()
    store.refresh()
    motionRequire(store.versions.map(\.id) == ["v2", "v1"], "the changed motion round saves its end once as v2")
    guard let second = store.versions.first else { throw AIToolError("The changed motion round has no end version") }
    motionRequire(store.save(project.state, kind: .afterRound) == .unchanged(second),
                  "saving the completed motion round again is a no-op")

    let edited = project.state
    fixture.resetUndo()
    let restored = try await store.goBack(to: first.id)
    motionRequire(restored.changed && motionText(project.state, id: id) == "EXPEDITION",
                  "going back restores the stored page parameters")
    motionRequire(project.ownUndoManager.canUndo, "restoring a motion version registers one undo step")
    project.ownUndoManager.undo()
    motionRequire(ProjectVersionFiles.canonical(project.state) == ProjectVersionFiles.canonical(edited),
                  "one undo returns from the version to the edited motion")
    motionRequire(!project.ownUndoManager.canUndo, "version restore was exactly one undo step")
    project.ownUndoManager.redo()
    motionRequire(motionText(project.state, id: id) == "EXPEDITION", "redo returns to the older motion version")
    fixture.resetUndo()
    let count = store.versions.count
    let same = try await store.goBack(to: first.id)
    motionRequire(!same.changed && store.versions.count == count && !project.ownUndoManager.canUndo,
                  "going back to the same motion version writes nothing and registers no undo")
    project.applyDocumentRepair { $0.update(id) { $0.sourceURL = relocated } }
    let sameAfterRelocation = try await store.goBack(to: first.id)
    motionRequire(!sameAfterRelocation.changed && !project.ownUndoManager.canUndo,
                  "cache relocation alone is not a different version to restore")

    // Missing caches are restored even when the project has no editor and scheduleRebuild does no preview work.
    _ = try await store.goBack(to: second.id)
    try manager.removeItem(at: firstMovie)
    fixture.resetUndo()
    let missing = try await store.goBack(to: first.id)
    motionRequire(missing.changed, "a headless project restores a version whose rendered movie was deleted")
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let clip = project.state.clip(with: id), manager.fileExists(atPath: clip.sourceURL.path),
           clip.sourceURL.deletingLastPathComponent() == WebMotionProjectFiles.directory(for: project.documentURL!) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let recovered = project.state.clip(with: id)
    motionRequire(recovered.map { manager.fileExists(atPath: $0.sourceURL.path) } == true,
                  "version restore automatically regenerates its missing movie in the background")
    motionRequire(recovered?.sourceURL.deletingLastPathComponent() == WebMotionProjectFiles.directory(for: project.documentURL!),
                  "recovered version movie belongs beside the actual project, outside the history folder")
    motionRequire(ProjectVersionFiles.canonical(project.state) == ProjectVersionFiles.canonical(saved.timeline),
                  "cache recovery preserves the saved version identity, including its original render timestamp")
    motionRequire(!manager.fileExists(atPath: folder.appendingPathComponent("SkyCut/Motion").path),
                  "restores and later version saves never leave large movie copies in history")
    try VideoEditExportGraph.requireMotionCaches(project.state)
}

@MainActor
private func ordinaryMediaReferencesStayExact(_ state: TimelineState, root: URL) {
    var one = state
    one.mainClips = [EditClip(sourceURL: root.appendingPathComponent("ordinary-one.mov"), sourceDuration: 1)]
    var two = one
    two.mainClips[0].sourceURL = root.appendingPathComponent("ordinary-two.mov")
    motionRequire(ProjectVersionFiles.canonical(one) != ProjectVersionFiles.canonical(two),
                  "version comparison keeps ordinary imported media locations exact")
}

@MainActor
private func motionText(_ state: TimelineState, id: UUID) -> String? {
    state.clip(with: id)?.webMotion.flatMap { WebMotionParameters.object($0.parametersJSON)["text"]?.stringValue }
}


// A lane is outside EditClip: a cache-hit move with no parameter or time change still belongs to the AI round's history.
@MainActor
private func laneOnlyMoveVersions(_ root: URL) async throws {
    let fixture = try MotionFixture(root: root.appendingPathComponent("lane-only-version-motion"))
    let project = fixture.project
    var historyFolder: URL?
    defer {
        _ = OpenProjects.shared.close(project)
        if let historyFolder { try? FileManager.default.removeItem(at: historyFolder) }
    }
    let placed = try await WebMotionActions.place(record: fixture.record, at: 2, project: project)
    project.applyDocumentRepair { $0.overlayTracks.append(EditLane(clips: [])) }
    let destinationID = project.state.overlayTracks[1].id
    motionRequire(project.saveNow(), "the lane-only AI fixture saves its unchanged motion before moving it")
    let original = project.state.clip(with: placed.clip.id)!
    let store = ProjectVersionStore.for(project)
    historyFolder = store.folder
    guard let first = store.save(project.state, kind: .afterRound).version else {
        throw AIToolError("The lane-only AI fixture has no starting version")
    }
    let round = AISession.shared.round(for: project)
    round.beginIfNeeded(project: project)
    let answer = try await fixture.completed(fixture.call(["clip_id": .string(original.id.uuidString), "track": "V3"]))
    motionRequire(!answer.failed, "a real set_motion call moves only the existing clip's lane")
    motionRequire(project.state.clip(with: original.id) == original,
                  "the successful lane-only call leaves the complete EditClip value equal")
    let actualLane = project.state.location(of: original.id).flatMap { location -> UUID? in
        guard case .overlay(let index) = location.track else { return nil }
        return project.state.overlayTracks[index].id
    }
    motionRequire(actualLane == destinationID, "the lane-only call actually lands on the requested destination UUID")
    motionRequire(answer.payload["unchanged"] != true, "a lane-only AI move is reported as a change")
    motionRequire(answer.payload["before_round_version"]?["id"] == .string(first.id),
                  "a lane-only AI move reports the version from before its round")
    round.finishRound()
    store.refresh()
    motionRequire(store.versions.map(\.id) == ["v2", first.id], "a lane-only AI round saves its changed end as a new version")
}
