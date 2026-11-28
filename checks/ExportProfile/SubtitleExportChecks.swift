import Foundation
import SrtFlowCore
@testable import SrtFlow

// The Burn In subtitle editor's Export As writes only the subtitle it was pressed for, unedited
// (docs/architecture/system-file-windows.md rule 9; docs/bugfixes/2026-11-28-subtitle-replace-writes-another-subtitle.md),
// through the panel's own calls (SubtitleEditorExport.exportAs / save) on real files, with a save window the check answers
// late; the production "Replace?" and "Could Not Save" alerts are answered by pressing their own buttons (SubtitleEditsBench):
// - the review's sequence: Export As for A, a file already at the typed name, A replaced by B in its place by the time
//   Replace is answered: nothing is written and the person is told (before, B's text went into the file chosen for A);
// - A edited while Replace is asked: nothing written; A unchanged: Replace writes A;
// - the save window answering after A was replaced in its place: nothing written, the free name stays free, and the person
//   is told in an app-level alert (seen even off the Burn In page); the preview moving to a video's row while A stays open
//   on its own exports A, nothing told;
// - the video's row gone while Replace is asked: nothing written (before, the standalone file's text went there);
// - Save writes its own file and marks the subtitle saved; an export in another format onto its own file leaves it unsaved
//   (the mark follows the drive, review CXM1);
// - every alert, "Replace?" included, comes from a run-loop turn, never inside a Swift task (review CXM1).
@MainActor enum SubtitleExportChecks {
    static func run(root: URL, source: URL, require: (Bool, String) -> Void) async {
        let lab = ExportLab(root: root, source: source)
        await reviewSequence(lab, require)
        await editedWhileAsked(lab, require)
        await unchanged(lab, require)
        await windowAfterSwitch(lab, require)
        await previewMovedToARow(lab, require)
        await rowGone(lab, require)
        await save(lab, require)
        await otherFormatOntoItsOwnFile(lab, require)
        require(!lab.bench.askedInTask && lab.bench.missingButtons.isEmpty,
                "every alert, Replace included, came from a run-loop turn, never inside a Swift task: inside a task \(lab.bench.askedInTask), missing \(lab.bench.missingButtons)")
        lab.restore()
    }

    private static let nothingWritten = L10n("Nothing was written: the subtitle changed. Export again.")

    /// Export As for A; a file is at the typed name (the helper's answer: nobody asked "Replace?"); A is replaced by B in its
    /// place while the question is up; Replace.
    private static func reviewSequence(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.standalone.open(lab.a)
        lab.export.exportAs(.srt, boundTo: nil)
        lab.bench.whileAsked = { lab.standalone.clear(); lab.standalone.open(lab.b) }
        lab.bench.replies = ["Replace"]
        lab.answer(SaveLocation(url: lab.taken, mayReplace: false))
        _ = await lab.bench.until { !lab.told.isEmpty }
        require(lab.untouched(lab.taken) && lab.replaceAsked == 1 && lab.told == [nothingWritten],
                "Replace answered after another subtitle took A's place writes nothing and says so: \(lab.shown(lab.taken)), told \(lab.told)")
    }

    private static func editedWhileAsked(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.standalone.open(lab.a)
        lab.export.exportAs(.srt, boundTo: nil)
        lab.bench.whileAsked = { lab.standalone.document?.cues[0].text = "Edited while asked"; lab.standalone.hasUnsavedEdits = true }
        lab.bench.replies = ["Replace"]
        lab.answer(SaveLocation(url: lab.taken, mayReplace: false))
        _ = await lab.bench.until { !lab.told.isEmpty }
        require(lab.untouched(lab.taken) && lab.told == [nothingWritten],
                "Replace answered after the subtitle was edited writes nothing and says so: \(lab.shown(lab.taken))")
    }

    private static func unchanged(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.standalone.open(lab.a)
        lab.export.exportAs(.srt, boundTo: nil)
        lab.bench.replies = ["Replace"]
        lab.answer(SaveLocation(url: lab.taken, mayReplace: false))
        let written = await lab.bench.until { lab.bench.text(lab.taken).contains("Line from A") }
        require(written && lab.replaceAsked == 1 && lab.told.isEmpty,
                "Replace for the subtitle still there, unedited, writes it: \(lab.shown(lab.taken)), told \(lab.told)")
    }

    /// Export As for A; while the save window is open, B takes A's place (the person may have left the Burn In page by then);
    /// the window answers a free name.
    private static func windowAfterSwitch(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.standalone.open(lab.a)
        lab.export.exportAs(.srt, boundTo: nil)
        lab.standalone.clear()
        lab.standalone.open(lab.b)
        let free = lab.bench.file("Free.srt")
        lab.answer(SaveLocation(url: free, mayReplace: false))
        _ = await lab.bench.until { !lab.told.isEmpty }
        require(!FileManager.default.fileExists(atPath: free.path) && lab.told == [nothingWritten],
                "a save window answered after another subtitle took A's place writes nothing there, and says so in an app-level alert: told \(lab.told)")
    }

    /// Export As for A open on its own; while the save window is open a video with B joins the queue, so the preview shows
    /// B's row; A is still open on its own, unedited.
    private static func previewMovedToARow(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.standalone.open(lab.a)
        lab.export.exportAs(.srt, boundTo: nil)
        lab.queue.add(urls: [lab.video], burnIn: BurnInRequest(subtitleURL: lab.b, document: lab.bench.load(lab.b)))
        let free = lab.bench.file("Free.srt")
        lab.answer(SaveLocation(url: free, mayReplace: false))
        let written = await lab.bench.until { lab.bench.text(free).contains("Line from A") }
        require(written && lab.told.isEmpty,
                "the preview moving to a video's row while A stays open on its own still exports A, nothing told: \(lab.shown(free))")
    }

    /// Export As for a video's subtitle A, the standalone file B open behind it; the video leaves the queue while Replace is
    /// asked.
    private static func rowGone(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.queue.add(urls: [lab.video], burnIn: BurnInRequest(subtitleURL: lab.a, document: lab.bench.load(lab.a)))
        guard let id = lab.queue.items.first?.id else { return require(false, "the video is queued") }
        lab.standalone.open(lab.b)
        lab.export.exportAs(.srt, boundTo: id)
        lab.bench.whileAsked = { lab.queue.remove(id: id) }
        lab.bench.replies = ["Replace"]
        lab.answer(SaveLocation(url: lab.taken, mayReplace: false))
        _ = await lab.bench.until { !lab.told.isEmpty }
        require(lab.untouched(lab.taken) && lab.told == [nothingWritten],
                "a video that left the queue while Replace was asked gets nothing written, nor does the standalone file: \(lab.shown(lab.taken))")
    }

    private static func save(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.standalone.open(lab.a)
        lab.standalone.document?.cues[0].text = "Saved line"
        lab.standalone.hasUnsavedEdits = true
        lab.export.save(boundTo: nil)
        let saved = await lab.bench.until { !lab.standalone.hasUnsavedEdits }
        require(saved && lab.bench.text(lab.a).contains("Saved line") && lab.told.isEmpty,
                "Save writes the subtitle to its own file and marks it saved: \(lab.shown(lab.a))")
    }

    /// A saved subtitle exported as WebVTT onto its own .srt name (a typed path): the drive no longer holds it.
    private static func otherFormatOntoItsOwnFile(_ lab: ExportLab, _ require: (Bool, String) -> Void) async {
        lab.reset()
        lab.standalone.open(lab.a)
        lab.export.exportAs(.vtt, boundTo: nil)
        lab.answer(SaveLocation(url: lab.a, mayReplace: true))
        let landed = await lab.bench.until { lab.bench.text(lab.a).hasPrefix("WEBVTT") }
        _ = await lab.bench.until { lab.standalone.hasUnsavedEdits }
        require(landed && lab.standalone.hasUnsavedEdits && lab.told.isEmpty,
                "an export in another format onto the subtitle's own file leaves it unsaved: the mark follows the drive")
    }
}

/// The export checks' bench: files A, B and a taken name; the panel's calls over a queue and the standalone file; a save
/// window the check answers; the alerts answered through SubtitleEditsBench.
@MainActor private final class ExportLab {
    let bench: SubtitleEditsBench
    let video: URL
    let a: URL, b: URL, taken: URL
    let standalone = StandaloneSubtitleStore.shared
    private(set) var queue = EncodeQueue(outputSuffix: "_subtitled", requiresSubtitles: true)
    private var window: ((SaveLocation) -> Void)?
    private let chooser = SubtitleEditorExport.chooseSaveLocation
    private let sentinel = "the file that was already there"

    init(root: URL, source: URL) {
        bench = SubtitleEditsBench(folder: root.appendingPathComponent("subtitle-export", isDirectory: true))
        a = bench.file("A.srt")
        b = bench.file("B.srt")
        taken = bench.file("Taken.srt")
        video = bench.file("video.mp4")
        if !FileManager.default.fileExists(atPath: video.path) { try? FileManager.default.copyItem(at: source, to: video) }
        SubtitleEditorExport.chooseSaveLocation = { [unowned self] _, _, then in window = then }
    }

    /// The panel's Save and Export As over this bench's queue and the standalone file.
    var export: SubtitleEditorExport { SubtitleEditorExport(subtitles: BurnInSubtitles(queue: queue, standalone: standalone)) }

    /// What the app-level "Could Not Save" alerts said, in order.
    var told: [String] {
        zip(bench.asked, bench.details).filter { $0.0 == L10n("Could Not Save") }.map(\.1)
    }

    /// How many times "Replace?" was asked about the taken file.
    var replaceAsked: Int { bench.asked.filter { $0 == String(format: L10n("Replace “%@”?"), taken.lastPathComponent) }.count }

    /// Fresh files, an empty queue, nothing open, asked or told.
    func reset() {
        standalone.clear()
        queue = EncodeQueue(outputSuffix: "_subtitled", requiresSubtitles: true)
        bench.forget()
        bench.write(a, "Line from A")
        bench.write(b, "Line from B")
        try? Data(sentinel.utf8).write(to: taken)
        try? FileManager.default.removeItem(at: bench.file("Free.srt"))
        window = nil
    }

    /// The open save window answers.
    func answer(_ location: SaveLocation) {
        let pending = window
        window = nil
        pending?(location)
    }

    func untouched(_ url: URL) -> Bool { bench.text(url) == sentinel }
    /// What is in the file, on one line (for the failure messages).
    func shown(_ url: URL) -> String { bench.text(url).replacingOccurrences(of: "\n", with: " / ") }

    func restore() {
        standalone.clear()
        SubtitleEditorExport.chooseSaveLocation = chooser
        bench.restore()
    }
}
