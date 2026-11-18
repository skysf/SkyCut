import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import SrtFlowCore
@testable import SrtFlow

// The real shared library, official parameter forms and decoded frames from the bundled checked preview movies.
// Uses an isolated background project; no user media, cloud request, input injection or page execution occurs here.
@MainActor
enum MotionPresetOfficialRender {
    private struct Source {
        var template: OfficialWebMotionTemplate
        var record: WebMotionClipRecord
        var movie: URL
    }

    static func render(out: URL) async throws {
        guard let folder = ProcessInfo.processInfo.environment["SRTFLOW_MOTION_RENDER_WORK"] else {
            throw AIToolError("The official-motion UI renderer needs its isolated work folder")
        }
        let work = URL(fileURLWithPath: folder, isDirectory: true)
        guard let project = OpenProjects.shared.newProject(savingAs: work.appendingPathComponent("Official Motions.skycut"), placement: .background) else {
            throw AIToolError(OpenProjects.shared.failure ?? "Could not create the official-motion UI fixture")
        }
        defer { _ = OpenProjects.shared.close(project) }
        AISession.shared.setViewMode(.background, for: project)
        AppLanguageStore.shared.language = .english
        var sources: [Source] = []
        for template in OfficialWebMotionTemplate.allCases {
            let record = try await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try template.record() } }.get()
            guard let movie = template.previewURL,
                  await WebMotionMoviePoster.image(for: movie, record: record) != nil else {
                throw AIToolError("The official template preview is missing or undecodable: \(template.rawValue)")
            }
            sources.append(Source(template: template, record: record, movie: movie))
        }
        try await renderLooks(project, sources: sources, out: out)
        for source in sources { try await frames(source, work: work, out: out) }
    }

    private static func renderLooks(_ project: VideoEditProject, sources: [Source], out: URL) async throws {
        let looks: [(String, AppTheme, NSAppearance?)] = [
            ("light", .forest, NSAppearance(named: .aqua)), ("dark", .classic, NSAppearance(named: .darkAqua))
        ]
        for (look, theme, appearance) in looks {
            AppThemeStore.shared.setTheme(theme)
            NSApp.appearance = appearance
            for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                AppLanguageStore.shared.language = language
                func file(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(language.rawValue)-\(look).png") }
                var empty = TimelineState()
                empty.canvasRatio = .wide16x9
                project.replaceStateForDocument(empty)
                project.clearSelection()
                try await Snapshot.take(MotionPresetPanel(project: project), to: file("5-official-library"), appearance: appearance)
                let official = MotionPresetLibrary.entries(in: empty).filter { if case .official = $0 { return true }; return false }
                try await Snapshot.take(
                    MotionPresetLibraryRows(project: project, entries: official)
                        .padding(14).frame(width: 380).background(AppThemePalette.current.panel),
                    to: file("6-official-template-cards"), appearance: appearance)
                for source in sources {
                    // Stored English defaults deliberately remain unchanged while the UI language switches.
                    var clip = EditClip(sourceURL: source.movie, sourceDuration: source.record.duration, timelineStart: 0)
                    clip.webMotion = source.record
                    var state = empty
                    state.overlayTracks = [EditLane(clips: [clip])]
                    project.replaceStateForDocument(state)
                    project.selectedClipIDs = [clip.id]
                    try await Snapshot.take(
                        WebMotionInspectorSection(project: project, clip: clip)
                            .padding(14).frame(width: 252, alignment: .topLeading)
                            .background(AppThemePalette.current.panel),
                        to: file("7-official-\(source.template.rawValue)-parameters"), appearance: appearance)
                    try await clipNames(project, clip: clip,
                                        inspector: file("9-official-\(source.template.rawValue)-inspector"),
                                        timeline: file("10-official-\(source.template.rawValue)-timeline"), appearance: appearance)
                }
            }
        }
    }

    private static func clipNames(_ project: VideoEditProject, clip: EditClip,
                                  inspector: URL, timeline: URL, appearance: NSAppearance?) async throws {
        try await Snapshot.take(
            VideoEditInspectorView(project: project, clock: project.clock, playhead: project.clock.whilePaused)
                .frame(width: 252, height: 900),
            to: inspector, size: CGSize(width: 252, height: 900), appearance: appearance)
        try await Snapshot.take(
            ClipBlockView(clip: clip, slot: .overlay(0), height: 72, pps: 80, isSelected: true,
                          drag: TimelineDragBox(), isDragMember: false,
                          context: ClipBlockContext(slot: .overlay(0), project: project), project: project,
                          onDragBegin: {}, onDragChange: { _, _ in }, onDragEnd: {}, onTrim: { _, _ in },
                          onTrimEnd: {}, onMarkerPeek: { _ in })
                .equatable().padding(8).background(AppThemePalette.current.panel),
            to: timeline, size: CGSize(width: 336, height: 88), appearance: appearance)
    }

    private static func frames(_ source: Source, work: URL, out: URL) async throws {
        let record = source.record
        let span = record.duration - record.hitTime
        let grid = FrameGrid(fps: record.fps)
        let times: [Double]
        if source.template == .wordCollision {
            let impact = grid.time(ofFrame: grid.frame(containing: record.hitTime) + 1)
            times = [max(0, record.hitTime - 0.2), impact, record.hitTime + 0.45,
                     record.duration - grid.time(ofFrame: 1)]
        } else {
            times = [record.hitTime + 0.12, record.hitTime + span * 0.25,
                     record.hitTime + span * 0.55, record.hitTime + span * 0.8]
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.movie))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 360)
        var files: [URL] = []
        var labels: [String] = []
        for (index, requested) in times.enumerated() {
            let time = grid.time(ofFrame: grid.frame(containing: requested))
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let file = work.appendingPathComponent("\(source.template.rawValue)-frame-\(index).png")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw AIToolError("Could not prepare the official preview frame")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw AIToolError("Could not write the official preview frame") }
            files.append(file)
            labels.append(String(format: "t = %.3f s (hit %.2f s)", time, record.hitTime))
        }
        let sheet = out.appendingPathComponent("8-official-\(source.template.rawValue)-frames.png")
        try ContactSheet.write(rows: files.map { [$0] }, labels: labels,
                               columns: [source.template.titleKey], to: sheet)
        print("rendered \(sheet.lastPathComponent)")
    }
}
