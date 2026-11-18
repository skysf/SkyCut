import AppKit
import SwiftUI
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// PR B's real panel and web-motion inspector, in an isolated app with a synthetic project-owned page.
// No official template, user media, cloud request, input injection or native video export is involved.
@MainActor enum MotionPresetWebRender {
    static func render(out: URL) async throws {
        guard let folder = ProcessInfo.processInfo.environment["SRTFLOW_MOTION_RENDER_WORK"] else {
            throw AIToolError("The web-motion UI renderer needs its isolated work folder")
        }
        let work = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard let project = OpenProjects.shared.newProject(savingAs: work.appendingPathComponent("Field Notes.skycut"), placement: .background) else {
            throw AIToolError(OpenProjects.shared.failure ?? "Could not create the web-motion UI fixture")
        }
        defer { _ = OpenProjects.shared.close(project) }
        AISession.shared.setViewMode(.background, for: project)
        let placed = try await WebMotionActions.place(record: fixture(), at: 2, project: project)
        guard placed.rendered.result.checks.count == 6, placed.rendered.result.checks.allSatisfy({ $0.passed == true }),
              let source = placed.clip.webMotion else { throw AIToolError("The synthetic page did not pass all six checks") }
        project.selectedClipIDs = [placed.clip.id]
        guard await WebMotionMoviePoster.image(for: placed.clip.sourceURL, record: source) != nil else {
            throw AIToolError("The real rendered movie's poster could not be loaded")
        }
        try await renderLooks(project, clipID: placed.clip.id, source: source, out: out)
    }

    private static func renderLooks(_ project: VideoEditProject, clipID: UUID, source: WebMotionClipRecord, out: URL) async throws {
        let looks: [(String, AppTheme, NSAppearance?)] = [
            ("light", .forest, NSAppearance(named: .aqua)), ("dark", .classic, NSAppearance(named: .darkAqua))
        ]
        for (look, theme, appearance) in looks {
            AppThemeStore.shared.setTheme(theme)
            NSApp.appearance = appearance
            for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                AppLanguageStore.shared.language = language
                var record = source
                // These are authored fixture labels in each language, not automatic translation of a user's stored labels.
                record.parameterFields = fields()
                project.applyDocumentRepair { $0.update(clipID) { $0.webMotion = record } }
                guard let clip = project.state.clip(with: clipID) else { throw AIToolError("The UI fixture lost its motion clip") }
                func file(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(language.rawValue)-\(look).png") }
                let library = file("1-motion-library")
                try await Snapshot.take(MotionPresetPanel(project: project), to: library, appearance: appearance)
                try verifyPoster(in: library)
                try await parameterSection(project, clip: clip, to: file("2-web-parameters"), appearance: appearance)
                try await Snapshot.take(
                    VideoEditInspectorView(project: project, clock: project.clock, playhead: project.clock.whilePaused)
                        .frame(width: 252, height: 900),
                    to: file("3-web-inspector"), size: CGSize(width: 252, height: 900), appearance: appearance)
                var warning = record
                warning.provenance?.macOS = "Fixture older system"
                warning.provenance?.fonts = ["Unavailable Fixture Font"]
                project.applyDocumentRepair { $0.update(clipID) { $0.webMotion = warning } }
                if let warned = project.state.clip(with: clipID) {
                    try await parameterSection(project, clip: warned, to: file("4-web-portability-warning"), appearance: appearance)
                }
            }
        }
    }

    private static func parameterSection(_ project: VideoEditProject, clip: EditClip, to file: URL, appearance: NSAppearance?) async throws {
        try await Snapshot.take(
            WebMotionInspectorSection(project: project, clip: clip)
                .padding(14)
                .frame(width: 252, alignment: .topLeading)
                .background(AppThemePalette.current.panel),
            to: file, appearance: appearance)
    }

    private static func fields() -> [WebMotionParameterField] {
        [.init(key: "text", label: L10n("Text")), .init(key: "font", label: L10n("Font"), kind: .font),
         .init(key: "color", label: L10n("Colour"), kind: .color),
         .init(key: "number", label: L10n("Number"), kind: .number, minimum: 0, maximum: 99)]
    }

    // The synthetic fixture has a green title rectangle. A black cached player layer must fail the capture, not look like success.
    private static func verifyPoster(in file: URL) throws {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: file)) else {
            throw AIToolError("Could not read the captured motion library")
        }
        let scale = Double(bitmap.pixelsWide) / 380
        let left = Int(38 * scale), right = Int(138 * scale)
        let top = bitmap.pixelsHigh - Int(77 * scale), bottom = bitmap.pixelsHigh - Int(42 * scale)
        var green = 0, total = 0
        for y in top..<bottom {
            for x in left..<right {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if color.greenComponent > color.redComponent * 1.4,
                   color.greenComponent > color.blueComponent * 1.05, color.greenComponent > 0.14 { green += 1 }
            }
        }
        guard total > 0, green > total * 3 / 4 else {
            throw AIToolError("The idle movie poster is missing in \(file.lastPathComponent) (\(green)/\(total) green pixels)")
        }
        print("verified idle movie poster \(file.lastPathComponent): \(green)/\(total) green pixels")
    }

    private static func fixture() throws -> WebMotionClipRecord {
        .init(page: page, parametersJSON: try WebMotionParameters.canonical([
            "text": "FIELD NOTES", "font": "Avenir Next", "color": "#A5D9C3", "number": 42
        ]), name: "Field Notes", parameterFields: fields(), duration: 1.5, hitTime: 0.6, width: 960, height: 540, fps: 24)
    }

    // A simple transparent title and counter to show the four parameter controls, not a PR C design.
    private static let page = #"""
    <!doctype html><html><style>html,body{margin:0;background:transparent;overflow:hidden}canvas{display:block}</style>
    <canvas id="art"></canvas><script>
    const canvas=document.getElementById('art');
    canvas.width=MOTION_RENDER.width;canvas.height=MOTION_RENDER.height;
    const ctx=canvas.getContext('2d'), p=MOTION_PARAMS;
    window.motion={frame(t){
      const w=canvas.width,h=canvas.height;
      ctx.clearRect(0,0,w,h);ctx.setTransform(1,0,0,1,0,0);
      ctx.globalAlpha=Math.min(1,t/.2,(p.duration-t)/.2);
      ctx.fillStyle='#143e36';ctx.fillRect(w*.1,h*.19,w*.8,h*.62);
      ctx.strokeStyle=p.color;ctx.lineWidth=5;ctx.strokeRect(w*.1,h*.19,w*.8,h*.62);
      ctx.fillStyle=p.color;ctx.textAlign='center';
      ctx.font='500 104px "'+p.font+'"';ctx.fillText(p.text,w*.5,h*.46,w*.72);
      ctx.font='500 62px "'+p.font+'"';ctx.fillText(String(p.number)+' / EXPEDITION',w*.5,h*.63,w*.72);
    }};
    </script></html>
    """#
}
