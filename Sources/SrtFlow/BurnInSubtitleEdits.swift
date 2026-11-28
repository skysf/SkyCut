import Foundation
import SrtFlowCore

// MARK: - Unsaved Burn In subtitle edits are never dropped without asking
//
// What it does: every way a Burn In subtitle with unsaved edits could go away asks first (SubtitleEditsQuestion): another
// subtitle file — or the same one again — for a video (`attach`: a row's Choose…, the page's drop and its pairing by
// name), a video removed (`remove`, the row's ✕), Clear Finished (`clearFinished`), Quit and Restart and Update
// (`settleForQuit`, from ProjectQuit). Save writes the subtitle to its own file first (the editor's Save), Don't Save lets
// it go, Cancel changes nothing. The action then touches only what was asked about: a subtitle edited or replaced while its
// save was being written is asked about again, never dropped. Page actions run one after another, each after the questions
// and saves of the ones before it, so an older action never lands after a newer one. With nothing to ask and nothing under
// way, an action runs at once, as before.
// While a Save of a subtitle's file is still on its way (SubtitleFileSave.isWriting), Don't Save is never offered — the
// write would land after it — only Keep Waiting / Cancel; a file is never read into a row while a write to it is on its way;
// when a write lands, the place's mark follows the drive. Quit takes over: the page's actions under way stand down, and
// Quit's question is the only one (review CXM1). Every action, and Quit, first writes a time still being typed in a cell
// (PendingTimecode), so it counts as an edit.
// What it doesn't: the question's alert (SubtitleEditsQuestion); the editor's own Save and Export As (SubtitleEditorExport);
// the queue (EncodeQueue); the standalone file's ✕, which refuses while it has unsaved edits (SubtitleEditPanel); reopening
// the open standalone file, which keeps its edits (StandaloneSubtitleStore.open).
//
// Why (2026-11-28, docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md): choosing another subtitle file for a
// video, removing it, Clear Finished and Quit dropped its unsaved edits without a word. Rules:
// docs/architecture/export-settings.md §9.

@MainActor
final class BurnInSubtitleEdits {
    /// The Burn In page's.
    static let shared = BurnInSubtitleEdits(.page)

    /// The edits the person answered Don't Save for, each only while its place still holds exactly that.
    struct Discarded {
        fileprivate var answered: [BurnInSubtitles.Place: BurnInSubtitles.Held] = [:]

        /// `place` may let its subtitle go: nothing unsaved there now, or exactly what Don't Save was answered for.
        func allows(_ place: BurnInSubtitles.Place, _ unsaved: BurnInSubtitles.Held?) -> Bool {
            unsaved.map { answered[place] == $0 } ?? true
        }
    }

    let subtitles: BurnInSubtitles
    /// Page actions still waiting for their questions or saves, and the newest of them (the next one waits for it).
    private var pending = 0
    private var last: Task<Void, Never>?
    /// Bumped when Quit takes over: page actions started before it ask nothing more and do nothing, so Quit's own
    /// question is the only one (review CXM1).
    private var epoch = 0

    init(_ subtitles: BurnInSubtitles) {
        self.subtitles = subtitles
    }

    /// A page action is waiting for its questions or saves.
    var isBusy: Bool { pending > 0 }

    // MARK: - Page actions

    /// A row's ✕.
    func remove(_ id: EncodeItem.ID) {
        PendingTimecode.commit()
        let place = BurnInSubtitles.Place.row(id)
        whenSettled({ [place] }) { [self] discarded in
            guard discarded.allows(place, unsaved(place)) else { return }
            subtitles.queue.remove(id: id)
        }
    }

    /// Clear Finished: the finished rows go, each asked about first.
    func clearFinished() {
        PendingTimecode.commit()
        let queue = subtitles.queue
        whenSettled({ queue.items.filter(\.isDone).map { .row($0.id) } }) { [self] discarded in
            for item in queue.items where item.isDone && discarded.allows(.row(item.id), unsaved(.row(item.id))) {
                queue.remove(id: item.id)
            }
        }
    }

    /// `subtitle` for the video `id`, read into its row; a row with unsaved edits is asked about first, also when
    /// `subtitle` is its own file again (Don't Save then reads it from the drive). Never read while a write to that file is
    /// still on its way: it waits for it (the editor's deadline), and says the drive is not responding past that.
    func attach(_ subtitle: URL, to id: EncodeItem.ID) {
        PendingTimecode.commit()
        let place = BurnInSubtitles.Place.row(id)
        whenSettled({ [place] }, reading: subtitle, stillWriting: { [self] in
            subtitles.queue.setError(SubtitleFileSave.notRespondingText(subtitle), for: id)
        }) { [self] discarded in
            guard subtitles.queue.items.contains(where: { $0.id == id }), discarded.allows(place, unsaved(place)) else { return }
            load(subtitle, into: id)
        }
    }

    // MARK: - Quit

    /// Something to ask at Quit: a subtitle with unsaved edits not given up yet.
    func needsAsking(after discarded: Discarded) -> Bool {
        subtitles.places.contains { !discarded.allows($0, unsaved($0)) }
    }

    /// Quit (ProjectQuit): every subtitle with unsaved edits is asked about. Quit takes over from the page's actions under
    /// way: they stand down, and a Save of theirs still being written is asked about here once, Keep Waiting or Cancel. A Save
    /// waits for its drive at most `deadline` (Quit's grace: nothing else on screen moves while Quit waits). false: Cancel.
    func settleForQuit(into discarded: inout Discarded, deadline: TimeInterval) async -> Bool {
        epoch += 1
        return await settle(subtitles.places, into: &discarded, deadline: deadline) { true }
    }

    // MARK: - Asking

    /// What `place` holds when it has unsaved edits, or a Save of its file is still being written (it is not saved before the
    /// newest one lands, review CXM2), and a file to save it to; nil otherwise.
    func unsaved(_ place: BurnInSubtitles.Place) -> BurnInSubtitles.Held? {
        guard let held = subtitles.held(place), let url = held.url,
              held.hasUnsavedEdits || SubtitleFileSave.isWriting(url) else { return nil }
        return held
    }

    /// Runs `action` once the unsaved edits at `places` are settled: at once when nothing there needs asking, nothing is
    /// being written to `reading` and no action is under way; otherwise after the actions before it (and after the write to
    /// `reading` landed; `stillWriting` when it has not by the editor's deadline). Cancel, or Quit taking over: it never runs.
    private func whenSettled(
        _ places: @escaping @MainActor () -> [BurnInSubtitles.Place], reading file: URL? = nil,
        stillWriting: @escaping @MainActor () -> Void = {}, _ action: @escaping @MainActor (Discarded) -> Void
    ) {
        let writing = file.map(SubtitleFileSave.isWriting) ?? false
        if pending == 0, !writing, places().allSatisfy({ unsaved($0) == nil }) { return action(Discarded()) }
        pending += 1
        let previous = last, started = epoch
        last = Task { @MainActor [self] in
            defer { pending -= 1 }
            await previous?.value
            let current = { [self] in epoch == started }
            var discarded = Discarded()
            // Asked again until nothing changed since the answers: a time typed while a Save was written (written now), or
            // any other edit, is asked about instead of dropped (review CXM2).
            repeat {
                guard await settle(places(), into: &discarded, while: current), current() else { return }
                PendingTimecode.commit()
            } while places().contains { !discarded.allows($0, unsaved($0)) }
            if let file, !(await SubtitleFileSave.waitUntilWritten(file, deadline: SubtitleFileSave.deadline)) {
                if current() { stillWriting() }
                return
            }
            if current() { action(discarded) }
        }
    }

    /// Asks about each place's unsaved edits in turn; again after a Save that failed, or when new edits came in while it was
    /// written. While a Save of a place's file is still on its way (it did not answer within `deadline`, nil: the editor's
    /// own, or another one started it), Don't Save is not offered: Keep Waiting (up to `deadline` again) or Cancel. Asks
    /// nothing more once `current` says no. false: Cancel.
    private func settle(
        _ places: [BurnInSubtitles.Place], into discarded: inout Discarded, deadline: TimeInterval? = nil,
        while current: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for place in places {
            while let now = unsaved(place), !discarded.allows(place, now) {
                guard current(), let url = now.url else { return false }
                if SubtitleFileSave.isWriting(url) {
                    switch await SubtitleEditsQuestion.askWhileWriting(url.lastPathComponent, stillWanted: current) {
                    case .keepWaiting: _ = await SubtitleFileSave.waitUntilWritten(url, deadline: deadline ?? SubtitleFileSave.deadline)
                    case .cancel: return false
                    }
                    continue
                }
                // The last failed write of its file, until a later one lands (also after a Cancel: reviews CXM2, CXM3).
                switch await SubtitleEditsQuestion.ask(url.lastPathComponent, failure: SubtitleFileSave.lastFailure(url), stillWanted: current) {
                case .cancel: return false
                case .dontSave: discarded.answered[place] = now
                case .save: await save(now, at: place, deadline: deadline)
                }
            }
        }
        return true
    }

    /// `held` written to its own file in its own format, off the main thread (the editor's Save), waited for at most
    /// `deadline`. Whenever it lands, on time or after "not responding", the place's mark follows the drive
    /// (`BurnInSubtitles.follow`); a failure is kept by SubtitleFileSave for the next question. The loop then looks again:
    /// still writing (Keep Waiting / Cancel), failed (asked with the reason), or saved.
    private func save(_ held: BurnInSubtitles.Held, at place: BurnInSubtitles.Place, deadline: TimeInterval?) async {
        guard let url = held.url else { return }
        let data = SubtitleFileSave.data(held.document, format: held.document.format)
        _ = await SubtitleFileSave.write(data, to: url, replacing: true, deadline: deadline) { [self] landed in
            if landed == .written { subtitles.follow(place, written: held) }
        }
    }

    /// `subtitle` read into the row (what the page always did): the standalone file's unsaved edits come along when it is
    /// that file.
    private func load(_ subtitle: URL, into id: EncodeItem.ID) {
        let queue = subtitles.queue, standalone = subtitles.standalone
        do {
            let document: SubtitleDocumentModel
            if standalone.url == subtitle, let edited = standalone.document, standalone.hasUnsavedEdits {
                // 这个文件正在字幕列里改着呢，配给视频时要带着没保存的改动走，不能从磁盘重读一份把编辑丢了。
                document = edited
                queue.updateBurnIn(BurnInRequest(subtitleURL: subtitle, document: document, hasUnsavedEdits: true), for: id)
                standalone.clear()
            } else {
                document = try SubtitleLoader.load(subtitle)
                queue.updateBurnIn(BurnInRequest(subtitleURL: subtitle, document: document), for: id)
                if standalone.url == subtitle { standalone.clear() }
            }
            if document.cues.isEmpty {
                queue.setError(String(format: L10n("No subtitle lines found in %@."), subtitle.lastPathComponent), for: id)
            }
        } catch {
            queue.setError(error.localizedDescription, for: id)
        }
    }
}
