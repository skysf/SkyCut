import AppKit
import Foundation

// MARK: - "Save the changes to “X”?" before a Burn In subtitle's unsaved edits would go away
//
// What it does: the one question asked before anything drops a Burn In subtitle's unsaved edits (BurnInSubtitleEdits:
// another file for a video, a video removed, Clear Finished, Quit / Restart and Update): Save / Don't Save / Cancel, as for
// a project, naming the file, and after a Save that failed, why. Shown through RunLoopAlert: from a run-loop turn, never
// inside a Swift task (docs/architecture/system-file-windows.md rule 10), never inside another alert, also while Quit waits.
// What it doesn't: what is done with the answer (BurnInSubtitleEdits); the run-loop turn itself (RunLoopAlert).
//
// Why (2026-11-28, docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md): these edits were dropped without a
// word. Rules: docs/architecture/export-settings.md §9.

@MainActor
enum SubtitleEditsQuestion {
    enum Choice: Equatable {
        case save, dontSave, cancel
    }

    /// Asks about `file`'s unsaved edits; `failure`: why the last Save of them failed. Cancel when `stillWanted` says no by
    /// the time the alert would come up.
    static func ask(
        _ file: String, failure: String? = nil, stillWanted: @escaping @MainActor () -> Bool = { true }
    ) async -> Choice {
        await RunLoopAlert.ask({ alert(file, failure: failure) }, stillWanted: stillWanted).map(choice) ?? .cancel
    }

    /// The alert: Save (the default button), Don't Save, Cancel (Escape).
    static func alert(_ file: String, failure: String?) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(format: L10n("Save the changes to “%@”?"), file)
        alert.informativeText = [failure, L10n("Your changes will be lost if you don't save them.")]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: L10n("Save"))
        alert.addButton(withTitle: L10n("Don't Save"))
        alert.addButton(withTitle: L10n("Cancel")).keyEquivalent = "\u{1b}"
        return alert
    }

    /// The button pressed, in the order `alert` adds them.
    static func choice(_ response: NSApplication.ModalResponse) -> Choice {
        switch response {
        case .alertFirstButtonReturn: .save
        case .alertSecondButtonReturn: .dontSave
        default: .cancel
        }
    }
}
