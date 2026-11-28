import Foundation
import SrtFlowCore
@testable import SrtFlow

// Unsaved Burn In subtitle edits are never dropped without asking (docs/architecture/export-settings.md §9;
// docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md), through the page's own calls (BurnInSubtitleEdits:
// the row's ✕, Clear Finished, a row's Choose… and the page's drop) on a real queue and real files, the question answered by
// pressing the production alert's buttons (SubtitleEditsBench):
// - ✕ on a row with unsaved edits asks; Cancel keeps the row and its edits, Don't Save removes it and leaves its file, Save
//   writes the edits to its file and then removes it, a Save that fails asks again with the reason; a row without unsaved
//   edits goes at once;
// - Clear Finished asks about each finished row with unsaved edits; Cancel removes nothing, Don't Save lets them go;
// - another subtitle file for a row with unsaved edits asks; Cancel keeps it, Don't Save attaches the other file, Save writes
//   the old one first; the same file again asks too (Don't Save reads it from the drive), and without edits reads it at once;
// - an edit typed while Save writes is asked about again, never dropped; a later choice for the same video lands after the
//   earlier Save-then-attach, so it wins;
// - every question comes from a run-loop turn, never inside a Swift task.
@MainActor enum SubtitleEditsChecks {
    static func run(root: URL, source: URL, require: (Bool, String) -> Void) async {
        let bench = SubtitleEditsBench(folder: root.appendingPathComponent("subtitle-edits", isDirectory: true))
        let videos = (0..<2).map { bench.file("video \($0).mp4") }
        for video in videos where !FileManager.default.fileExists(atPath: video.path) {
            try? FileManager.default.copyItem(at: source, to: video)
        }
        await removeRow(bench, videos, require)
        await clearFinished(bench, videos, require)
        await anotherFile(bench, videos, require)
        await editDuringSave(bench, videos, require)
        require(!bench.askedInTask && bench.missingButtons.isEmpty,
                "every question came from a run-loop turn with Save / Don't Save / Cancel: inside a task \(bench.askedInTask), missing \(bench.missingButtons)")
        bench.restore()
    }

    /// A queue with one row per subtitle (a copy of the check's video each), and the page's edits over it.
    private static func page(_ bench: SubtitleEditsBench, _ videos: [URL], _ subtitles: [URL]) -> (EncodeQueue, [EncodeItem.ID], BurnInSubtitleEdits) {
        bench.forget()
        StandaloneSubtitleStore.shared.clear()
        for (name, line) in [("A.srt", "Line from A"), ("B.srt", "Line from B"), ("C.srt", "Line from C")] {
            bench.write(bench.file(name), line)
        }
        let queue = EncodeQueue(outputSuffix: "_subtitled", requiresSubtitles: true)
        for (video, subtitle) in zip(videos, subtitles) {
            queue.add(urls: [video], burnIn: BurnInRequest(subtitleURL: subtitle, document: bench.load(subtitle)))
        }
        return (queue, queue.items.map(\.id), BurnInSubtitleEdits(BurnInSubtitles(queue: queue, standalone: .shared)))
    }

    private static func edit(_ queue: EncodeQueue, _ id: EncodeItem.ID, _ line: String) {
        queue.editBurnInDocument(for: id) { $0.cues[0].text = line }
    }

    private static func burnIn(_ queue: EncodeQueue, _ id: EncodeItem.ID) -> BurnInRequest? {
        queue.items.first { $0.id == id }?.burnIn
    }

    private static func removeRow(_ bench: SubtitleEditsBench, _ videos: [URL], _ require: (Bool, String) -> Void) async {
        var (queue, ids, edits) = page(bench, videos, [bench.file("A.srt")])
        edit(queue, ids[0], "Edited A")
        bench.replies = ["Cancel"]
        edits.remove(ids[0])
        await bench.idle(edits)
        require(burnIn(queue, ids[0])?.document?.cues.first?.text == "Edited A" && burnIn(queue, ids[0])?.hasUnsavedEdits == true
                && bench.asked == [bench.question("A.srt")],
                "✕ on a row with unsaved edits asks first; Cancel keeps the row and its edits: asked \(bench.asked)")
        bench.replies = ["Don't Save"]
        edits.remove(ids[0])
        await bench.idle(edits)
        require(queue.items.isEmpty && bench.text(bench.file("A.srt")).contains("Line from A"),
                "Don't Save removes the row and leaves its file as it was: \(queue.items.count) rows")

        (queue, ids, edits) = page(bench, videos, [bench.file("A.srt")])
        edit(queue, ids[0], "Saved from the row")
        bench.replies = ["Save"]
        edits.remove(ids[0])
        await bench.idle(edits)
        require(queue.items.isEmpty && bench.text(bench.file("A.srt")).contains("Saved from the row"),
                "Save writes the row's edits to its subtitle file, then removes the row: \(bench.text(bench.file("A.srt")))")

        (queue, ids, edits) = page(bench, videos, [bench.file("A.srt")])
        edit(queue, ids[0], "Not saved: the drive refused")
        bench.gate.failing = true
        bench.replies = ["Save", "Cancel"]
        edits.remove(ids[0])
        await bench.idle(edits)
        bench.gate.failing = false
        require(queue.items.count == 1 && burnIn(queue, ids[0])?.hasUnsavedEdits == true && bench.asked.count == 2
                && bench.details.last?.contains(bench.failure(bench.file("A.srt"))) == true,
                "a Save that fails asks again with the reason, and Cancel keeps the row and its edits: \(bench.details.last ?? "nothing asked")")

        (queue, ids, edits) = page(bench, videos, [bench.file("A.srt")])
        edits.remove(ids[0])
        require(queue.items.isEmpty && bench.asked.isEmpty, "a row without unsaved edits goes at once, nothing asked")
    }

    private static func clearFinished(_ bench: SubtitleEditsBench, _ videos: [URL], _ require: (Bool, String) -> Void) async {
        let (queue, ids, edits) = page(bench, videos, [bench.file("A.srt"), bench.file("B.srt")])
        edit(queue, ids[0], "Edited A")
        ids.forEach(queue.cancel(id:))
        bench.replies = ["Cancel"]
        edits.clearFinished()
        await bench.idle(edits)
        require(queue.items.count == 2 && burnIn(queue, ids[0])?.hasUnsavedEdits == true && bench.asked == [bench.question("A.srt")],
                "Clear Finished asks about the finished row with unsaved edits only; Cancel removes nothing: \(queue.items.count) rows, asked \(bench.asked)")
        bench.replies = ["Don't Save"]
        edits.clearFinished()
        await bench.idle(edits)
        require(queue.items.isEmpty && bench.text(bench.file("A.srt")).contains("Line from A"),
                "Don't Save lets every finished row go, its file as it was: \(queue.items.count) rows")

        // Don't Save for the first row, Save for the second; the first is edited while the second is written.
        let (later, rows, laterEdits) = page(bench, videos, [bench.file("A.srt"), bench.file("B.srt")])
        edit(later, rows[0], "Given up")
        edit(later, rows[1], "Saved B")
        rows.forEach(later.cancel(id:))
        bench.gate.arm()
        bench.replies = ["Don't Save", "Save"]
        laterEdits.clearFinished()
        _ = await bench.until { bench.gate.isHolding }
        edit(later, rows[0], "Typed after Don't Save")
        bench.gate.open()
        await bench.idle(laterEdits)
        require(later.items.map(\.id) == [rows[0]] && burnIn(later, rows[0])?.document?.cues.first?.text == "Typed after Don't Save"
                && bench.text(bench.file("B.srt")).contains("Saved B"),
                "a finished row edited after its Don't Save, while another row's Save was written, stays with that edit; the saved row goes: \(later.items.count) rows")
    }

    private static func anotherFile(_ bench: SubtitleEditsBench, _ videos: [URL], _ require: (Bool, String) -> Void) async {
        let a = bench.file("A.srt"), b = bench.file("B.srt")
        let (queue, ids, edits) = page(bench, videos, [a])
        let id = ids[0]
        edit(queue, id, "Edited A")
        bench.replies = ["Cancel"]
        edits.attach(b, to: id)
        await bench.idle(edits)
        require(burnIn(queue, id)?.subtitleURL == a && burnIn(queue, id)?.document?.cues.first?.text == "Edited A"
                && bench.asked == [bench.question("A.srt")],
                "another file for a row with unsaved edits asks first; Cancel keeps its subtitle and edits: asked \(bench.asked)")
        bench.replies = ["Don't Save"]
        edits.attach(b, to: id)
        await bench.idle(edits)
        require(burnIn(queue, id)?.subtitleURL == b && burnIn(queue, id)?.document?.cues.first?.text == "Line from B"
                && burnIn(queue, id)?.hasUnsavedEdits == false && bench.text(a).contains("Line from A"),
                "Don't Save: the other file takes its place and the old file is as it was")
        edit(queue, id, "Edited B")
        bench.replies = ["Save"]
        edits.attach(a, to: id)
        await bench.idle(edits)
        require(bench.text(b).contains("Edited B") && burnIn(queue, id)?.subtitleURL == a,
                "Save writes the old subtitle's edits to its file first, then the other file takes its place: \(bench.text(b))")
        edit(queue, id, "Edited A again")
        bench.forget()
        bench.replies = ["Don't Save"]
        edits.attach(a, to: id)
        await bench.idle(edits)
        require(burnIn(queue, id)?.document?.cues.first?.text == "Line from A" && burnIn(queue, id)?.hasUnsavedEdits == false
                && bench.asked == [bench.question("A.srt")],
                "the same file again for a row with unsaved edits asks too; Don't Save reads it from the drive: asked \(bench.asked)")
        bench.write(a, "Changed elsewhere")
        edits.attach(a, to: id)
        require(burnIn(queue, id)?.document?.cues.first?.text == "Changed elsewhere" && bench.asked.count == 1,
                "without unsaved edits the same file is read again at once, nothing asked")
    }

    private static func editDuringSave(_ bench: SubtitleEditsBench, _ videos: [URL], _ require: (Bool, String) -> Void) async {
        let a = bench.file("A.srt"), b = bench.file("B.srt"), c = bench.file("C.srt")
        var (queue, ids, edits) = page(bench, videos, [a])
        edit(queue, ids[0], "First edit")
        bench.gate.arm()
        bench.replies = ["Save", "Cancel"]
        edits.attach(b, to: ids[0])
        let held = await bench.until { bench.gate.isHolding }
        edit(queue, ids[0], "Typed while it was saved")
        bench.gate.open()
        await bench.idle(edits)
        require(held && burnIn(queue, ids[0])?.subtitleURL == a && burnIn(queue, ids[0])?.document?.cues.first?.text == "Typed while it was saved"
                && burnIn(queue, ids[0])?.hasUnsavedEdits == true && bench.asked.count == 2,
                "an edit typed while Save writes is asked about again (Cancel keeps it) and the other file is not attached: asked \(bench.asked.count)")

        (queue, ids, edits) = page(bench, videos, [a])
        edit(queue, ids[0], "Edited A")
        bench.gate.arm()
        bench.replies = ["Save"]
        edits.attach(b, to: ids[0])
        _ = await bench.until { bench.gate.isHolding }
        edits.attach(c, to: ids[0])
        bench.gate.open()
        await bench.idle(edits)
        require(burnIn(queue, ids[0])?.subtitleURL == c && bench.text(a).contains("Edited A"),
                "a later choice for the same video lands after the earlier Save-then-attach, so it wins: \(burnIn(queue, ids[0])?.subtitleURL?.lastPathComponent ?? "nil")")
    }
}
