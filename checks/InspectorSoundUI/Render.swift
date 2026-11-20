import AppKit
import SwiftUI
import SrtFlowCore
@testable import SrtFlow

// Off-screen renders of the clip inspector's sound section (scripts/render-inspector-sound.sh), for a look before merging
// a change to it: Volume, the voice band and the sound scene of a shot with its own sound, with the voice band off and at
// −10 dB (as the AI sets it, with a Room scene), in English, Simplified Chinese and Spanish, in the forest theme (always light)
// and the classic theme on a dark system, in the narrowest inspector column (252 pt, 14 pt padding); plus the whole clip
// inspector (forest) at the column's default width (290 pt) to show where the section sits. Only images, no verdicts: the
// voice band's behavior is pinned by scripts/check-audio-engine.sh and scripts/check-project-file.sh
// (docs/architecture/sound-scenes.md section 5). Nothing of the user's is touched (isolated bundle id, a headless project,
// a placeholder media file in a temporary folder).

@main enum InspectorSoundRender {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.inspectorsoundrender"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("The inspector sound render requires its isolated bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["SRTFLOW_INSPECTOR_SOUND_RENDER_OUT"]!)
        let work = URL(fileURLWithPath: environment["SRTFLOW_INSPECTOR_SOUND_RENDER_WORK"]!).resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let project = OpenProjects.shared.primary
            let shot = try placeShot(in: project, work: work)
            let looks: [(name: String, theme: AppTheme, appearance: NSAppearance?)] = [
                ("forest", .forest, NSAppearance(named: .aqua)), ("classic-dark", .classic, NSAppearance(named: .darkAqua))
            ]
            for look in looks {
                AppThemeStore.shared.setTheme(look.theme)
                // Only this process's appearance (as checks/ThemeSwitch does): the user's system setting is not touched.
                NSApp.appearance = look.appearance
                for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                    AppLanguageStore.shared.language = language
                    func file(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(language.rawValue)-\(look.name).png") }
                    set(shot, voiceBand: 0, scene: nil, in: project)
                    try await Snapshot.take(SoundPane(project: project, id: shot), to: file("1-voice-band-off"), appearance: look.appearance)
                    set(shot, voiceBand: -10, scene: .room, in: project)
                    try await Snapshot.take(SoundPane(project: project, id: shot), to: file("2-voice-band-10db"), appearance: look.appearance)
                    if look.name == "forest" {
                        project.select(shot, additive: false)
                        try await Snapshot.take(WholeInspector(project: project), to: file("3-clip-inspector"),
                                                size: CGSize(width: 290, height: 1100), appearance: look.appearance)
                        project.clearSelection()
                    }
                }
            }
        } catch {
            print("FAIL: inspector sound render: \(error)")
            exit(1)
        }
        print("PASS: rendered the clip inspector's sound section in en, zh-Hans and es (forest, classic dark) to \(out.path)")
        exit(0)
    }

    /// One 8-second 1080p shot with its own sound on the main track (a placeholder file: nothing here reads media).
    @MainActor
    private static func placeShot(in project: VideoEditProject, work: URL) throws -> UUID {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let media = work.appendingPathComponent("Shot4.mp4")
        try Data("placeholder".utf8).write(to: media)
        let info = MediaInfo(duration: 8, displaySize: CGSize(width: 1920, height: 1080), frameRate: 30, videoCodec: "h264",
                             audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 12_000_000)
        let clip = EditClip(sourceURL: media, sourceDuration: 8, info: info)
        var state = TimelineState()
        state.mainClips = [clip]
        project.perform(rebuildsPreview: false) { $0 = state }
        return clip.id
    }

    @MainActor
    private static func set(_ id: UUID, voiceBand: Double, scene: SoundSceneKind?, in project: VideoEditProject) {
        project.perform(rebuildsPreview: false) { state in
            state.update(id) { $0.voiceBandDB = voiceBand }
            state.setSoundSceneKind(scene, for: [id])
        }
    }
}

/// The sound section as the inspector lays it out in its narrowest column (252 wide, 14 padding).
private struct SoundPane: View {
    let project: VideoEditProject
    let id: UUID

    var body: some View {
        if let clip = project.state.clip(with: id) {
            ClipSoundSection(project: project, clip: clip, location: project.state.location(of: id), playhead: clip.timelineStart)
                .padding(14)
                .frame(width: 252, alignment: .topLeading)
                .background(AppThemePalette.current.panel)
        }
    }
}

/// The whole inspector with the shot selected, at the column's default width (VideoEditView: idealWidth 290).
private struct WholeInspector: View {
    let project: VideoEditProject

    var body: some View {
        VideoEditInspectorView(project: project, clock: project.clock, playhead: project.clock.whilePaused)
            .frame(width: 290, alignment: .topLeading)
    }
}
