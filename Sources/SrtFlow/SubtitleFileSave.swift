import Foundation
import SrtFlowCore

// MARK: - Writing a subtitle document to a file (the subtitle editor's Save and Export As)
//
// What it does: a subtitle file's bytes (reindexed, then SubtitleSerializer: the serialization the editor always used) and
// the write: atomic, and replacing a file already at the URL only when the person confirmed it for exactly that URL
// (NewFileClaim). Saving back to the document's own file replaces it.
// What it doesn't: asking the person (FileReplaceQuestion, asked by SubtitleEditPanel); which document is saved and its
// unsaved mark (SubtitleEditPanel).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md): Export As wrote with a plain
// `Data.write`, so a typed or dropped answer in the file-window helper replaced a subtitle file of the same name unasked.

enum SubtitleFileSave {
    /// The file's bytes.
    static func data(_ document: SubtitleDocumentModel, format: SubtitleFormat) -> Data {
        var copy = document
        copy.reindex()
        return Data(SubtitleSerializer.serialize(copy, format: format).utf8)
    }

    /// Writes `document` at `url`. `replacing`: a file already there may be replaced (its own file, or confirmed for exactly
    /// this URL). `.occupied`: a file is there and nobody confirmed replacing it; nothing written, that file untouched.
    static func write(
        _ document: SubtitleDocumentModel, format: SubtitleFormat, to url: URL, replacing: Bool
    ) throws -> NewFileClaim.Outcome {
        try NewFileClaim.write(data(document, format: format), to: url, replacing: replacing)
    }
}
