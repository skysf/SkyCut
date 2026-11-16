import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// A round of 20 edits and one step back; nothing saved when nothing changed; a never-saved project; undo version='s errors.
// (Two projects and a moved media file: TwoProjectChecks.swift.)

/// Twenty different edits an AI round might make: texts, volumes, moves, a clip removed (a media reference goes) and one added
/// (another comes), the music track's fader.
func twentyEdits(_ step: Int, _ state: inout TimelineState, _ media: Media) {
    switch step {
    case 0: state.textOverlays.append(TextOverlay(text: "Edit 0", timelineStart: 3, duration: 1, row: 1))
    case 1: state.mainClips[1].volume = 0.3
    case 2: state.mainClips[1].timelineStart = 2.5
    case 3: state.mainClips.remove(at: 0)
    case 4: state.mainClips.append(EditClip(sourceURL: media.c, sourceDuration: 1.5, timelineStart: 6))
    case 5: state.audioTracks[0].volume = 0.6
    case 6: state.audioTracks[0].clips[0].fadeInDuration = 0.5
    default: state.textOverlays[0].text = "Edit \(step)"
    }
}

@MainActor
func runRoundChecks(_ checks: Checks, media: Media) async throws {
    let start = media.startingState()
    let project = try makeProject("Round.skycut", in: media.work.appendingPathComponent("round"), state: start)
    defer { close(project) }
    let round = AISession.shared.round(for: project)
    checks.require(project.state == start && versionFiles(project).isEmpty, "a project nobody edited with AI has no versions")

    // A round of 20 edits: the first change saves the starting point and names it; the others do not.
    var named: [JSONValue?] = []
    for step in 0..<20 {
        named.append(aiEdit(project) { twentyEdits(step, &$0, media) }.payload["before_round_version"])
    }
    checks.require(named[0]?["id"] == "v1" && round.beforeVersion == "v1", "the round's first change names v1 (\(String(describing: named[0])))")
    checks.require(named[0]?["note"]?.stringValue?.contains("undo version=v1") == true, "the note tells the AI how to go back")
    checks.require(named.dropFirst().allSatisfy { $0 == nil }, "only the round's first change names it")
    var files = versionFiles(project)
    checks.require(files.map(\.id) == ["v1"] && files.first?.kind == .beforeRound, "during the round there is one version, its start")
    checks.require(files.first.flatMap { ProjectVersionFiles.canonicalTimeline(ofFile: $0.url) } == ProjectVersionFiles.canonical(start),
                   "v1 holds the starting point")
    checks.require(project.state != start && project.state.mediaURLs != start.mediaURLs, "the round changed the project and its media")
    checks.require(AIRoundVersions.statusJSON(project)["before_round_version"] == "v1", "get_status names this round's starting point")

    // The round ends (30 s without calls): what it made becomes v2.
    round.finishRound()
    files = versionFiles(project)
    checks.require(files.map(\.id) == ["v2", "v1"] && files.first?.kind == .afterRound, "the end of the round saves v2 (\(files.map(\.id)))")

    // A second round right away: its starting point already is v2, nothing written; its end is v3.
    _ = aiEdit(project) { $0.textOverlays[0].text = "Second round" }
    checks.require(round.beforeVersion == "v2" && versionFiles(project).count == 2,
                   "a starting point equal to the newest version reuses it (\(round.beforeVersion ?? "nil"))")
    round.finishRound()
    let leftState = project.state
    checks.require(versionFiles(project).map(\.id) == ["v3", "v2", "v1"], "the second round's end is v3")

    // Nothing changed, nothing saved: the same state again, after a restart (nothing in memory), and a round without changes.
    let newest = versionFiles(project)[0]
    checks.require(ProjectVersionStore.for(project).save(project.state, kind: .afterRound) == .unchanged(newest), "the same state again writes nothing")
    ProjectVersionStore.forget(project)
    checks.require(ProjectVersionStore.for(project).save(project.state, kind: .afterRound) == .unchanged(newest),
                   "after a restart the newest file is read and compared: nothing written")
    round.beginIfNeeded(project: project)
    round.finishRound()
    checks.require(versionFiles(project).count == 3 && round.phase == .idle, "a round that changed nothing saves nothing")

    // One step back to before the first round, the way the AI does it.
    let undo = project.effectiveUndoManager!
    let back = try await AIProjectTools.undo(AIToolArguments(["version": "v1"]), project)
    checks.require(back.changedProject && back.payload["undone"] == "version" && back.payload["version"] == "v1", "undo version=v1 went back")
    checks.require(back.payload["saved_before_going_back"] == "v3" && versionFiles(project).count == 3,
                   "the state being left already was v3: named, nothing new written")
    checks.require(project.state == start, "one step back: the project equals the starting point field by field")
    checks.require(project.state.allClips.map(\.sourceURL) == start.allClips.map(\.sourceURL) && project.state.mediaURLs == start.mediaURLs,
                   "media references are the starting point's")
    checks.require(start.mediaURLs.allSatisfy { project.mediaRecords[$0.path] != nil }, "every restored media file has its record (bookmark)")
    undo.undo()
    checks.require(project.state == leftState, "one Command-Z returns to the state before going back")
    undo.redo()
    checks.require(project.state == start, "and redo goes back again")
    let again = try await AIProjectTools.undo(AIToolArguments(["version": "v1"]), project)
    checks.require(!again.changedProject && again.payload["note"] != nil && versionFiles(project).count == 3,
                   "going back to the version it already is changes nothing")

    // get_status lists them newest first, with what each was saved for.
    let status = AIRoundVersions.statusJSON(project)
    checks.require(status["versions"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["v3", "v2", "v1"], "get_status lists the versions")
    checks.require(status["versions"]?.arrayValue?.map { $0["kind"]?.stringValue ?? "" } == ["after_ai_round", "after_ai_round", "before_ai_round"],
                   "get_status says what each was saved for")
    checks.require(round.beforeVersion == nil && status["before_round_version"] == nil,
                   "a round with no starting version (it changed nothing) names none in get_status")
    try await runMagnetGapCheck(checks, media: media)
    try runPruneChecks(checks, media: media)
}

/// A version with the magnet on and a gap left in V1 (a file may say so; opening never packs V1) comes back with its gap: going
/// back restores as is, not through `perform`, whose magnet would close it (docs/bugfixes/2026-10-02-undo-round-repacks-v1.md).
@MainActor
private func runMagnetGapCheck(_ checks: Checks, media: Media) async throws {
    var start = TimelineState()
    start.mainMagnet = true
    start.mainClips = [EditClip(sourceURL: media.a, sourceDuration: 2, timelineStart: 0),
                       EditClip(sourceURL: media.b, sourceDuration: 2, timelineStart: 3)]
    start.assignMissingTrackColors()
    let project = try makeProject("Magnet.skycut", in: media.work.appendingPathComponent("magnet"), state: start)
    defer { close(project) }
    _ = aiEdit(project) { $0.mainClips.remove(at: 0) }
    AISession.shared.round(for: project).finishRound()
    _ = try await AIProjectTools.undo(AIToolArguments(["version": "v1"]), project)
    checks.require(project.state == start && project.state.mainClips.last?.timelineStart == 3,
                   "the magnet's gap in V1 comes back with the version (V1 starts at \(project.state.mainClips.map(\.timelineStart)))")
}

/// The newest 30 stay; numbers keep counting.
@MainActor
private func runPruneChecks(_ checks: Checks, media: Media) throws {
    var state = media.startingState()
    let project = try makeProject("Prune.skycut", in: media.work.appendingPathComponent("prune"), state: state)
    defer { close(project) }
    let store = ProjectVersionStore.for(project)
    for index in 1...33 {
        state.textOverlays[0].text = "Version \(index)"
        _ = store.save(state, kind: .afterRound)
    }
    let ids = versionFiles(project).map(\.id)
    checks.require(ids.count == 30 && ids.first == "v33" && ids.last == "v4", "33 saved: the newest 30 stay (v4…v33), \(ids.count) files")
    checks.require(store.versions.map(\.id) == ids, "the sheet's list is the files on disk, newest first")
    state.textOverlays[0].text = "Version 34"
    checks.require(store.save(state, kind: .afterRound).version?.id == "v34" && versionFiles(project).last?.id == "v5",
                   "numbers keep counting after pruning")
}

/// A never-saved project gets its starting point once the router saved it; an empty start is not saved.
@MainActor
func runUntitledChecks(_ checks: Checks, media: Media) async throws {
    let primary = OpenProjects.shared.primary
    let start = media.startingState()
    primary.restoreTimeline(start)
    primary.effectiveUndoManager?.removeAllActions()
    checks.require(primary.isUntitled && ProjectVersionStore.for(primary).save(start, kind: .afterRound) == .notSaved(.untitled),
                   "a never-saved project has no place for versions")
    let round = AISession.shared.round(for: primary)
    round.beginIfNeeded(project: primary)
    _ = AIUndoGrouping.step(primary.effectiveUndoManager) { primary.perform { $0.textOverlays[0].text = "Changed" } }
    round.noteChange()
    checks.require(round.beforeVersion == nil, "the starting point waits until the project has a file")
    // What the router's saveIfNeverSaved does, into the check's folder.
    let folder = media.work.appendingPathComponent("untitled", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    checks.require(primary.saveDocument(as: folder.appendingPathComponent("Untitled.skycut")), "the never-saved project is saved")
    let reported = AIRoundVersions.reporting(primary, in: .ok(["edited": true], changed: true))
    checks.require(reported.payload["before_round_version"]?["id"] == "v1" && round.beforeVersion == "v1", "then its starting point is v1 and named")
    checks.require(versionFiles(primary).first.flatMap { ProjectVersionFiles.canonicalTimeline(ofFile: $0.url) } == ProjectVersionFiles.canonical(start),
                   "v1 is the state before the change, not after it")

    let empty = try makeProject("Empty.skycut", in: media.work.appendingPathComponent("empty"), state: TimelineState())
    defer { close(empty) }
    checks.require(ProjectVersionStore.for(empty).save(TimelineState(), kind: .afterRound) == .notSaved(.empty), "an empty timeline is never a version")
    let first = aiEdit(empty) { $0.textOverlays.append(TextOverlay(text: "First", timelineStart: 0, row: 0)) }
    checks.require(first.payload["before_round_version"] == nil && versionFiles(empty).isEmpty, "a round that starts empty names no version")
}

/// undo version='s errors follow the parameter contract: what was asked, what exists, a suggestion; nothing changes.
@MainActor
func runErrorChecks(_ checks: Checks, media: Media) async throws {
    let project = try makeProject("Errors.skycut", in: media.work.appendingPathComponent("errors"), state: media.startingState())
    defer { close(project) }
    _ = aiEdit(project) { $0.textOverlays[0].text = "Changed" }
    AISession.shared.round(for: project).finishRound()
    let state = project.state
    let files = versionFiles(project)
    let canUndo = project.effectiveUndoManager?.canUndo
    func unchanged(_ what: String) {
        checks.require(project.state == state && versionFiles(project) == files && project.effectiveUndoManager?.canUndo == canUndo,
                       "\(what): nothing changed, nothing saved, no undo step")
    }
    do {
        _ = try await AIProjectTools.undo(AIToolArguments(["version": "v9"]), project)
        checks.require(false, "an unknown version must fail")
    } catch let error as AIToolError {
        checks.require(error.details["status"] == "invalid_parameter" && error.details["parameter"] == "version"
                       && error.details["requested"] == "v9" && error.details["allowed"] == ["v2", "v1"]
                       && error.details["suggested"] == "v1" && error.details["retryable"] == false,
                       "unknown version: requested, allowed, the round's start suggested (\(error.details))")
    }
    unchanged("an unknown version")
    do {
        _ = try await AIProjectTools.undo(AIToolArguments(["version": "v1", "round": true]), project)
        checks.require(false, "version with round must fail")
    } catch let error as AIToolError {
        checks.require(error.message.contains("only one of steps, round and version"), "version with round=true is refused: \(error.message)")
    }
    unchanged("version with round=true")
    let fresh = try makeProject("NoVersions.skycut", in: media.work.appendingPathComponent("errors"), state: media.startingState())
    defer { close(fresh) }
    do {
        _ = try await AIProjectTools.undo(AIToolArguments(["version": "v1"]), fresh)
        checks.require(false, "a project without versions must fail")
    } catch let error as AIToolError {
        checks.require(error.details["allowed"] == [] && error.details["suggestion"] != nil && error.details["suggested"] == nil,
                       "no versions yet: an empty list and a suggestion, no made-up id")
    }
}
