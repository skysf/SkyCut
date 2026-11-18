import Foundation
import SrtFlowCore
import SrtFlowMCPKit
import SrtFlowWebMotionKit
@testable import SrtFlow

// The shipped designs use the real registry, locked helper and AI placement path. Small output sizes keep the finite
// two-render checks light; every default frame is compared, rather than comparing only names or source strings.
@MainActor func runMotionOfficialChecks(_ root: URL) async throws {
    let fixture = try MotionFixture(root: root.appendingPathComponent("official-motion"))
    let language = AppLanguageStore.shared.language
    defer {
        AppLanguageStore.shared.language = language
        _ = OpenProjects.shared.close(fixture.project)
    }
    AppLanguageStore.shared.language = .english
    fixture.project.applyDocumentRepair { $0.canvasRatio = .auto }
    let library = AIMotionSummary.library(fixture.project.state).arrayValue ?? []
    let ids = OfficialWebMotionTemplate.allCases.map(\.id)
    motionRequire(library.prefix(3).allSatisfy { $0["kind"] == "native" }
                    && library.dropFirst(3).prefix(3).compactMap { $0["id"]?.stringValue } == ids,
                  "the one library advertises all three official web designs immediately after native presets")
    motionRequire(library.filter { $0["origin"] == "official" }.allSatisfy { $0["tool"] == "set_motion" },
                  "official designs use the existing set_motion tool")
    var rendered: [OfficialWebMotionTemplate: WebMotionCache.Rendered] = [:]
    for template in OfficialWebMotionTemplate.allCases {
        let original = try template.record()
        try officialMetadataChecks(template, record: original, state: fixture.project.state)
        var record = original
        record.width = 320; record.height = 180
        let directory = WebMotionActions.cacheDirectory(for: fixture.project)
        let first = try await WebMotionCache.render(record, directory: directory, force: true)
        let second = try await WebMotionCache.render(record, directory: directory, force: true)
        for result in [first, second] {
            motionRequire(!result.cacheHit && result.result.accepted && result.result.frameCount == 96,
                          "\(template.id) renders all 96 default frames through a fresh helper")
            motionRequire(Set(result.result.checks.map(\.name)) == Set(WebMotionCheckName.allCases)
                            && result.result.checks.allSatisfy { $0.passed == true },
                          "\(template.id) passes all six page checks")
            motionRequire(result.result.transparent && result.result.pageErrors.isEmpty,
                          "\(template.id) carries alpha and has no page errors")
        }
        motionRequire(first.result.frameHashes.count == 96 && first.result.frameHashes == second.result.frameHashes,
                      "\(template.id) draws the same pixels in two independent complete renders")
        motionRequire(Set(first.result.frameHashes).count > 4,
                      "\(template.id) is an animated design rather than one repeated still")
        try await officialPreviewChecks(template, record: original)
        try await officialParameterRenderChecks(template, original: original, reference: first, fixture: fixture)
        rendered[template] = second
    }
    guard let first = rendered[.boxToEarth] else { throw AIToolError("The official box fixture did not render") }
    try await officialPlacementChecks(fixture, rendered: first)
    try officialLabelChecks()
}

@MainActor private func officialParameterRenderChecks(_ template: OfficialWebMotionTemplate, original: WebMotionClipRecord,
                                                     reference: WebMotionCache.Rendered, fixture: MotionFixture) async throws {
    let directory = WebMotionActions.cacheDirectory(for: fixture.project)
    var controlRecord = original
    controlRecord.width = 320; controlRecord.height = 180; controlRecord.fps = 4
    let control = try await WebMotionCache.render(controlRecord, directory: directory, force: true)
    officialRenderPassed(control, frames: 16, context: "\(template.id) four-fps control")
    let commonTimes = stride(from: 0, to: reference.result.frameHashes.count, by: 6).map { reference.result.frameHashes[$0] }
    motionRequire(control.result.frameHashes == commonTimes,
                  "\(template.id) four-fps control matches every same-time frame in its 24-fps render")
    // Shorten the duration so the common sample range contains its changed fade; extending a hold may preserve every earlier frame.
    var changes: [(String, JSONValue)] = [("text", "EXPEDITION"), ("font", "Helvetica"), ("color", "#3388CC"),
                                        ("duration", 3), ("hit", 1.25)]
    if template == .wordCollision { changes.append(("second_text", "DISCOVERY")) }
    for (key, value) in changes {
        let request = try AIMotionRequest(AIToolArguments(["template": .string(template.id), "parameters": .object([key: value])]),
                                          state: fixture.project.state, playhead: 0)
        var record = request.record
        record.width = 320; record.height = 180; record.fps = 4
        let result = try await WebMotionCache.render(record, directory: directory, force: true)
        officialRenderPassed(result, frames: Int(record.duration * 4), context: "\(template.id) changed \(key)")
        let count = min(control.result.frameHashes.count, result.result.frameHashes.count)
        let expectedCommonFrames = Int(min(controlRecord.duration, record.duration) * 4)
        motionRequire(count == expectedCommonFrames && count > 0
                        && result.result.frameHashes.prefix(count) != control.result.frameHashes.prefix(count),
                      "\(template.id) changing only \(key) changes pixels at a common render time")
    }
    var portrait = controlRecord
    portrait.width = 180; portrait.height = 320
    let result = try await WebMotionCache.render(portrait, directory: directory, force: true)
    officialRenderPassed(result, frames: 16, context: "\(template.id) portrait")
    motionRequire(result.record.width == 180 && result.record.height == 320 && result.result.transparent,
                  "\(template.id) actually renders its responsive portrait page with alpha")
}

@MainActor private func officialRenderPassed(_ rendered: WebMotionCache.Rendered, frames: Int, context: String) {
    motionRequire(!rendered.cacheHit && rendered.result.accepted && rendered.result.frameHashes.count == frames
                    && rendered.result.frameCount == frames,
                  "\(context) runs a fresh helper for every expected frame")
    motionRequire(Set(rendered.result.checks.map(\.name)) == Set(WebMotionCheckName.allCases)
                    && rendered.result.checks.allSatisfy { $0.passed == true },
                  "\(context) passes all six page checks")
}

@MainActor private func officialMetadataChecks(_ template: OfficialWebMotionTemplate, record: WebMotionClipRecord,
                                              state: TimelineState) throws {
    let values = try WebMotionParameters.readObject(record.parametersJSON)
    motionRequire(record.templateID == template.id && values == template.parameters
                    && values["duration"]?.doubleValue == record.duration && values["hit"]?.doubleValue == record.hitTime,
                  "\(template.id) defaults keep reserved duration/hit synchronized with source metadata")
    motionRequire(Set(record.parameterFields.map(\.key)) == Set(template.fieldLabelKeys.keys)
                    && !record.parameterFields.contains { ["duration", "hit"].contains($0.key) },
                  "\(template.id) exposes its editable words, font and colour without duplicate timing fields")
    motionRequire(WebMotionEnvironment.fonts(in: record).allSatisfy(WebMotionEnvironment.hasFont),
                  "\(template.id) defaults use installed fonts")
    try WebMotionValidation.validate(record)
    let request = try AIMotionRequest(AIToolArguments(["template": .string(template.id), "hit_at": 5]), state: state, playhead: 0)
    motionRequire(!request.needsPageApproval && request.record.page == record.page && request.record.templateID == template.id,
                  "\(template.id) is trusted bundled code resolved by the existing AI request")
    var portrait = state
    portrait.canvasRatio = .tall9x16
    portrait.frameRate = .fps30
    let fitted = try MotionPresetLibrary.template(template.id, in: portrait)
    motionRequire(fitted.width == 1080 && fitted.height == 1920 && fitted.fps == 30,
                  "\(template.id) adopts the destination canvas and frame rate")
    var changes: [String: JSONValue] = ["text": "EXPEDITION", "font": "Helvetica", "color": "#3388CC", "duration": 2.5, "hit": 0.4]
    if template == .wordCollision { changes["second_text"] = "DISCOVERY" }
    let edited = try AIMotionRequest(AIToolArguments(["template": .string(template.id), "parameters": .object(changes)]),
                                    state: state, playhead: 1)
    let editedValues = try WebMotionParameters.readObject(edited.record.parametersJSON)
    motionRequire(changes.allSatisfy { editedValues[$0.key] == $0.value }
                    && edited.record.duration == 2.5 && edited.record.hitTime == 0.4,
                  "\(template.id) accepts word, font, colour and timing parameters without rewriting the page")
}

@MainActor private func officialPlacementChecks(_ fixture: MotionFixture, rendered: WebMotionCache.Rendered) async throws {
    let project = fixture.project
    let placed = try await WebMotionActions.place(record: rendered.record, at: 2, project: project)
    motionRequire(placed.rendered.cacheHit && placed.clip.webMotion?.templateID == OfficialWebMotionTemplate.boxToEarth.id,
                  "an official source places through the shared checked cache path")
    AIAccessStore.shared.setMode(.ask)
    let before = project.state
    fixture.resetUndo()
    let added = try await fixture.completed(fixture.call(["template": .string(OfficialWebMotionTemplate.boxToEarth.id), "hit_at": 8]))
    motionRequire(!added.failed && added.payload["cache_hit"] == true && project.state.allClips.count == 2,
                  "one set_motion call places an official template without asking for AI-page approval")
    let addedClip = project.state.allClips.first { $0.id != placed.clip.id }
    motionRequire(addedClip.map { abs($0.timelineStart + 0.6 - 8) < 0.000001 } == true,
                  "the official template's local hit lands on the requested timeline second")
    let after = project.state
    project.ownUndoManager.undo()
    motionRequire(project.state == before && !project.ownUndoManager.canUndo, "an official AI insertion is one undo step")
    project.ownUndoManager.redo()
    motionRequire(project.state == after, "redo restores the official template insertion")
    fixture.resetUndo()
    let edited = try await fixture.completed(fixture.call(["clip_id": .string(placed.clip.id.uuidString),
        "parameters": ["text": "EXPEDITION", "font": "Helvetica", "color": "#3388CC", "duration": 2.5, "hit": 0.4]]))
    guard let changed = project.state.clip(with: placed.clip.id), let source = changed.webMotion else {
        throw AIToolError("The official parameter edit lost its clip")
    }
    motionRequire(!edited.failed && changed.id == placed.clip.id && changed.sourceURL != placed.clip.sourceURL
                    && source.duration == 2.5 && source.hitTime == 0.4 && changed.timelineStart == placed.clip.timelineStart,
                  "parameter changes re-render the same official clip while keeping its timeline start")
    motionRequire(project.saveNow(), "the project saves its edited official page and parameters")
    let loaded = try VideoEditProjectIO.load(from: project.documentURL!)
    let saved = loaded.timeline.clip(with: changed.id)?.webMotion
    motionRequire(saved?.page == source.page && saved?.parametersJSON == source.parametersJSON
                    && saved?.parameterFields == source.parameterFields && saved?.templateID == source.templateID
                    && saved?.name == source.name && saved?.duration == source.duration && saved?.hitTime == source.hitTime,
                  "the real project-file round trip preserves the official source and editable parameters")
    project.ownUndoManager.undo()
    motionRequire(project.state == after && !project.ownUndoManager.canUndo, "one undo restores all official parameters and its previous movie")
    project.ownUndoManager.redo()
    let reused = try await fixture.completed(fixture.call(["template": .string("project:\(changed.id.uuidString.lowercased())"), "at": 12]))
    motionRequire(!reused.failed && reused.payload["cache_hit"] == true && project.state.allClips.count == 3,
                  "an edited official clip is reusable as an independent project template")
    guard let reusedClip = project.state.allClips.first(where: { $0.id != changed.id && $0.id != addedClip!.id }),
          let reusedSource = reusedClip.webMotion else { throw AIToolError("The project-template copy is missing") }
    motionRequire(reusedSource.templateID == source.templateID && reusedSource.parametersJSON == source.parametersJSON,
                  "AI project-template reuse preserves the official source identity and independent parameters")
    let language = AppLanguageStore.shared.language
    AppLanguageStore.shared.language = .spanish
    motionRequire(OfficialWebMotionLabels.title(reusedSource) == L10n(OfficialWebMotionTemplate.boxToEarth.titleKey),
                  "a reused official template's default name still follows the UI language")
    for field in reusedSource.parameterFields {
        motionRequire(OfficialWebMotionLabels.field(field, record: reusedSource) == L10n(field.label),
                      "a reused official template's default field \(field.key) still follows the UI language")
    }
    AppLanguageStore.shared.language = language
    var custom = EditClip(sourceURL: changed.sourceURL, sourceDuration: changed.sourceDuration, timelineStart: 0)
    custom.webMotion = source
    custom.webMotion?.templateID = nil
    var customState = TimelineState()
    customState.overlayTracks = [EditLane(clips: [custom])]
    let customID = "project:\(custom.id.uuidString.lowercased())"
    let customRequest = try AIMotionRequest(AIToolArguments(["template": .string(customID)]), state: customState, playhead: 0)
    motionRequire(customRequest.record.templateID == customID,
                  "a custom project page without an origin still receives its project-template identity")
    let defaults = try MotionPresetLibrary.template(OfficialWebMotionTemplate.boxToEarth.id, in: project.state)
    motionRequire(defaults.parametersJSON == rendered.record.parametersJSON
                    && project.state.clip(with: addedClip!.id)?.webMotion?.parametersJSON == rendered.record.parametersJSON,
                  "editing a placement changes neither the bundled defaults nor another placement's parameters")
}

@MainActor private func officialLabelChecks() throws {
    AppLanguageStore.shared.language = .english
    let original = try OfficialWebMotionTemplate.wordCollision.record()
    for language in [AppLanguage.simplifiedChinese, .spanish] {
        AppLanguageStore.shared.language = language
        motionRequire(OfficialWebMotionLabels.title(original) == L10n(OfficialWebMotionTemplate.wordCollision.titleKey)
                        && OfficialWebMotionLabels.title(original) != original.name,
                      "an official default name follows \(language.rawValue) without rewriting the stored source")
        for field in original.parameterFields {
            motionRequire(OfficialWebMotionLabels.field(field, record: original) == L10n(field.label),
                          "official default field \(field.key) follows the current UI language")
        }
        let translated = try OfficialWebMotionTemplate.wordCollision.record()
        AppLanguageStore.shared.language = .english
        motionRequire(OfficialWebMotionLabels.title(translated) == original.name
                        && translated.parametersJSON == original.parametersJSON,
                      "a saved translated official name is recognized while authored parameter values stay unchanged")
    }
    var custom = original
    custom.name = "My Expedition"
    var field = original.parameterFields[0]
    field.label = "Brand wording"
    AppLanguageStore.shared.language = .spanish
    motionRequire(OfficialWebMotionLabels.title(custom) == "My Expedition"
                    && OfficialWebMotionLabels.field(field, record: custom) == "Brand wording",
                  "custom official-template names and field labels remain verbatim")
}
