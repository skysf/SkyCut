import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Two projects open at once keep their own versions; "Undo This Round" keeps what it leaves as a version; a version whose media
// file was moved since follows it.

@MainActor
func runTwoProjectChecks(_ checks: Checks, media: Media) async throws {
    let folder = media.work.appendingPathComponent("two", isDirectory: true)
    let oneStart = media.startingState()
    var twoStart = media.startingState()
    twoStart.textOverlays[0].text = "The other project"
    let one = try makeProject("One.skycut", in: folder, state: oneStart)
    let two = try makeProject("Two.skycut", in: folder, state: twoStart)
    defer { close(one); close(two) }

    // Both are edited by AI in the same stretch of time, interleaved.
    _ = aiEdit(one) { $0.textOverlays[0].text = "One, edited" }
    _ = aiEdit(two) { $0.textOverlays[0].text = "Two, edited" }
    _ = aiEdit(one) { $0.mainClips[0].volume = 0.2 }
    AISession.shared.round(for: one).finishRound()
    AISession.shared.round(for: two).finishRound()
    let oneFiles = versionFiles(one)
    let twoFiles = versionFiles(two)
    checks.require(ProjectVersionStore.for(one).folder != ProjectVersionStore.for(two).folder, "two projects, two folders")
    checks.require(oneFiles.map(\.id) == ["v2", "v1"] && twoFiles.map(\.id) == ["v2", "v1"], "each has its own v1 and v2")
    checks.require(oneFiles.last.flatMap { ProjectVersionFiles.canonicalTimeline(ofFile: $0.url) } == ProjectVersionFiles.canonical(oneStart)
                   && twoFiles.last.flatMap { ProjectVersionFiles.canonicalTimeline(ofFile: $0.url) } == ProjectVersionFiles.canonical(twoStart),
                   "each project's v1 is its own starting point")
    let oneFolder = ProjectVersionStore.for(one).folder?.resolvingSymlinksInPath().path
    checks.require(!ProjectVersionStore.for(one).versions.isEmpty
                   && ProjectVersionStore.for(one).versions.allSatisfy { $0.url.deletingLastPathComponent().resolvingSymlinksInPath().path == oneFolder },
                   "a project's list only shows its own folder")

    // Going back on one leaves the other alone.
    let twoNow = two.state
    _ = try await AIProjectTools.undo(AIToolArguments(["version": "v1"]), one)
    checks.require(one.state == oneStart && two.state == twoNow && versionFiles(two) == twoFiles, "going back on one leaves the other untouched")

    // "Undo This Round" (in memory, as before) is still exact, and keeps what it leaves as a version first.
    _ = aiEdit(two) { $0.textOverlays[0].text = "Mid round" }
    _ = aiEdit(two) { $0.mainClips[1].volume = 0.1 }
    let undone = try await AIProjectTools.undo(AIToolArguments(["round": true]), two)
    checks.require(undone.payload["undone"] == "round" && two.state == twoNow, "undo round=true returns to the round's start exactly")
    checks.require(versionFiles(two).first?.kind == .beforeGoingBack && versionFiles(two).count == 3,
                   "what undo round=true left is kept as a version (\(versionFiles(two).map(\.id)))")

    try await runMovedMediaChecks(checks, media: media)
}

/// A version refers to a file that was moved after it was saved: going back follows the file (its bookmark), so the clip plays.
@MainActor
private func runMovedMediaChecks(_ checks: Checks, media: Media) async throws {
    let manager = FileManager.default
    let folder = media.work.appendingPathComponent("moves", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let original = folder.appendingPathComponent("interview.mp4")
    try manager.copyItem(at: media.a, to: original)
    var start = TimelineState()
    start.mainClips = [EditClip(sourceURL: original, sourceDuration: 2, timelineStart: 0)]
    start.textOverlays = [TextOverlay(text: "Interview", timelineStart: 0, duration: 1, row: 0)]
    start.assignMissingTrackColors()
    let project = try makeProject("Moves.skycut", in: folder, state: start)
    defer { close(project) }
    // The round replaces the clip; the version from before it still refers to interview.mp4.
    _ = aiEdit(project) { $0.mainClips[0] = EditClip(sourceURL: media.b, sourceDuration: 2, timelineStart: 0) }
    AISession.shared.round(for: project).finishRound()
    checks.require(versionFiles(project).map(\.id) == ["v2", "v1"], "the moves project has v1 (with interview.mp4) and v2")
    let moved = folder.appendingPathComponent("renamed/interview, final.mp4")
    try manager.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.moveItem(at: original, to: moved)
    _ = try await AIProjectTools.undo(AIToolArguments(["version": "v1"]), project)
    let clip = project.state.mainClips.first
    checks.require(clip?.sourceURL.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath(),
                   "going back follows the moved file (\(clip?.sourceURL.path ?? "no clip"))")
    checks.require(clip.map { project.mediaRecords[$0.sourceURL.path] != nil } == true, "the moved file's record is in the project's table")
    checks.require(project.state.textOverlays.map(\.text) == ["Interview"], "the rest of the version came back too")
}
