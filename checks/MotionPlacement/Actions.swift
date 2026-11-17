import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// The real helper's movie is placed through the production service, then edited and reused through the AI tool.
@MainActor func runMotionActionChecks(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    let initial = project.state
    let placed = try await WebMotionActions.place(record: fixture.record, hitAt: 2.25, project: project)
    let id = placed.clip.id
    motionRequire(project.state.mainClips.isEmpty && project.state.overlayTracks.count == 1, "web motion only creates an upper video track")
    motionRequire(abs(placed.clip.timelineStart - 2) < 0.000001, "the local 0.25 s hit lands at timeline second 2.25")
    motionRequire(placed.rendered.result.checks.count == 6 && placed.rendered.result.checks.allSatisfy { $0.passed == true },
                  "the placed real movie passed all six page checks")
    motionRequire(placed.rendered.result.frameCount == 12 && placed.rendered.result.frameHashes.count == 12,
                  "the half-second page really rendered twelve 24-fps frames")
    motionRequire(FileManager.default.fileExists(atPath: placed.clip.sourceURL.path), "the placed clip points to a real movie")
    motionRequire(placed.clip.sourceURL.deletingLastPathComponent() == WebMotionProjectFiles.directory(for: project.documentURL!),
                  "the movie is cached next to its project under SkyCut/Motion")
    motionRequire(project.state.mediaURLs.isEmpty, "the generated movie is not imported media")
    try await generatedCacheCannotBeUpscaled(fixture, clipID: id)
    try explicitFileReplacementDropsThePage(fixture, original: placed.clip)
    let firstState = project.state
    project.ownUndoManager.undo()
    motionRequire(project.state == initial && !project.ownUndoManager.canUndo, "one undo removes the whole placement")
    project.ownUndoManager.redo()
    motionRequire(project.state == firstState, "one redo restores the same clip and movie")

    // A cut and speed set by the editor must survive an AI parameter-only re-render.
    project.applyDocumentRepair { state in
        state.update(id) { clip in
            clip.sourceStart = 1.0 / 12
            clip.sourceDuration = 1.0 / 3
            clip.speed = 1.5
            clip.rotationDegrees = 12
            clip.opacity = 0.75
            clip.placement = .init(centerX: 0.4, centerY: 0.6, width: 0.7, height: 0.7)
        }
    }
    let before = project.state
    let old = before.clip(with: id)!
    fixture.resetUndo()
    AIAccessStore.shared.setMode(.ask)
    AIMotionTool.answerWithin = 0
    let reply = try await fixture.completed(fixture.call(["clip_id": .string(id.uuidString), "parameters": ["color": "#ffaa33"]]))
    motionRequire(reply.wasJob && !reply.failed, "a slow-answer path returns a job whose real result succeeds")
    guard let changed = project.state.clip(with: id) else { throw AIToolError("The parameter edit lost its clip id") }
    motionRequire(changed.id == id && changed.timelineStart == old.timelineStart && changed.sourceStart == old.sourceStart
                    && changed.sourceDuration == old.sourceDuration && changed.speed == old.speed
                    && changed.opacity == old.opacity && changed.rotationDegrees == old.rotationDegrees && changed.placement == old.placement,
                  "parameter-only editing keeps the clip id, cut, speed, placement and effects")
    motionRequire(changed.sourceURL != old.sourceURL && FileManager.default.fileExists(atPath: old.sourceURL.path),
                  "changed parameters create a new immutable cache and retain the old movie for undo")
    let values = WebMotionParameters.object(changed.webMotion!.parametersJSON)
    motionRequire(values["text"] == "EXPEDITION" && values["color"] == "#ffaa33", "parameter edits merge with unmentioned values")
    motionRequire(reply.payload["clip_id"]?.stringValue != nil && reply.payload["render_seconds"]?.doubleValue != nil
                    && reply.payload["checks"]?.arrayValue?.count == 6 && !(reply.payload["look_times"]?.arrayValue?.isEmpty ?? true),
                  "the AI receives clip identity, render time, six checks and moments to inspect")
    let after = project.state
    project.ownUndoManager.undo()
    motionRequire(project.state == before && !project.ownUndoManager.canUndo, "one undo restores the preceding parameters and movie")
    project.ownUndoManager.redo()
    motionRequire(project.state == after, "one redo restores the parameter edit")

    fixture.resetUndo()
    let reuse = try await fixture.completed(fixture.call(["template": .string("project:\(id.uuidString.lowercased())"), "at": 2.1]))
    motionRequire(!reuse.failed && project.state.allClips.count == 2, "one AI call reuses the stored page as a new template placement")
    motionRequire(reuse.payload["cache_hit"] == true && reuse.payload["render_seconds"] == 0,
                  "an unchanged local template reuses its checked movie")
    motionRequire(project.state.overlayTracks.count == 2, "an overlapping template placement lifts to another upper track")
    let library = AIMotionSummary.library(project.state).arrayValue ?? []
    motionRequire(library.prefix(3).allSatisfy { $0["kind"] == "native" } && library.dropFirst(3).allSatisfy { $0["kind"] == "web" },
                  "the shared library lists native presets before reusable web pages")
    project.ownUndoManager.undo()
    motionRequire(project.state.allClips.count == 1, "template reuse is one undo step")
    project.ownUndoManager.redo()
    try await hiddenTargetAndTiming(fixture, record: changed.webMotion!)
    try await hiddenExistingClipKeepsItsLane(fixture)
    try await nonGridDurationUsesTheMovieLength(fixture)
    AIMotionTool.answerWithin = 25
}

/// File replacement consumes already-probed values; applying it is pure and must detach the old generated source.
@MainActor private func explicitFileReplacementDropsThePage(_ fixture: MotionFixture, original: EditClip) throws {
    let replacement = ClipFileReplacement(url: fixture.root.appendingPathComponent("ordinary-video.mov"), kind: .video,
                                          duration: original.info!.duration, info: original.info, hasAudio: false)
    var changed = original
    try ClipFileReplacement.apply(replacement, to: &changed, sourceStart: 0, stillDuration: replacement.duration)
    motionRequire(changed.webMotion == nil && changed.sourceURL == replacement.url,
                  "an explicit ordinary video replacement clears web-motion source metadata and swaps the URL")
    motionRequire(changed.id == original.id && changed.timelineStart == original.timelineStart
                    && changed.sourceDuration == original.sourceDuration,
                  "explicit file replacement keeps the clip's identity and timeline geometry")
    var refused = original
    var tooShort = replacement
    tooShort.duration = 0.01
    do {
        try ClipFileReplacement.apply(tooShort, to: &refused, sourceStart: 0, stillDuration: tooShort.duration)
        motionRequire(false, "a replacement too short for this generated clip must be refused")
    } catch {
        motionRequire(refused == original && refused.webMotion != nil,
                      "a refused short replacement retains the generated page and original clip unchanged")
    }
}

/// Generated motion caches retain their stored page as source; neither UI nor AI may turn one into an upscale source.
@MainActor private func generatedCacheCannotBeUpscaled(_ fixture: MotionFixture, clipID: UUID) async throws {
    let project = fixture.project
    let before = project.state
    motionRequire(UpscalePanelModel(project: project, clipID: clipID) == nil,
                  "the upscale panel refuses a generated web-motion cache")
    do {
        _ = try await AIUpscaleTool.upscale(AIToolArguments(["clip_id": .string(clipID.uuidString)]), project)
        motionRequire(false, "the AI upscale tool must refuse generated web motion before account or network work")
    } catch let error as AIToolError {
        motionRequire(error.message.contains("generated web motion"),
                      "the real AI upscale tool rejects the generated source before checking for a key")
    }
    motionRequire(project.state == before, "refusing upscale preserves the generated motion and its project")
}

/// A page duration may end between frames; whole clips use the encoded movie's frame-aligned length.
@MainActor private func nonGridDurationUsesTheMovieLength(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    let before = project.state
    defer {
        project.applyDocumentRepair { $0 = before }
        fixture.resetUndo()
    }
    var record = fixture.record
    record.duration = 0.51
    let first = try await WebMotionActions.place(record: record, at: 12, project: project)
    guard let firstInfo = first.clip.info else { throw AIToolError("The non-grid movie has no probed duration") }
    motionRequire(abs(firstInfo.duration - 0.5) < 0.000001
                    && abs(first.clip.sourceDuration - firstInfo.duration) < 0.000001 && first.clip.sourceStart == 0,
                  "a 0.51-second page at 24 fps creates a whole 0.5-second clip with no tail beyond its movie")
    var grown = first.clip.webMotion!
    grown.duration = 1.01
    let second = try await WebMotionActions.place(record: grown, replacing: first.clip.id, project: project)
    guard let secondInfo = second.clip.info else { throw AIToolError("The extended non-grid movie has no probed duration") }
    motionRequire(abs(secondInfo.duration - 1) < 0.000001
                    && abs(second.clip.sourceDuration - secondInfo.duration) < 0.000001 && second.clip.sourceStart == 0
                    && second.clip.sourceDuration > first.clip.sourceDuration && second.clip.id == first.clip.id,
                  "growing that same whole page to 1.01 seconds extends the same clip to its actual 1-second movie")
}

/// Re-rendering is an edit to the existing clip: hiding its lane must not be undone by that edit.
@MainActor private func hiddenExistingClipKeepsItsLane(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    let before = project.state
    guard let original = before.allClips.first(where: { $0.webMotion != nil }),
          case .overlay(let index)? = before.location(of: original.id)?.track,
          var record = original.webMotion else { throw AIToolError("The hidden-edit fixture needs a web-motion clip") }
    let laneID = before.overlayTracks[index].id
    defer {
        project.applyDocumentRepair { $0 = before }
        fixture.resetUndo()
    }
    project.applyDocumentRepair { $0.overlayTracks[index].isHidden = true }
    var parameters = WebMotionParameters.object(record.parametersJSON)
    parameters["text"] = "HIDDEN REVISION"
    record.parametersJSON = try WebMotionParameters.canonical(parameters)
    let edited = try await WebMotionActions.place(record: record, replacing: original.id, project: project)
    guard case .overlay(let resultingIndex)? = project.state.location(of: edited.clip.id)?.track else {
        throw AIToolError("Re-rendering the hidden clip lost its upper-track location")
    }
    let resultingLane = project.state.overlayTracks[resultingIndex]
    motionRequire(resultingLane.id == laneID && resultingLane.isHidden
                    && project.state.overlayTracks.count == before.overlayTracks.count,
                  "a parameter-only edit stays in the same hidden lane instead of making the clip visible")
    motionRequire(edited.clip.id == original.id && edited.clip.timelineStart == original.timelineStart
                    && edited.clip.sourceStart == original.sourceStart && edited.clip.sourceDuration == original.sourceDuration,
                  "re-rendering in a hidden lane retains the existing clip's identity and cut")
}

@MainActor private func hiddenTargetAndTiming(_ fixture: MotionFixture, record: WebMotionClipRecord) async throws {
    let project = fixture.project
    project.applyDocumentRepair { $0.overlayTracks[0].isHidden = true }
    let hidden = try await WebMotionActions.place(record: record, at: 9, preferring: .overlay(0), project: project)
    guard case .overlay(let index)? = project.state.location(of: hidden.clip.id)?.track else {
        throw AIToolError("The hidden-target placement did not create an upper-track clip")
    }
    motionRequire(index != 0 && !project.state.overlayTracks[index].isHidden && hidden.rendered.cacheHit,
                  "a hidden requested lane falls back to a visible upper track, using the cached movie")
    project.applyDocumentRepair { $0.overlayTracks[0].isHidden = false }

    var whole = hidden.clip
    whole.sourceStart = 0
    whole.sourceDuration = record.duration
    whole.speed = 2
    var grown = record
    grown.duration = 1
    grown.hitTime = 0.75
    let wholeStart = try WebMotionActions.startTime(grown, before: whole, at: nil, hitAt: 5)
    motionRequire(abs(wholeStart - 4.625) < 0.000001,
                  "a growing whole clip can put its new source hit beyond the old end, accounting for speed")
    var trimmed = whole
    trimmed.sourceStart = 0.1
    trimmed.sourceDuration = 0.2
    do {
        _ = try WebMotionActions.startTime(grown, before: trimmed, at: nil, hitAt: 5)
        motionRequire(false, "a trimmed clip must reject a source hit outside its retained range")
    } catch {
        motionRequire(true, "a trimmed clip cannot claim a hit it does not show")
    }
}
