import Foundation
import SrtFlowCore

// MARK: - The Burn In page's subtitles: each video's row, and the file opened on its own
//
// What it does: names the places a subtitle lives on the Burn In page — a video's row in the queue (`BurnInRequest`), or the
// standalone file (`StandaloneSubtitleStore`) — and reads what one holds at a moment (its file, its text, whether that text
// has unsaved edits), so a decision taken earlier can check later that the place still holds exactly that. Marks a place
// saved once a write of it has landed.
// What it doesn't: asking before unsaved edits go away (BurnInSubtitleEdits); the editor's Save and Export As
// (SubtitleEditorExport); editing the text (SubtitleEditPanel, EncodeQueue.editBurnInDocument).
//
// Why (2026-11-28, docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md and
// docs/bugfixes/2026-11-28-subtitle-replace-writes-another-subtitle.md): both fixes act later on a subtitle chosen earlier
// (after a question, after a save window, after a write) and must not act on another one.

@MainActor
struct BurnInSubtitles {
    /// The Burn In page's: its queue and the standalone file.
    static var page: BurnInSubtitles { BurnInSubtitles(queue: .burnIn, standalone: .shared) }

    /// Where a subtitle lives.
    enum Place: Hashable {
        case row(EncodeItem.ID)
        case standalone
    }

    /// What a place holds at one moment.
    struct Held: Equatable {
        let url: URL?
        let document: SubtitleDocumentModel
        let hasUnsavedEdits: Bool

        /// The same file and the same text (whether it is saved may differ).
        func sameText(as other: Held?) -> Bool { other.map { $0.url == url && $0.document == document } ?? false }
    }

    let queue: EncodeQueue
    let standalone: StandaloneSubtitleStore

    /// Every place, in the page's order: the rows, then the standalone file.
    var places: [Place] { queue.items.map { .row($0.id) } + [.standalone] }

    /// What `place` holds now; nil when there is no subtitle there (the row is gone, has no subtitle, nothing is open).
    func held(_ place: Place) -> Held? {
        switch place {
        case .row(let id):
            guard let burnIn = queue.items.first(where: { $0.id == id })?.burnIn, let document = burnIn.document else { return nil }
            return Held(url: burnIn.subtitleURL, document: document, hasUnsavedEdits: burnIn.hasUnsavedEdits)
        case .standalone:
            guard let document = standalone.document else { return nil }
            return Held(url: standalone.url, document: document, hasUnsavedEdits: standalone.hasUnsavedEdits)
        }
    }

    /// The place the subtitle panel edits for its preview row `item`: that row while it has a subtitle, else the standalone
    /// file (the panel's own rule, SubtitleEditPanel.document).
    func panelPlace(boundTo item: EncodeItem.ID?) -> Place {
        if let item, held(.row(item)) != nil { return .row(item) }
        return .standalone
    }

    /// A write of what `place` holds landed on its own file: no unsaved edits.
    func markSaved(_ place: Place) {
        switch place {
        case .row(let id): queue.markBurnInSaved(for: id)
        case .standalone: standalone.hasUnsavedEdits = false
        }
    }
}
