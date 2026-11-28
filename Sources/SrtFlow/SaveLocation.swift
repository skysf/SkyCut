import AppKit
import Foundation

// MARK: - Where the person chose to save, and whether a file already there may be replaced
//
// What it does: the answer of a save window (`SaveLocation`) carries whether replacing a file at that URL was confirmed —
// only macOS's own save window asks "Replace?", and only about the URL it returns; a typed or dropped answer in the
// file-window helper never asked. When nobody asked and a file is there, the caller asks here (`FileReplaceQuestion`)
// before it writes over it.
// What it doesn't: the windows (SystemFileWindows, SystemFileChooser, FileWindowHelper); the write that refuses to replace
// a file nobody agreed to replace (NewFileClaim).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md): a folder dropped on the helper, or a
// typed path ending in "/", got the suggested name and was written at once, silently replacing a project or subtitle file
// of the same name. Rules: docs/architecture/system-file-windows.md rule 9.

/// Where the person chose to save, and whether a file already at `url` may be replaced: true only when macOS's own save
/// window asked "Replace?" about exactly this URL — it asks only about a file that is there, so an answer naming a free
/// name is no decision to replace (SystemFileWindows.openSave). A typed or dropped answer in the helper never asked, so it
/// may not.
struct SaveLocation: Equatable {
    let url: URL
    /// The person confirmed replacing a file at exactly `url`.
    let mayReplace: Bool

    /// The same choice at another URL (a caller adding the extension the person removed): the confirmation covered only
    /// the URL it was asked about.
    func at(_ other: URL) -> SaveLocation {
        SaveLocation(url: other, mayReplace: mayReplace && other.standardizedFileURL == url.standardizedFileURL)
    }
}

/// "Replace “X”?" for a chosen file that is already there when nobody has asked yet (a typed or dropped answer in the
/// helper, a name the caller completed). An in-process alert, so it may be modal; Cancel is the default. A seam: the
/// checks answer it.
@MainActor
enum FileReplaceQuestion {
    static var ask: @MainActor (URL) -> Bool = { askInAlert($0) }

    /// The same question asked from a run-loop turn (RunLoopAlert), for a caller inside a Swift task: its modal loop never
    /// runs inside the task (docs/architecture/system-file-windows.md rule 10). The Burn In subtitle editor's Export As asks
    /// here (2026-11-28); the project's Save As still asks `ask` inside its task.
    static func askFromRunLoop(_ url: URL) async -> Bool {
        await RunLoopAlert.onFreeTurn { ask(url) }
    }

    private static func askInAlert(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L10n("Replace “%@”?"), url.lastPathComponent)
        alert.informativeText = String(
            format: L10n("A file with this name is already in “%@”. Replacing it overwrites that file."),
            url.deletingLastPathComponent().lastPathComponent
        )
        alert.addButton(withTitle: L10n("Cancel"))
        alert.addButton(withTitle: L10n("Replace")).hasDestructiveAction = true
        return RunLoopAlert.run(alert) == .alertSecondButtonReturn
    }
}
