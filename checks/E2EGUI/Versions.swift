import AppKit
import SwiftUI
import SrtFlowCore
@testable import SrtFlow

// Press the real Go Back button in a mounted Versions sheet and verify the project's undo stack.
@MainActor enum VersionsGUI {
    static func check(_ project: VideoEditProject) async throws {
        var previous = TimelineState()
        previous.textOverlays = [TextOverlay(text: "Earlier title", timelineStart: 0, duration: 3, row: 0)]
        project.restoreTimeline(previous)
        let store = ProjectVersionStore.for(project)
        guard store.save(project.state, kind: .afterRound).version?.id == "v1" else {
            throw CheckFailure("Could not write the version fixture")
        }
        project.perform { $0.textOverlays[0].text = "Current title" }
        project.effectiveUndoManager?.removeAllActions()

        let sheet = try CheckWindow(ProjectVersionsSheet(project: project), width: 440, height: 280)
        defer { sheet.close() }
        _ = try await sheet.text("Versions")
        try await sheet.click("Go Back")
        try await sheet.wait("Versions to restore the chosen cut") {
            project.state.textOverlays.first?.text == "Earlier title"
        }
        guard project.effectiveUndoManager?.canUndo == true else {
            throw CheckFailure("Restoring a version did not leave an undo step")
        }
        project.effectiveUndoManager?.undo()
        guard project.state.textOverlays.first?.text == "Current title" else {
            throw CheckFailure("One undo did not return to the cut left by Go Back")
        }
        print("GUI Versions: opened the sheet, restored a version, then returned with one undo")
    }
}
