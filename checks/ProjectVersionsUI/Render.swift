import AppKit
import SwiftUI
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Off-screen renders of the saved-versions UI (scripts/render-project-versions.sh), for the PR's images: the Versions sheet with
// six versions and with none, and the AI banner's details naming the version from before the round — in English, Simplified Chinese
// and Spanish, in the forest theme (always light) and the classic theme on a dark system. Only images, no verdicts: the behavior is
// pinned by scripts/check-project-versions.sh. Temporary projects, media and versions root; nothing of the user's is touched.

@main enum ProjectVersionsRender {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.projectversionsrender"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("The versions render requires its isolated bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["SRTFLOW_VERSIONS_RENDER_OUT"]!)
        let work = URL(fileURLWithPath: environment["SRTFLOW_VERSIONS_RENDER_WORK"]!).resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let scene = try RenderScene(work: work)
            for (look, theme, dark) in [("forest", AppTheme.forest, false), ("classic-dark", AppTheme.classic, true)] {
                AppThemeStore.shared.setTheme(theme)
                // Only this process's appearance (as checks/ThemeSwitch does): the user's system setting is not touched.
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                    AppLanguageStore.shared.language = language
                    func file(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(language.rawValue)-\(look).png") }
                    try await Snapshot.take(ProjectVersionsSheet(project: scene.trip), to: file("1-versions"))
                    try await Snapshot.take(ProjectVersionsSheet(project: scene.untouched), to: file("2-no-versions"))
                    try await Snapshot.take(AIActivityDetails(project: scene.edited) {}, to: file("3-ai-details"))
                }
            }
        } catch {
            print("FAIL: versions render: \(error)")
            exit(1)
        }
        print("PASS: rendered the versions UI in en, zh-Hans and es (forest, classic dark) to \(out.path)")
        exit(0)
    }
}

/// Three headless projects: one with six versions from a day of AI rounds, one without any, one whose round just ended.
@MainActor
private struct RenderScene {
    let trip: VideoEditProject
    let untouched: VideoEditProject
    let edited: VideoEditProject

    init(work: URL) throws {
        let media = work.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let clip = media.appendingPathComponent("glacier.mp4")
        try Data("placeholder".utf8).write(to: clip)
        var state = TimelineState()
        state.mainClips = [EditClip(sourceURL: clip, sourceDuration: 8, timelineStart: 0)]
        state.textOverlays = [TextOverlay(text: "South Pole", timelineStart: 0, duration: 3, row: 0)]
        state.assignMissingTrackColors()
        trip = try Self.project("Trip to the South Pole.skycut", in: work, state: state)
        untouched = try Self.project("Interview.skycut", in: work, state: state)
        edited = try Self.project("Teaser.skycut", in: work, state: state)

        // A day of rounds: v1 before the first round … v6 after the afternoon's round.
        let kinds: [(ProjectVersionKind, Int, Int)] = [(.beforeRound, 9, 58), (.afterRound, 10, 15), (.beforeGoingBack, 10, 21),
                                                       (.afterRound, 10, 40), (.beforeRound, 14, 3), (.afterRound, 14, 20)]
        let store = ProjectVersionStore.for(trip)
        let today = Calendar.current.startOfDay(for: Date())
        for (index, (kind, hour, minute)) in kinds.enumerated() {
            state.textOverlays[0].text = "South Pole \(index + 1)"
            guard let version = store.save(state, kind: kind).version else { throw AIToolError("could not seed \(kind)") }
            let time = today.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: version.url.path)
        }
        store.refresh()

        // A finished round of 23 changes by Claude Code: its first change saved the start as v1.
        let round = AISession.shared.round(for: edited)
        round.noteCall(client: "claude-code")
        round.beginIfNeeded(project: edited)
        for index in 0..<23 {
            _ = AIUndoGrouping.step(edited.effectiveUndoManager) { edited.perform { $0.textOverlays[0].text = "Teaser \(index)" } }
            round.noteChange()
        }
        round.finishRound()
    }

    private static func project(_ name: String, in folder: URL, state: TimelineState) throws -> VideoEditProject {
        guard let project = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent(name), placement: .background) else {
            throw AIToolError("could not create \(name)")
        }
        project.restoreTimeline(state)
        project.effectiveUndoManager?.removeAllActions()
        _ = project.saveNow()
        return project
    }
}
