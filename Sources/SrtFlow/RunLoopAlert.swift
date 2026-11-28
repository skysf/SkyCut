import AppKit
import Foundation

// MARK: - Alerts shown from a run-loop turn, never inside a Swift task
//
// What it does: runs an in-process alert's modal loop (or any work that shows one, `onFreeTurn`) from a run-loop timer —
// never inside a Swift task, never inside a dispatch block (docs/architecture/system-file-windows.md rule 10) — and only
// once no other alert's modal loop is running, so one alert never opens inside another. The timer runs in the default and
// the modal-panel run-loop modes: while Quit waits for its answer (`terminateLater`), AppKit runs the run loop only in the
// modal-panel mode (measured 2026-11-28 with a probe app: a default-mode timer never fired). Callers in a task await the
// answer; their task is suspended, not running the modal loop.
// What it doesn't: what the alerts say and what is done with the answers (SubtitleEditsQuestion, FileReplaceQuestion,
// SubtitleEditorExport).
//
// Why (2026-11-28, review CXM1 of docs/bugfixes/2026-11-28-subtitle-replace-writes-another-subtitle.md): the subtitle
// editor's Replace question still ran `runModal` inside its save task, the crash mechanism of
// docs/bugfixes/2026-11-27-check-for-updates-crash-tracking-owner-selectors.md, and its "Nothing was written" message went
// to the subtitle panel, unseen once the person had left the Burn In page.

@MainActor
enum RunLoopAlert {
    /// Runs an alert's modal loop and gives the button pressed (a seam: the checks press its buttons by title).
    static var run: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// `body` on a run-loop turn with no alert's modal loop running; its value is the answer.
    static func onFreeTurn<Value>(_ body: @escaping @MainActor () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            whenNoAlertIsUp { continuation.resume(returning: body()) }
        }
    }

    /// The alert `make` builds, shown on a run-loop turn: the button pressed, or nil when `stillWanted` said no by then.
    static func ask(
        _ make: @escaping @MainActor () -> NSAlert, stillWanted: @escaping @MainActor () -> Bool = { true }
    ) async -> NSApplication.ModalResponse? {
        await onFreeTurn { stillWanted() ? run(make()) : nil }
    }

    /// The same, without waiting for the answer (a message with one button).
    static func tell(_ make: @escaping @MainActor () -> NSAlert) {
        whenNoAlertIsUp { _ = run(make()) }
    }

    /// `body` on a run-loop turn (a timer) once no alert's modal loop is running; looked at again every 0.1 s while one is.
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
