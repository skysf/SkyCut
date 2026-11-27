import SwiftUI

// MARK: - Settings › General › Software Update
//
// What it does: SkyCut's version, a status line (checked today / yesterday / on a date and up to date, checking,
// downloading, ready, a new version), Check for Updates (the answer shows in the status line: no window), and the switch
// "Download and install updates automatically" (default on, AppUpdater.automatic) with a caption that follows it. A copy
// that can't update itself shows the switch disabled and says so. While the test hook is set (`SrtFlow.update.feedURL`,
// to an address SkyCut uses), one line shows its address: a hook left behind after a test never turns updates off
// silently. Not shown for a copy that never updates.
// What it doesn't: the rules or the checking (AppUpdater, AppUpdateStatusLine).
// Rules: docs/architecture/app-updates.md "What the person sees", docs/architecture/workbench-and-settings.md.

struct AppUpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if let mode = updater.mode {
            Section("Software Update") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "SkyCut \(updater.running?.description ?? "")")
                        Text(verbatim: status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let feed = updater.testFeedURL {
                            Text(verbatim: String(format: L10n("Test update feed: %@"), feed.absoluteString))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings-test-update-feed")
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Check for Updates") { updater.check(from: .settings) }
                        .disabled(updater.state.checking || updater.state.phase == .downloading)
                        .accessibilityIdentifier("settings-check-for-updates")
                }
                Toggle("Download and install updates automatically", isOn: $updater.automatic)
                    .disabled(!installs(mode))
                Text(verbatim: caption(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { updater.refreshTestFeed() }
        }
    }

    private func installs(_ mode: AppUpdateMode) -> Bool {
        if case .install = mode { return true }
        return false
    }

    private func caption(_ mode: AppUpdateMode) -> String {
        guard installs(mode) else { return L10n("This copy of SkyCut can’t update itself") }
        return updater.automatic
            ? L10n("New versions download in the background and install when you quit.")
            : L10n("You’re only told about new versions; nothing downloads until you click.")
    }

    private var status: String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        switch AppUpdateStatusLine.make(updater.state, lastUpToDate: updater.lastUpToDate, now: Date(), calendar: .current) {
        case .checking: return L10n("Checking…")
        case .downloading(let percent): return String(format: L10n("Downloading %d%%"), percent ?? 0)
        case .ready(let version): return String(format: L10n("SkyCut %@ is ready"), version.description)
        case .available(let version): return String(format: L10n("New version: SkyCut %@"), version.description)
        case .checkedToday(let date): return String(format: L10n("Checked today at %@ · Up to date"), date.formatted(time))
        case .checkedYesterday(let date): return String(format: L10n("Checked yesterday at %@ · Up to date"), date.formatted(time))
        case .checkedOn(let date): return String(format: L10n("Checked on %@ · Up to date"), date.formatted(day))
        case .checkFailed: return L10n("Couldn’t check for updates")
        case .notChecked: return L10n("Not checked yet")
        }
    }
}
