import Foundation
@testable import SrtFlow

// An untitled project whose only content is a marker on the ruler with its note is not empty: every way of closing it asks
// Save… / Discard / Cancel first (docs/bugfixes/2026-11-27-untitled-project-with-only-markers-closes-unasked.md). Before the
// fix it closed without asking and the marker and its note were gone. Real App objects and the production marker calls: a
// project window's close button (`closesAtOnce`), closing and New Project (`prepareToClose`, which Open / Open Recent and the
// AI's close_project ask too) and Quit (`ProjectQuit`, also Restart and Update) all ask; Cancel and a save that fails keep
// the project with its marker and note; Discard lets it go.
@MainActor enum UntitledMarkersChecks {
    static func run(_ checks: Checks, root: URL) async {
        let project = makeProject("Untitled with a ruler marker", in: root)
        await project.startNewProject()   // saved and clean: replaced at once by an untitled, empty document
        // Media in, a marker on the ruler with a note, the media out again: only the marker is left.
        _ = project.perform(rebuildsPreview: false) { state in
            state.mainClips = [EditClip(sourceURL: root.appendingPathComponent("Taken out again.mov"), sourceDuration: 4)]
        }
        project.addMarker(to: .ruler, atTimeline: 2)
        if let marker = project.state.rulerMarkers.first {
            project.setMarkerText(MarkerRef(owner: .ruler, markerID: marker.id), "Cut the intro here")
        }
        _ = project.perform(rebuildsPreview: false) { $0.mainClips = [] }
        let kept = project.state.rulerMarkers
        checks.require(project.isUntitled && project.state.allClips.isEmpty && kept.count == 1
                       && kept.first?.text == "Cut the intro here",
                       "an untitled project whose only content is a ruler marker with a note (\(kept.count) markers)")

        let untitled = ProjectCloseQuestions.untitled
        let saveLocation = ProjectCloseQuestions.saveLocation
        var asked = 0
        ProjectCloseQuestions.untitled = { _ in asked += 1; return .cancel }
        checks.require(!project.closesAtOnce(), "its window does not close at once: there is a question to ask first")
        let closing = await project.prepareToClose()
        checks.require(closing == .refused && asked == 1,
                       "closing it asks Save… / Discard / Cancel; Cancel keeps it (asked \(asked), \(closing))")
        await project.startNewProject()
        checks.require(asked == 2 && project.isUntitled && project.state.rulerMarkers == kept,
                       "New Project asks too; Cancel keeps the project, its marker and its note (asked \(asked))")
        let quits = await ProjectQuit.prepareAll()
        checks.require(!quits && asked == 3 && project.state.rulerMarkers == kept,
                       "Quit asks too; Cancel keeps SkyCut open with the marker (quits \(quits), asked \(asked))")

        ProjectCloseQuestions.untitled = { _ in asked += 1; return .save }
        ProjectCloseQuestions.saveLocation = { _ in
            SaveLocation(url: root.appendingPathComponent("No such folder/Marked.skycut"), mayReplace: false)
        }
        let failed = await project.prepareToClose()
        checks.require(failed == .refused && asked == 4 && project.isUntitled && project.state.rulerMarkers == kept,
                       "Save… to a place that can't be written keeps the project with its marker (\(failed))")

        ProjectCloseQuestions.untitled = { _ in asked += 1; return .discard }
        let discarded = await project.prepareToClose()
        checks.require(discarded == .ready && asked == 5, "Discard lets it go (\(discarded), asked \(asked))")
        _ = OpenProjects.shared.close(project)
        ProjectCloseQuestions.untitled = untitled
        ProjectCloseQuestions.saveLocation = saveLocation
    }
}
