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

    init(_ subtitles: BurnInSubtitles) {
        self.subtitles = subtitles
    }

    /// A page action is waiting for its questions or saves.
    var isBusy: Bool { pending > 0 }

    // MARK: - Page actions

    /// A row's ✕.
    func remove(_ id: EncodeItem.ID) {
        let place = BurnInSubtitles.Place.row(id)
        whenSettled({ [place] }) { [self] discarded in
            guard discarded.allows(place, unsaved(place)) else { return }
            subtitles.queue.remove(id: id)
        }
    }

    /// Clear Finished: the finished rows go, each asked about first.
    func clearFinished() {
        let queue = subtitles.queue
        whenSettled({ queue.items.filter(\.isDone).map { .row($0.id) } }) { [self] discarded in
            for item in queue.items where item.isDone && discarded.allows(.row(item.id), unsaved(.row(item.id))) {
                queue.remove(id: item.id)
            }
        }
    }

    /// `subtitle` for the video `id`, read into its row; a row with unsaved edits is asked about first, also when
    /// `subtitle` is its own file again (Don't Save then reads it from the drive).
    func attach(_ subtitle: URL, to id: EncodeItem.ID) {
        let place = BurnInSubtitles.Place.row(id)
        whenSettled({ [place] }) { [self] discarded in
            guard subtitles.queue.items.contains(where: { $0.id == id }), discarded.allows(place, unsaved(place)) else { return }
            load(subtitle, into: id)
        }
    }

    // MARK: - Quit

    /// Something to ask at Quit: a subtitle with unsaved edits not given up yet, or a page action still under way.
    func needsAsking(after discarded: Discarded) -> Bool {
        pending > 0 || subtitles.places.contains { !discarded.allows($0, unsaved($0)) }
    }

    /// Quit (ProjectQuit): once the page's actions under way are done, every subtitle with unsaved edits is asked about. A
    /// Save waits for its drive at most `deadline` (Quit's grace: nothing else on screen moves while Quit waits), then is
    /// asked about again, saying the drive is not responding. false: Cancel.
    func settleForQuit(into discarded: inout Discarded, deadline: TimeInterval) async -> Bool {
        while pending > 0, let running = last { await running.value }
        return await settle(subtitles.places, into: &discarded, deadline: deadline)
    }

    // MARK: - Asking

    /// What `place` holds when it has unsaved edits and a file to save them to; nil otherwise.
    func unsaved(_ place: BurnInSubtitles.Place) -> BurnInSubtitles.Held? {
        guard let held = subtitles.held(place), held.hasUnsavedEdits, held.url != nil else { return nil }
        return held
    }

    /// Runs `action` once the unsaved edits at `places` are settled: at once when nothing there needs asking and no action
    /// is under way, otherwise after the actions before it. Cancel: it never runs.
    private func whenSettled(
        _ places: @escaping @MainActor () -> [BurnInSubtitles.Place], _ action: @escaping @MainActor (Discarded) -> Void
    ) {
        if pending == 0, places().allSatisfy({ unsaved($0) == nil }) { return action(Discarded()) }
        pending += 1
        let previous = last
        last = Task { @MainActor [self] in
            await previous?.value
            var discarded = Discarded()
            if await settle(places(), into: &discarded) { action(discarded) }
            pending -= 1
        }
    }

    /// Asks about each place's unsaved edits in turn; again after a Save that failed or did not answer within `deadline` (nil:
    /// the editor's own, SubtitleFileSave.deadline), or when new edits came in while it was written. false: Cancel (nothing
    /// more is asked).
    private func settle(
        _ places: [BurnInSubtitles.Place], into discarded: inout Discarded, deadline: TimeInterval? = nil
    ) async -> Bool {
        for place in places {
            var failure: String?
            while let now = unsaved(place), !discarded.allows(place, now) {
                switch await SubtitleEditsQuestion.ask(now.url?.lastPathComponent ?? "", failure: failure) {
                case .cancel: return false
                case .dontSave: discarded.answered[place] = now
                case .save: failure = await save(now, at: place, deadline: deadline)
                }
            }
        }
        return true
    }

    /// `held` written to its own file in its own format, off the main thread (the editor's Save); its place is marked saved
    /// when the write lands and it still holds exactly that, also after "not responding". nil: written; otherwise why not.
    private func save(_ held: BurnInSubtitles.Held, at place: BurnInSubtitles.Place, deadline: TimeInterval?) async -> String? {
        guard let url = held.url else { return nil }
        let data = SubtitleFileSave.data(held.document, format: held.document.format)
        let answer = await SubtitleFileSave.write(data, to: url, replacing: true, deadline: deadline) { [self] landed in
            guard landed == .written, held.sameText(as: subtitles.held(place)) else { return }
            subtitles.markSaved(place)
        }
        switch answer {
        case .written: return nil
        case .occupied: return NewFileClaim.occupiedReason(url)
        case .failed(let reason): return reason
        case .notResponding: return SubtitleFileSave.notRespondingText(url)
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
