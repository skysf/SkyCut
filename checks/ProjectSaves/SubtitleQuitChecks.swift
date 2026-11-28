import Foundation
import SrtFlowCore
@testable import SrtFlow

// Quit (and Restart and Update, which quits the same way) asks about every Burn In subtitle with unsaved edits, on the path
// that asks about projects (ProjectQuit; docs/architecture/export-settings.md §9;
// docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md). Real App objects: the Burn In queue's row and the
// standalone file, each with unsaved edits; the question answered by pressing the production alert's buttons
// (SubtitleEditsBench):
// - Quit no longer quits at once; Cancel stays (Restart and Update is told) and keeps both edits;
// - Don't Save for each lets the quit go on and writes nothing;
// - a Save whose drive does not answer within Quit's grace is asked about again with Keep Waiting / Cancel only (Cancel
//   stays), and the write that lands later still marks the subtitle saved; Save writes the other one to its file first;
// - a page ✕ whose Save is still being written when Quit comes: Quit asks once (Keep Waiting / Cancel); after Cancel the
//   page's action stands down (nothing more asked, the video stays) and the late write still saves (review CXM1);
// - a time still being typed in a cell, the only edit, is written first by Quit and asked about, through quitsAtOnce
//   (applicationShouldTerminate) and through prepareAll alone (after a screen recording);
// - the questions come from a run-loop turn, never inside a Swift task.
@MainActor enum SubtitleQuitChecks {
    static func run(_ checks: Checks, root: URL) async {
        let bench = SubtitleEditsBench(folder: root.appendingPathComponent("subtitle-quit", isDirectory: true))
        // Any project left open is let go without a real alert: only the subtitles are asked here.
        let untitled = ProjectCloseQuestions.untitled, drive = ProjectQuit.askAboutDrive, cancelled = ProjectQuit.quitCancelled
        ProjectCloseQuestions.untitled = { _ in .discard }
        ProjectQuit.askAboutDrive = { _ in .quitAnyway }
        let queue = EncodeQueue.burnIn, standalone = StandaloneSubtitleStore.shared
        let a = bench.write(bench.file("A.srt"), "Line from A"), b = bench.write(bench.file("B.srt"), "Line from B")
        let nothingBefore = !BurnInSubtitleEdits.shared.needsAsking(after: BurnInSubtitleEdits.Discarded())
        queue.add(urls: [bench.file("video.mp4")], burnIn: BurnInRequest(subtitleURL: a, document: bench.load(a)))
        guard let id = queue.items.last?.id else { return checks.require(false, "the Burn In queue takes the video") }
        queue.editBurnInDocument(for: id) { $0.cues[0].text = "Row edit" }
        standalone.open(b)
        standalone.document?.cues[0].text = "Standalone edit"
        standalone.hasUnsavedEdits = true
        checks.require(nothingBefore && !ProjectQuit.quitsAtOnce(), "unsaved Burn In subtitles keep Quit from quitting at once")

        var told = false
        ProjectQuit.quitCancelled = { told = true }
        bench.replies = ["Cancel"]
        let stayed = await ProjectQuit.prepareAll()
        checks.require(!stayed && told && bench.asked == [bench.question("A.srt")] && rowText(queue, id) == "Row edit"
                       && standalone.document?.cues.first?.text == "Standalone edit" && standalone.hasUnsavedEdits,
                       "Quit asks about the first subtitle with unsaved edits; Cancel stays, Restart and Update is told, both edits are kept: asked \(bench.asked)")

        bench.forget()
        bench.replies = ["Don't Save", "Don't Save"]
        let discarded = await ProjectQuit.prepareAll()
        checks.require(discarded && bench.asked == [bench.question("A.srt"), bench.question("B.srt")]
                       && bench.text(a).contains("Line from A") && bench.text(b).contains("Line from B"),
                       "Don't Save for each lets Quit go on and writes nothing: asked \(bench.asked)")

        bench.forget()
        bench.gate.arm()
        bench.replies = ["Save", "Cancel"]
        let stuck = await ProjectQuit.prepareAll()
        checks.require(!stuck && bench.asked == [bench.question("A.srt"), stillSaving("A.srt")]
                       && bench.buttons.last == [L10n("Keep Waiting"), L10n("Cancel")],
                       "a Save whose drive does not answer within Quit's grace is asked about again with Keep Waiting / Cancel only; Cancel stays: \(bench.asked)")
        bench.gate.open()
        let landed = await bench.until { queue.items.first(where: { $0.id == id })?.burnIn?.hasUnsavedEdits == false }
        checks.require(landed && bench.text(a).contains("Row edit"),
                       "the write that lands after Quit stopped waiting still marks the subtitle saved: \(bench.text(a))")

        bench.forget()
        bench.replies = ["Save"]
        let saved = await ProjectQuit.prepareAll()
        checks.require(saved && bench.asked == [bench.question("B.srt")] && bench.text(b).contains("Standalone edit")
                       && !standalone.hasUnsavedEdits,
                       "Save writes the subtitle still unsaved to its file first, then Quit goes on: asked \(bench.asked), \(bench.text(b))")
        await pageSaveAtQuit(checks, bench, id: id, a: a)
        await timeStillBeingTypedAtQuit(checks, bench, id: id)
        checks.require(!bench.askedInTask && bench.missingButtons.isEmpty,
                       "the questions came from a run-loop turn with Save / Don't Save / Cancel: inside a task \(bench.askedInTask)")

        queue.remove(id: id)
        standalone.clear()
        ProjectCloseQuestions.untitled = untitled
        ProjectQuit.askAboutDrive = drive
        ProjectQuit.quitCancelled = cancelled
        bench.restore()
    }

    /// The row's ✕ answered Save, its write held; Quit comes while it is written, and is cancelled.
    private static func pageSaveAtQuit(_ checks: Checks, _ bench: SubtitleEditsBench, id: EncodeItem.ID, a: URL) async {
        let queue = EncodeQueue.burnIn
        queue.editBurnInDocument(for: id) { $0.cues[0].text = "Saved by the page" }
        bench.forget()
        bench.gate.arm()
        bench.replies = ["Save"]
        BurnInSubtitleEdits.shared.remove(id)
        _ = await bench.until { bench.gate.isHolding }
        bench.replies = ["Cancel"]
        let quit = await ProjectQuit.prepareAll()
        let atQuit = Array(bench.asked.dropFirst())
        bench.gate.open()
        let saved = await bench.until { queue.items.first(where: { $0.id == id })?.burnIn?.hasUnsavedEdits == false }
        await bench.idle(BurnInSubtitleEdits.shared)
        checks.require(!quit && atQuit == [stillSaving("A.srt")] && bench.asked.count == 2,
                       "Quit during a page's Save asks once, Keep Waiting / Cancel, and Cancel stays: asked at Quit \(atQuit), in all \(bench.asked.count)")
        checks.require(saved && queue.items.contains { $0.id == id } && bench.text(a).contains("Saved by the page"),
                       "after that Cancel the page's ✕ stands down (the video stays) and its late write still saves it")
    }

    /// The row saved; a time typed in its cell and not entered yet (the draft registered as TimecodeField does).
    private static func timeStillBeingTypedAtQuit(_ checks: Checks, _ bench: SubtitleEditsBench, id: EncodeItem.ID) async {
        let queue = EncodeQueue.burnIn
        func start() -> Double? { queue.items.first { $0.id == id }?.burnIn?.document?.cues.first?.start }
        queue.markBurnInSaved(for: id)
        bench.forget()
        PendingTimecode.began(UUID()) { queue.editBurnInDocument(for: id) { $0.cues[0].start = 0.25 } }
        checks.require(!ProjectQuit.quitsAtOnce() && start() == 0.25,
                       "a time still being typed is written before Quit decides it can quit at once: \(start() ?? -1)")
        queue.markBurnInSaved(for: id)
        PendingTimecode.began(UUID()) { queue.editBurnInDocument(for: id) { $0.cues[0].start = 0.5 } }
        bench.replies = ["Cancel"]
        let quit = await ProjectQuit.prepareAll()
        checks.require(!quit && start() == 0.5 && bench.asked == [bench.question("A.srt")],
                       "Quit through prepareAll alone writes it first too, and asks: asked \(bench.asked)")
    }

    private static func stillSaving(_ file: String) -> String { String(format: L10n("“%@” is still being saved"), file) }

    private static func rowText(_ queue: EncodeQueue, _ id: EncodeItem.ID) -> String? {
        queue.items.first { $0.id == id }?.burnIn?.document?.cues.first?.text
    }
}
