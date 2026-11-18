import AppKit
import Darwin
import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Exercise the inspector's real draft/render and card/drop preparation paths with a synthetic page. These checks never
// instantiate a window, reveal Finder, use a user project, or replace the existing model/AI/cache integration checks.
@MainActor func runMotionEditorChecks(_ root: URL) async throws {
    let fixture = try MotionFixture(root: root.appendingPathComponent("editor-motion"))
    defer { _ = OpenProjects.shared.close(fixture.project) }
    var record = fixture.record
    record.page = record.page.replacingOccurrences(of: "ctx.font='60px Avenir Next'",
                                                   with: "ctx.font='60px '+(MOTION_PARAMS.font||'Avenir Next')")
        .replacingOccurrences(of: "canvas.width*.5", with: "canvas.width*(MOTION_PARAMS.amount||.5)")
    record.parameterFields += [.init(key: "font", label: "Typeface", kind: .font),
                               .init(key: "amount", label: "Amount", kind: .number, minimum: 0.1, maximum: 1),
                               .init(key: "duration", label: "Duration", kind: .number),
                               .init(key: "hit", label: "Hit", kind: .number)]
    var values = WebMotionParameters.object(record.parametersJSON)
    let fonts = ["Avenir Next", "Helvetica", "Arial", "Menlo"].filter(WebMotionEnvironment.hasFont)
    guard let font = fonts.first, let editedFont = fonts.dropFirst().first else {
        throw AIToolError("Editor motion checks require two distinct installed typefaces")
    }
    values["font"] = .string(font)
    values["amount"] = 0.5
    record.parametersJSON = try WebMotionParameters.canonical(values)
    let placed = try await WebMotionActions.place(record: record, at: 2, project: fixture.project)
    fixture.project.applyDocumentRepair { state in
        state.update(placed.clip.id) {
            $0.sourceStart = 1.0 / 12
            $0.sourceDuration = 1.0 / 3
            $0.speed = 1.5
            $0.opacity = 0.75
            $0.rotationDegrees = 12
            $0.placement = .init(centerX: 0.4, centerY: 0.6, width: 0.7, height: 0.7)
        }
    }
    fixture.resetUndo()
    try await draftAndRender(fixture, id: placed.clip.id, font: editedFont)
    try await editorRejectsQueuedChanges(fixture, id: placed.clip.id)
    try await addUsesCapturedTime(fixture, id: placed.clip.id)
    try editorDropPlans(fixture, id: placed.clip.id)
    requestFollowsDestinationIdentity(fixture, id: placed.clip.id)
}

@MainActor private func draftAndRender(_ fixture: MotionFixture, id: UUID, font: String) async throws {
    let project = fixture.project
    let before = project.state
    let original = before.clip(with: id)!
    let editor = WebMotionEditorModel(project: project, clip: original)
    motionRequire(!editor.hasChanges && !editor.isStale, "an inspector begins from the current stored parameters")
    editor.setString("EDITOR DRAFT", for: "text")
    editor.setString(font, for: "font")
    editor.setString("#8844aa", for: "color")
    editor.setNumber(0.35, for: "amount")
    editor.setDuration(0.625)
    editor.setHit(0.3125)
    motionRequire(editor.record.duration == 0.625 && editor.record.hitTime == 0.3125
                    && editor.number(for: "duration") == 0.625 && editor.number(for: "hit") == 0.3125,
                  "dedicated duration/hit controls keep scalar metadata and parameter JSON synchronized")
    editor.setNumber(0.75, for: "duration")
    editor.setNumber(0.375, for: "hit")
    let values = WebMotionParameters.object(editor.record.parametersJSON)
    motionRequire(values["text"] == "EDITOR DRAFT" && values["font"] == .string(font)
                    && values["color"] == "#8844aa" && values["amount"] == 0.35,
                  "text, installed font, colour and numeric fields edit the draft's typed values")
    motionRequire(editor.record.duration == 0.75 && editor.record.hitTime == 0.375
                    && values["duration"] == 0.75 && values["hit"] == 0.375,
                  "reserved numeric setters use the same normalized duration and local hit")
    motionRequire(editor.fields.allSatisfy { !["duration", "hit"].contains($0.key) },
                  "reserved timing values have one dedicated control rather than duplicate form fields")
    motionRequire(editor.hasChanges && project.state == before && !project.ownUndoManager.canUndo,
                  "changing every inspector field remains a local draft until Re-render")
    try await storedPagePreparation(editor, original: original)
    motionRequire(editor.hasChanges && project.state == before && !project.ownUndoManager.canUndo,
                  "preparing Show Page preserves the draft, timeline and undo history")
    let succeeded = await editor.render()
    motionRequire(succeeded && editor.error == nil && !editor.isRendering && !editor.hasChanges,
                  "Re-render commits the checked draft and resets the editor's baseline")
    guard let changed = project.state.clip(with: id) else { throw AIToolError("The editor re-render lost its clip") }
    motionRequire(changed.id == original.id && changed.timelineStart == original.timelineStart
                    && changed.sourceStart == original.sourceStart && changed.sourceDuration == original.sourceDuration
                    && changed.speed == original.speed && changed.opacity == original.opacity
                    && changed.rotationDegrees == original.rotationDegrees && changed.placement == original.placement,
                  "UI re-render retains the same clip, trim, speed, placement and effects")
    motionRequire(changed.webMotion?.duration == 0.75 && changed.webMotion?.hitTime == 0.375
                    && WebMotionParameters.object(changed.webMotion!.parametersJSON) == values,
                  "the committed source retains all normalized draft values")
    motionRequire(changed.sourceURL != original.sourceURL && FileManager.default.fileExists(atPath: original.sourceURL.path),
                  "UI parameter edits keep the preceding immutable movie available for undo")
    let after = project.state
    project.ownUndoManager.undo()
    motionRequire(project.state == before && !project.ownUndoManager.canUndo,
                  "one undo restores all preceding UI parameters and the old movie")
    project.ownUndoManager.redo()
    motionRequire(project.state == after, "one redo restores the re-rendered UI draft")
    fixture.resetUndo()
}

@MainActor private func storedPagePreparation(_ editor: WebMotionEditorModel, original: EditClip) async throws {
    let html = original.sourceURL.deletingPathExtension().appendingPathExtension("html")
    let parameters = original.sourceURL.deletingPathExtension().appendingPathExtension("parameters.json")
    for file in [html, parameters] where FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
    }
    let prepared = try await editor.pageURL()
    motionRequire(prepared == html && FileManager.default.fileExists(atPath: prepared.path),
                  "Show Page prepares a real source file beside the stored movie without opening Finder")
    motionRequire(try Data(contentsOf: prepared) == Data(original.webMotion!.page.utf8),
                  "Show Page writes the exact stored HTML bytes")
    motionRequire(try Data(contentsOf: parameters) == Data(original.webMotion!.parametersJSON.utf8),
                  "Show Page writes exact stored parameters, keeping unapplied draft values out of movie sidecars")
}

@MainActor private func editorRejectsQueuedChanges(_ fixture: MotionFixture, id: UUID) async throws {
    let project = fixture.project
    let baseline = project.state
    let original = baseline.clip(with: id)!
    let editor = WebMotionEditorModel(project: project, clip: original)
    editor.setString("STALE UI DRAFT", for: "text")
    project.applyDocumentRepair { $0.update(id) { $0.opacity = 0.5 } }
    let newer = project.state
    try await withRendererSentinel(root: fixture.root) { marker in
        let success = await editor.render()
        motionRequire(!success && editor.isStale && editor.error != nil,
                      "a clip edited before the UI Task starts refuses the stale draft")
        motionRequire(project.state == newer && !project.ownUndoManager.canUndo,
                      "pre-start UI rejection preserves the newer clip and adds no undo")
        motionRequire(!FileManager.default.fileExists(atPath: marker.path),
                      "stale UI validation happens before any renderer helper starts")
    }
    editor.reload()
    motionRequire(!editor.isStale && !editor.hasChanges && editor.record == project.state.clip(with: id)?.webMotion,
                  "Reload replaces the stale draft with current stored parameters")
    project.applyDocumentRepair { $0 = baseline }
    let invalidFont = WebMotionEditorModel(project: project, clip: original)
    invalidFont.setString("SrtFlow missing synthetic editor font", for: "font")
    try await withRendererSentinel(root: fixture.root) { marker in
        let success = await invalidFont.render()
        motionRequire(!success && invalidFont.error != nil && project.state == baseline,
                      "an unavailable typeface is rejected without changing the source")
        motionRequire(!FileManager.default.fileExists(atPath: marker.path),
                      "installed-font validation precedes helper startup")
    }
    try await sourceLaneRejectsQueuedUI(fixture, id: id)
    try await changedDocumentRejectsQueuedUI(fixture, id: id)
}

@MainActor private func changedDocumentRejectsQueuedUI(_ fixture: MotionFixture, id: UUID) async throws {
    let project = fixture.project
    let baseline = project.state
    let original = baseline.clip(with: id)!
    let editor = WebMotionEditorModel(project: project, clip: original)
    let request = WebMotionPresetRequest(templateID: "project:\(id.uuidString.lowercased())", at: 8, project: project)
    let preset = WebMotionPresetModel(project: project)
    let oldGeneration = project.documentGeneration
    project.newProject()
    project.replaceStateForDocument(baseline)
    motionRequire(project.saveDocument(as: fixture.root.appendingPathComponent("New.skycut")),
                  "the replacement-document fixture saves only inside its temporary project folder")
    motionRequire(project.documentGeneration != oldGeneration && project.state.clip(with: id) == original,
                  "the real New Project path changes document identity even when clip IDs and source are identical")
    fixture.resetUndo()
    let replacement = project.state
    try await withRendererSentinel(root: fixture.root) { marker in
        let rendered = await editor.render()
        let added = await preset.add(request)
        motionRequire(!rendered && !added && editor.isStale && preset.error != nil,
                      "queued inspector and add actions retain the document captured before Task creation")
        motionRequire(project.state == replacement && !project.ownUndoManager.canUndo,
                      "an old UI action cannot enter a new document containing the same clip")
        motionRequire(!FileManager.default.fileExists(atPath: marker.path),
                      "old-document UI actions reject before helper startup")
    }
}

@MainActor private func addUsesCapturedTime(_ fixture: MotionFixture, id: UUID) async throws {
    let project = fixture.project
    let before = project.state
    project.clock.seek(to: 7)
    let request = WebMotionPresetRequest(templateID: "project:\(id.uuidString.lowercased())", at: project.clock.time,
                                         project: project)
    project.clock.seek(to: 17)
    let preset = WebMotionPresetModel(project: project)
    let succeeded = await preset.add(request)
    let added = project.state.allClips.first { before.clip(with: $0.id) == nil }
    motionRequire(succeeded && added?.timelineStart == 7 && project.clock.time == 17,
                  "a template add uses the time captured at the tap, not the later playhead")
    motionRequire(added?.sourceStart == 0 && added?.sourceDuration == 0.75 && added?.speed == 1,
                  "a reused template becomes a fresh whole clip rather than inheriting the source clip's trim or speed")
    guard let added else { throw AIToolError("The UI add did not produce its new clip") }
    motionRequire(project.state.mainClips.isEmpty && project.state.location(of: added.id)?.track.isMain == false
                    && project.selectedClipIDs == [added.id],
                  "the UI add selects its new upper-track clip without placing media on V1")
    project.ownUndoManager.undo()
    motionRequire(project.state == before && !project.ownUndoManager.canUndo, "a UI template add remains one undo step")
    fixture.resetUndo()
}

@MainActor private func editorDropPlans(_ fixture: MotionFixture, id: UUID) throws {
    var state = fixture.project.state
    state.canvasRatio = .tall9x16
    state.frameRate = .fps60
    let fresh = try MotionPresetLibrary.template("project:\(id.uuidString.lowercased())", in: state)
    motionRequire(fresh.width == 1080 && fresh.height == 1920 && fresh.fps == state.frameRate.fps,
                  "reusing a page adopts fresh destination canvas geometry and project fps")
    motionRequire(state.clip(with: id)?.webMotion?.width == 320 && state.clip(with: id)?.webMotion?.fps != fresh.fps,
                  "fresh template preparation does not mutate the stored source geometry")
    state.overlayTracks.append(EditLane(clips: []))
    let lowerTargets: [TrackDropTarget?] = [.main, .audio(0), .newAudioBottom, .insertAudio(at: 0), nil]
    for target in lowerTargets {
        let plan = WebMotionPresetDropPlan.resolve(time: 5, duration: 0.5, target: target, state: state)
        motionRequire(plan?.target == .overlay(0) && plan?.start == 5 && plan?.duration == 0.5 && plan?.end == 5.5,
                      "incompatible or absent drop rows retain pointer timing and choose a visible upper video lane")
    }
    let collision = WebMotionPresetDropPlan.resolve(time: 2, duration: 0.5, target: .overlay(0), state: state)
    motionRequire(collision?.target == .overlay(1) && collision?.start == 2,
                  "a drop collision lifts by the existing media landing rule without moving its start")
    state.overlayTracks[0].isHidden = true
    motionRequire(WebMotionPresetDropPlan.resolve(time: 5, duration: 0.5, target: .overlay(0), state: state)?.target == .overlay(1),
                  "a hidden upper drop target falls back to the first visible upper lane")
    state.overlayTracks[1].isHidden = true
    motionRequire(WebMotionPresetDropPlan.resolve(time: 5, duration: 0.5, target: .main, state: state)?.target == .newOverlayTop,
                  "when every upper lane is hidden the drop creates a visible upper lane, never V1")
    motionRequire(WebMotionPresetDropPlan.resolve(time: 5, duration: 0.5, target: .insertOverlay(at: 1), state: state)?.target
                    == .insertOverlay(at: 1), "an explicit upper insertion seam preserves its new-lane policy")
    let invalid: [(Double, Double)] = [(-1, 1), (.nan, 1), (.infinity, 1), (1, 0), (1, -.infinity), (1, .nan)]
    motionRequire(invalid.allSatisfy { WebMotionPresetDropPlan.resolve(time: $0.0, duration: $0.1, target: .main, state: state) == nil },
                  "invalid drop times or durations never produce a landing plan")
}

@MainActor private func sourceLaneRejectsQueuedUI(_ fixture: MotionFixture, id: UUID) async throws {
    let project = fixture.project
    let baseline = project.state
    defer { project.applyDocumentRepair { $0 = baseline }; fixture.resetUndo() }
    project.applyDocumentRepair { $0.overlayTracks.append(EditLane(clips: [])) }
    let original = project.state.clip(with: id)!
    let editor = WebMotionEditorModel(project: project, clip: original)
    project.applyDocumentRepair { $0.relocateClip(id, to: .overlay(1), magnet: false) }
    let moved = project.state
    motionRequire(moved.clip(with: id) == original, "a pre-start UI vertical move keeps the complete expected clip value equal")
    try await withRendererSentinel(root: fixture.root) { marker in
        let success = await editor.render()
        motionRequire(!success && editor.isStale && project.state == moved && !project.ownUndoManager.canUndo,
                      "the inspector's source-lane snapshot refuses a pre-start vertical-only move")
        motionRequire(!FileManager.default.fileExists(atPath: marker.path),
                      "a stale source lane is refused before the UI launches any helper")
    }
}

@MainActor private func requestFollowsDestinationIdentity(_ fixture: MotionFixture, id: UUID) {
    let project = fixture.project
    let baseline = project.state
    defer { project.applyDocumentRepair { $0 = baseline }; fixture.resetUndo() }
    project.applyDocumentRepair { $0.overlayTracks.append(EditLane(clips: [])) }
    let tracks = project.state
    let destination = tracks.overlayTracks[1].id
    let request = WebMotionPresetRequest(templateID: "project:\(id.uuidString.lowercased())", at: 5,
                                         preferring: .overlay(1), project: project)
    project.applyDocumentRepair { $0.overlayTracks.swapAt(0, 1) }
    motionRequire(request.resolvedTarget(in: project.state) == .overlay(0)
                    && project.state.overlayTracks[0].id == destination,
                  "a queued UI request follows its destination UUID through a lane reorder")
    project.applyDocumentRepair { state in
        state = tracks
        state.overlayTracks.remove(at: 1)
        state.overlayTracks.append(EditLane(clips: []))
    }
    motionRequire(request.resolvedTarget(in: project.state) == .newOverlayTop,
                  "a removed UI destination cannot silently become the replacement lane at its old index")
    project.applyDocumentRepair { $0 = tracks; $0.overlayTracks[1].isHidden = true }
    motionRequire(request.resolvedTarget(in: project.state) == .newOverlayTop,
                  "a hidden UI destination uses a fresh upper lane")
    let insertion = WebMotionPresetRequest(templateID: request.templateID, at: 5, preferring: .insertOverlay(at: 1), project: project)
    let upper = WebMotionPresetRequest(templateID: request.templateID, at: 5, preferring: .newOverlayTop, project: project)
    motionRequire(insertion.resolvedTarget(in: project.state) == .insertOverlay(at: 1)
                    && upper.resolvedTarget(in: project.state) == .newOverlayTop,
                  "new and insert UI destinations retain their positional policies")
}

@MainActor private func withRendererSentinel(root: URL, _ body: (URL) async throws -> Void) async throws {
    let folder = root.appendingPathComponent("renderer-sentinel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let helper = folder.appendingPathComponent("helper")
    let marker = folder.appendingPathComponent("started")
    try Data("#!/bin/sh\n/usr/bin/touch \"${SRTFLOW_MOTION_EDITOR_MARKER}\"\nexit 99\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let previousHelper = ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_HELPER"]
    let previousMarker = ProcessInfo.processInfo.environment["SRTFLOW_MOTION_EDITOR_MARKER"]
    setenv("SRTFLOW_WEB_MOTION_HELPER", helper.path, 1)
    setenv("SRTFLOW_MOTION_EDITOR_MARKER", marker.path, 1)
    defer {
        if let previousHelper { setenv("SRTFLOW_WEB_MOTION_HELPER", previousHelper, 1) }
        else { unsetenv("SRTFLOW_WEB_MOTION_HELPER") }
        if let previousMarker { setenv("SRTFLOW_MOTION_EDITOR_MARKER", previousMarker, 1) }
        else { unsetenv("SRTFLOW_MOTION_EDITOR_MARKER") }
    }
    motionRequire(WebMotionRenderer.helperURL() == helper,
                  "the before-helper fixture points the real renderer at its executable marker helper")
    try await body(marker)
}
