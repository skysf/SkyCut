import AppKit
import SwiftUI
import SrtFlowCore
import SrtFlowMCPKit
import SrtFlowWebMotionKit
@testable import SrtFlow

// Operate the native and web motion cards and their production inspectors in hosted windows.
@MainActor enum MotionGUI {
    static func native(_ project: VideoEditProject) async throws {
        let panel = try CheckWindow(MotionPresetPanel(project: project), width: 380, height: 600)
        defer { panel.close() }
        _ = try await panel.text("Motion Presets")
        try await panel.click(MotionPresetKind.frameReveal.title)
        guard let title = project.state.textOverlays.first(where: { $0.motionPreset?.role == .title }),
              let members = MotionPresetGroups.members(ofText: title.id, in: project.state),
              members.kind == .frameReveal, !project.state.shapes.isEmpty else {
            throw CheckFailure("Clicking the native preset card did not add its text and shapes")
        }
        let inspector = VideoEditInspectorView(project: project, clock: project.clock, playhead: project.clock.whilePaused)
        let animation = try CheckWindow(inspector.textAnimationSection(title).padding(12), width: 252, height: 340)
        defer { animation.close() }
        _ = try await animation.text("Animation")
        _ = try await animation.text("Preset")
        _ = try await animation.text("Hit at")
        print("GUI native motion: added a card and found its Preset and Hit at rows in Animation")
    }

    static func web(_ project: VideoEditProject, page: String) async throws {
        let ink = "#DE18B0"
        let changedInk = "#20BC48"
        let record = WebMotionClipRecord(
            page: page, parametersJSON: try WebMotionParameters.canonical(["ink": .string(ink)]), name: "Ink Plate",
            parameterFields: [.init(key: "ink", label: "Ink", kind: .color)], duration: 0.5, hitTime: 0.25,
            width: 320, height: 180, fps: 24
        )
        let frames = WebMotionRequest.frameCount(duration: record.duration, fps: record.fps)
        let watch = WebMotionHelperProcess.Watch()
        let renderWait = Duration.seconds(WebMotionLimits.standard(frames: frames).total
            + watch.grace + watch.teardownGrace + 10)
        note("Rendering the initial web-motion movie (\(frames) frames)")
        let started = ContinuousClock.now
        _ = try await WebMotionActions.place(record: record, at: 0, project: project)
        note("Initial web-motion movie rendered after \(ContinuousClock.now - started)")
        let entries = MotionPresetLibrary.entries(in: project.state).filter {
            if case .web = $0 { return true }
            return false
        }
        guard entries.count == 1 else { throw CheckFailure("The rendered project motion did not appear in its library") }

        project.seekFromTimeline(time: 0.25)
        let cards = MotionPresetLibraryRows(project: project, entries: entries).padding(12)
        let panel = try CheckWindow(cards, width: 380, height: 230)
        defer { panel.close() }
        try await panel.click("Ink Plate")
        try await panel.wait("the saved web-motion card to place a second clip", timeout: renderWait) {
            project.state.allClips.filter { $0.webMotion != nil }.count == 2
        }
        guard let clip = project.state.allClips.first(where: { $0.webMotion != nil && $0.timelineStart == 0.25 }) else {
            throw CheckFailure("The web motion did not land at the playhead")
        }
        project.selectedTextIDs = []
        project.selectedClipIDs = [clip.id]
        let inspector = VideoEditInspectorView(project: project, clock: project.clock, playhead: project.clock.whilePaused)
        let check = try CheckWindow(inspector, width: 252, height: 770)
        defer { check.close() }
        _ = try await check.text("Motion Template")
        try check.type(changedInk, replacing: ink)
        try await check.click("Re-render")
        try await check.wait("Re-render to replace the selected clip with the changed ink", timeout: renderWait) {
            guard let replaced = project.state.clip(with: clip.id), let motion = replaced.webMotion else { return false }
            return WebMotionParameters.object(motion.parametersJSON)["ink"] == .string(changedInk)
                && replaced.sourceURL != clip.sourceURL
                && replaced.timelineStart == clip.timelineStart
        }
        project.effectiveUndoManager?.undo()
        guard project.state.clip(with: clip.id)?.sourceURL == clip.sourceURL else {
            throw CheckFailure("One undo did not return to the original web motion movie")
        }
        print("GUI web motion: placed a library card, edited the inspector and re-rendered the same clip")
    }
}
