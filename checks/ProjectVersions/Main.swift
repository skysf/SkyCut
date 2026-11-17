import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Saved project versions around AI rounds (docs/architecture/project-versions.md), on real App objects in an isolated bundle with
// temporary projects, media and versions root (scripts/check-project-versions.sh). Never touches the user's SkyCut, keychain or
// Application Support.
// - FileChecks.swift: names, ids, the per-project folder, pruning and the age sweep (pure rules + a real folder).
// - RoundChecks.swift: a round of 20 edits, then one step back to the version from before it — the project equals the starting
//   point field by field (media references included), Command-Z returns; nothing saved when nothing changed; a never-saved project;
//   undo version='s errors; get_status; two projects keep their own versions; a moved media file is followed.

@MainActor
final class Checks {
    private(set) var count = 0
    private(set) var failures = 0

    func require(_ condition: Bool, _ message: String) {
        count += 1
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}

@main enum ProjectVersionChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.projectversionscheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Use the isolated project versions check bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        guard let workPath = environment["SRTFLOW_PROJECT_VERSIONS_CHECK_DIR"], let rootPath = environment["SRTFLOW_VERSIONS_ROOT"] else {
            fatalError("SRTFLOW_PROJECT_VERSIONS_CHECK_DIR and SRTFLOW_VERSIONS_ROOT are required")
        }
        let work = URL(fileURLWithPath: workPath, isDirectory: true).resolvingSymlinksInPath()
        let checks = Checks()
        checks.require(ProjectVersionStore.root.path == URL(fileURLWithPath: rootPath, isDirectory: true).path,
                       "the check writes versions only into its own root (\(ProjectVersionStore.root.path))")
        runFileChecks(checks, work: work)
        do {
            let media = Media(work: work)
            try await runRoundChecks(checks, media: media)
            try await runUntitledChecks(checks, media: media)
            try await runErrorChecks(checks, media: media)
            try await runTwoProjectChecks(checks, media: media)
        } catch {
            checks.require(false, "unexpected error: \(error)")
        }
        print("\(checks.count - checks.failures)/\(checks.count) passed")
        exit(checks.failures == 0 ? 0 : 1)
    }
}

/// The media files the script made (tiny real videos), and a project state built from them.
struct Media {
    let work: URL
    var a: URL { work.appendingPathComponent("a.mp4") }
    var b: URL { work.appendingPathComponent("b.mp4") }
    var c: URL { work.appendingPathComponent("c.mp4") }

    /// Two clips on V1, music on A1 and a title: what a project looks like before an AI round.
    func startingState() -> TimelineState {
        var state = TimelineState()
        state.mainMagnet = false
        state.mainClips = [
            EditClip(sourceURL: a, sourceDuration: 2, timelineStart: 0),
            EditClip(sourceURL: b, sourceDuration: 2, timelineStart: 2, volume: 0.8)
        ]
        state.audioTracks = [EditLane(clips: [EditClip(sourceURL: c, isAudioOnly: true, sourceDuration: 2, timelineStart: 0, volume: 0.5)])]
        state.textOverlays = [TextOverlay(text: "Title", timelineStart: 0.5, duration: 2, row: 0)]
        state.assignMissingTrackColors()
        return state
    }
}

/// A saved, headless project holding `state`, with no undo history.
@MainActor
func makeProject(_ name: String, in folder: URL, state: TimelineState) throws -> VideoEditProject {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let project = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent(name), placement: .background) else {
        throw AIToolError("could not create \(name): \(OpenProjects.shared.failure ?? "unknown")")
    }
    project.restoreTimeline(state)
    project.effectiveUndoManager?.removeAllActions()
    guard project.saveNow() else { throw AIToolError("could not save \(name)") }
    return project
}

/// One AI tool call that changes the project, the way the router runs it: a round starts (if none is running), the edit is one
/// undo step, the change is counted, and the result goes through the same hook (AIRoundVersions.reporting).
@MainActor
func aiEdit(_ project: VideoEditProject, _ mutate: (inout TimelineState) -> Void) -> AIToolResult {
    let round = AISession.shared.round(for: project)
    round.beginIfNeeded(project: project)
    _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform(mutate) }
    round.noteChange()
    return AIRoundVersions.reporting(project, in: .ok(["edited": true], changed: true))
}

/// Closes a project the check opened (SkyCut keeps at most 8 open), as close_project does.
@MainActor
func close(_ project: VideoEditProject) {
    _ = OpenProjects.shared.close(project)
}

/// The version files in a project's folder, newest first.
@MainActor
func versionFiles(_ project: VideoEditProject) -> [ProjectVersion] {
    ProjectVersionStore.for(project).folder.map(ProjectVersionStore.read) ?? []
}
