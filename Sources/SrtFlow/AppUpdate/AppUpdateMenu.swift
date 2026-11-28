import SwiftUI

// MARK: - SkyCut › Check for Updates…
//
// What it does: the app menu's item after About: "Check for Updates…", which checks and opens the check window
// (AppUpdateCheckWindow: checking, then the answer); greyed "Checking for Updates…" while any check runs, so a second
// choice never starts a second check; "Downloading Update (29%)…" while a download runs, which shows the check window on
// that download without a check; or, once an update is downloaded and verified, "Restart and Update to %@…", which opens
// the toolbar pill's popover like clicking the pill (in the main window when no workbench window is active). Not shown for
// a copy that never updates (SkyCut Beta, dev builds).
// What it doesn't: check or download (AppUpdater), the window (AppUpdateCheckWindow).
// Rules: docs/architecture/app-updates.md "What the person sees".

struct AppUpdateMenuItem: View {
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if updater.mode != nil {
            switch AppUpdateMenuEntry.make(updater.state) {
            case .restart(let version):
                Button(String(format: L10n("Restart and Update to %@…"), version)) {
                    // The pill is in every workbench window: the focused project's (a project window's, else the main
                    // window's, which comes forward on whatever page it shows).
                    let focused = OpenProjects.shared.focused
                    if focused === OpenProjects.shared.primary { openWindow(id: WindowID.main) }
                    updater.requestPopover(for: focused)
                }
            case .downloading(let percent):
                Button(String(format: L10n("Downloading Update (%d%%)…"), percent)) { AppUpdateCheckWindow.shared.showDownload() }
            case .checking:
                Button("Checking for Updates…") {}
                    .disabled(true)
            case .check:
                Button("Check for Updates…") { updater.check(from: .menu) }
            }
        }
    }
}
