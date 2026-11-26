import AppKit
import SwiftUI

// MARK: - SkyCut › Check for Updates…, and the answer to a check the person started
//
// What it does: the app menu's item after About: "Check for Updates…", or, once an update is downloaded and verified,
// "Restart and Update to %@…", which opens the toolbar pill's popover like clicking the pill (in the main window when no
// workbench window is active). The answer to a check started here is the one window the updater ever opens: up to date;
// found and downloading (Update appears when done); found with auto install off (Download and Install / Later); found by
// a copy that can't update itself (Open Download Page / Later); or the check failed. Not shown for a copy that never
// updates (SkyCut Beta, dev builds).
// What it doesn't: check or download (AppUpdater).
// Rules: docs/architecture/app-updates.md "What the person sees".

struct AppUpdateMenuItem: View {
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if updater.mode != nil {
            if updater.state.phase == .ready, let version = updater.offerVersion {
                Button(String(format: L10n("Restart and Update to %@…"), version)) {
                    // The pill is in every workbench window: the focused project's (a project window's, else the main
                    // window's, which comes forward on whatever page it shows).
                    let focused = OpenProjects.shared.focused
                    if focused === OpenProjects.shared.primary { openWindow(id: WindowID.main) }
                    updater.requestPopover(for: focused)
                }
            } else {
                Button("Check for Updates…") { updater.check(from: .menu) }
            }
        }
    }
}

@MainActor
enum AppUpdateAlerts {
    static func show(_ answer: AppUpdateCheckAnswer) {
        let alert = make(answer, running: AppUpdater.shared.running?.description ?? "")
        NSApp.activate()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        switch answer {
        case .askToDownload: AppUpdater.shared.downloadAndInstall()
        case .cannotUpdate: NSWorkspace.shared.open(AppUpdateFeed.downloadPageURL)
        case .upToDate, .downloading, .failed: break
        }
    }

    /// The window for an answer (the renders draw these same alerts).
    static func make(_ answer: AppUpdateCheckAnswer, running: String) -> NSAlert {
        let alert = NSAlert()
        switch answer {
        case .upToDate:
            alert.messageText = L10n("SkyCut is up to date")
            alert.informativeText = String(format: L10n("%@ is the latest version."), running)
            alert.addButton(withTitle: L10n("OK"))
        case .downloading(let feed):
            alert.messageText = String(format: L10n("SkyCut %@ is available"), feed.version.description)
            alert.informativeText = L10n("Downloading in the background. When it’s done, Update appears in the toolbar.")
            alert.addButton(withTitle: L10n("OK"))
        case .askToDownload(let feed):
            alert.messageText = String(format: L10n("SkyCut %@ is available"), feed.version.description)
            alert.informativeText = L10n("Download it now, or later from New Version in the toolbar.")
            alert.addButton(withTitle: L10n("Download and Install"))
            dismissesWithEscape(alert.addButton(withTitle: L10n("Later")))
        case .cannotUpdate(let feed):
            alert.messageText = String(format: L10n("New version: SkyCut %@"), feed.version.description)
            alert.informativeText = L10n("It isn’t in the Applications folder, or that folder can’t be written to. Download the new version from the website and drag it into Applications to replace this one.")
            alert.addButton(withTitle: L10n("Open Download Page"))
            dismissesWithEscape(alert.addButton(withTitle: L10n("Later")))
        case .failed:
            alert.messageText = L10n("Couldn’t check for updates")
            alert.informativeText = L10n("SkyCut couldn’t reach the update server. Check your internet connection, then try again.")
            alert.addButton(withTitle: L10n("OK"))
        }
        return alert
    }

    /// AppKit gives Escape only to a button titled Cancel (as MoveToApplicationsAlerts does).
    private static func dismissesWithEscape(_ button: NSButton) {
        button.keyEquivalent = "\u{1b}"
    }
}
