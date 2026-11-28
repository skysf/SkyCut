import AppKit
import Foundation

// MARK: - "Save the changes to “X”?" before a Burn In subtitle's unsaved edits would go away
//
// What it does: the one question asked before anything drops a Burn In subtitle's unsaved edits (BurnInSubtitleEdits:
// another file for a video, a video removed, Clear Finished, Quit / Restart and Update): Save / Don't Save / Cancel, as for
// a project, naming the file, and after a Save that failed, why. The alert is shown from a run-loop turn, never inside a
// Swift task (docs/architecture/system-file-windows.md rule 10), and only while no other alert's modal loop runs, so one
// alert never opens inside another. Its timer runs in the default and the modal-panel run-loop modes: while Quit waits for
// its answer (terminateLater), AppKit runs the run loop in the modal-panel mode.
// What it doesn't: what is done with the answer (BurnInSubtitleEdits).
//
// Why (2026-11-28, docs/bugfixes/2026-11-28-burn-in-subtitle-edits-dropped-unasked.md): these edits were dropped without a
// word. Rules: docs/architecture/export-settings.md §9.

@MainActor
enum SubtitleEditsQuestion {
    enum Choice: Equatable {
        case save, dontSave, cancel
    }

    /// Runs the alert's modal loop and gives the button pressed (a seam: the checks press the alert's own buttons, by title).
    static var run: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// Asks about `file`'s unsaved edits; `failure`: why the last Save of them failed.
    static func ask(_ file: String, failure: String? = nil) async -> Choice {
        await withCheckedContinuation { continuation in
            whenNoAlertIsUp {
                continuation.resume(returning: choice(run(alert(file, failure: failure))))
            }
        }
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

    /// `body` on a run-loop turn (a timer: never inside a Swift task, never inside a dispatch block) once no alert's modal
    /// loop is running; looked at again every 0.1 s while one is.
    private static func whenNoAlertIsUp(after delay: TimeInterval = 0, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                if NSApp.modalWindow != nil { return whenNoAlertIsUp(after: 0.1, body) }
                body()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
}
