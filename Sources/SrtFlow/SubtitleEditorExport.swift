import Foundation
import SrtFlowCore
import UniformTypeIdentifiers

// MARK: - The Burn In subtitle editor's Save and Export As
//
// What it does: the panel's Save and Export As buttons (SubtitleEditPanel calls only `save` and `exportAs`). The subtitle a
// button is pressed for — the panel's place (its preview row, or the standalone file) and what it holds then — is taken
// when it is pressed. Before every write, when the save window answers and when Replace is answered, that place must still
// hold exactly that subtitle, unedited: otherwise nothing is written and the person is told "Nothing was written: the
// subtitle changed. Export again." The bytes are written off the main thread (SubtitleFileSave), replacing a file already
// there only when allowed: its own file, a file confirmed in macOS's own window, or Replace answered to
// FileReplaceQuestion. The subtitle is marked saved when a write of it in its own format lands on its own file and it still
// holds exactly that.
// What it doesn't: the Replace alert (FileReplaceQuestion); the write itself (SubtitleFileSave); what drops a subtitle with
// unsaved edits (BurnInSubtitleEdits).
//
// Why (2026-11-28, docs/bugfixes/2026-11-28-subtitle-replace-writes-another-subtitle.md): the Replace retry wrote whatever
// subtitle the panel held when Replace was answered, so another subtitle could land in the file chosen for the first one.
// Rule: docs/architecture/system-file-windows.md rule 9.

@MainActor
struct SubtitleEditorExport {
    /// The save window (a seam: the checks answer it themselves).
    static var chooseSaveLocation: @MainActor (_ types: [UTType], _ name: String, _ then: @escaping (SaveLocation) -> Void) -> Void = {
        FilePicker.chooseSaveLocation(types: $0, name: $1, then: $2)
    }

    /// What a button was pressed for: where, and what it held then.
    struct Pressed {
        let place: BurnInSubtitles.Place
        let held: BurnInSubtitles.Held
    }

    let subtitles: BurnInSubtitles
    /// Tells the person why nothing was written (the panel's "Could Not Save" alert).
    let report: @MainActor (String) -> Void

    /// Save: the subtitle to its own file (Export As when it has none).
    func save(boundTo item: EncodeItem.ID?) {
        guard let pressed = pressed(boundTo: item) else { return }
        guard let url = pressed.held.url else { return exportAs(pressed.held.document.format, boundTo: item) }
        write(pressed, pressed.held.document.format, to: SaveLocation(url: url, mayReplace: true))
    }

    /// Export As: the save window, then the subtitle as it was when this was pressed.
    func exportAs(_ format: SubtitleFormat, boundTo item: EncodeItem.ID?) {
        guard let pressed = pressed(boundTo: item) else { return }
        let base = pressed.held.url?.deletingPathExtension().lastPathComponent ?? pressed.held.document.title
        Self.chooseSaveLocation([format.utType], "\(base).\(format.fileExtension)") { location in
            write(pressed, format, to: location)
        }
    }

    /// What the panel edits for its preview row `item`, now.
    private func pressed(boundTo item: EncodeItem.ID?) -> Pressed? {
        let place = subtitles.panelPlace(boundTo: item)
        return subtitles.held(place).map { Pressed(place: place, held: $0) }
    }

    /// Writes `pressed`'s subtitle at `location` (off the main thread), only while its place still holds it unedited. A
    /// file already there is replaced only when `location` allows it, or when the person answers Replace, after which the
    /// same check runs again before the second write.
    private func write(_ pressed: Pressed, _ format: SubtitleFormat, to location: SaveLocation) {
        guard pressed.held.sameText(as: subtitles.held(pressed.place)) else {
            return report(L10n("Nothing was written: the subtitle changed. Export again."))
        }
        let data = SubtitleFileSave.data(pressed.held.document, format: format)
        Task {
            let answer = await SubtitleFileSave.write(data, to: location.url, replacing: location.mayReplace) { landed in
                // Its own file in its own format (an export onto it is a save), still holding exactly what was written.
                guard landed == .written, location.url == pressed.held.url, format == pressed.held.document.format,
                      pressed.held.sameText(as: subtitles.held(pressed.place)) else { return }
                subtitles.markSaved(pressed.place)
            }
            switch answer {
            case .written: break
            case .occupied:
                if FileReplaceQuestion.ask(location.url) { write(pressed, format, to: SaveLocation(url: location.url, mayReplace: true)) }
            case .failed(let reason): report(reason)
            case .notResponding: report(SubtitleFileSave.notRespondingText(location.url))
            }
        }
    }
}
