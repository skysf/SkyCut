import SwiftUI

// MARK: - What the window of SkyCut › Check for Updates… says
//
// What it does: the window's content in the update popovers' layout (the header, what's new, a note, the buttons on the
// right) and the theme's colours, for what AppUpdateCheckDisplay says now:
// - checking: a spinner on a light tile, «Checking for updates…», the running version, Cancel;
// - up to date (OK); couldn't check (Cancel / Try Again);
// - a newer version, followed live: downloading (a bar, «Downloading 29%», «12.3 MB / 42.4 MB»; «Verifying…» once every
//   byte is in; the note that it downloads in the background; OK), downloaded (the pill popover's own ready content: Later /
//   Restart and Update, then its waiting list while a restart waits), the download didn't finish (Later / Try Again), auto
//   install off (Later / Download and Install), a copy that can't update itself (Later / Open Download Page).
// The words are the old alerts' and the popovers' (the same keys), but for the failed download's note: its own key, without
// the popover's «Try again later.» next to a Try Again button. While the window is key, Return clicks the filled button and
// Escape the other one (AppUpdateCheckPanel). The renders draw these same views.
// What it doesn't: what shows when (AppUpdateCheckFlow, AppUpdateCheckDisplay), the window (AppUpdateCheckWindow), act
// (AppUpdateCheckWindow.perform; the reused ready and waiting contents call AppUpdater themselves, as in the popover).
// Rules: docs/architecture/app-updates.md "What the person sees".

/// A button of the check window.
enum AppUpdateCheckAction: Equatable, Sendable {
    case cancel, dismiss, tryAgain, downloadAndInstall, openDownloadPage
}

struct AppUpdateCheckContent: View {
    let display: AppUpdateCheckDisplay
    /// The running version.
    let running: String
    let perform: (AppUpdateCheckAction) -> Void
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            switch display {
            case .checking:
                AppUpdateHeader(icon: nil, title: L10n("Checking for updates…"), subtitle: youreOn)
                buttonRow { secondaryButton("Cancel", .cancel) }
            case .upToDate:
                AppUpdateHeader(icon: "checkmark", title: L10n("SkyCut is up to date"),
                                subtitle: String(format: L10n("%@ is the latest version."), running))
                buttonRow { defaultButton("OK", .dismiss) }
            case .couldNotCheck:
                AppUpdateHeader(icon: "wifi.exclamationmark", title: L10n("Couldn’t check for updates"), subtitle: youreOn)
                line(L10n("SkyCut couldn’t reach the update server. Check your internet connection, then try again."))
                buttonRow {
                    secondaryButton("Cancel", .dismiss)
                    defaultButton("Try Again", .tryAgain)
                }
            case .downloading(let feed, let fraction):
                available(feed)
                progress(feed, fraction)
                AppUpdateNoteBox(text: L10n("Downloading in the background. When it’s done, Update appears in the toolbar."),
                                 tone: .green)
                    .padding(.top, 14)
                buttonRow { defaultButton("OK", .dismiss) }
            case .ready(let feed):
                AppUpdateReadyContent(feed: feed, running: running) { perform(.dismiss) }
            case .waitingToRestart(let feed):
                AppUpdateWaitingContent(feed: feed, project: nil) { perform(.dismiss) }
            case .downloadFailed(let feed, let asked):
                available(feed)
                // Not the popover's «… Try again later.»: Try Again is right below.
                AppUpdateNoteBox(text: L10n("The download didn’t finish."), tone: .amber)
                    .padding(.top, 14)
                buttonRow {
                    secondaryButton("Later", .dismiss)
                    defaultButton("Try Again", asked ? .downloadAndInstall : .tryAgain)
                }
            case .askToDownload(let feed):
                available(feed)
                line(L10n("Download it now, or later from New Version in the toolbar."))
                buttonRow {
                    secondaryButton("Later", .dismiss)
                    defaultButton("Download and Install", .downloadAndInstall)
                }
            case .cannotUpdate(let feed):
                found(feed, title: String(format: L10n("New version: SkyCut %@"), feed.version.description),
                      subtitle: L10n("This copy of SkyCut can’t update itself"))
                line(L10n("It isn’t in the Applications folder, or that folder can’t be written to. Download the new version from the website and drag it into Applications to replace this one."))
                buttonRow {
                    secondaryButton("Later", .dismiss)
                    defaultButton("Open Download Page", .openDownloadPage)
                }
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }

    private var youreOn: String { String(format: L10n("You’re on %@ now"), running) }

    /// «SkyCut 0.19.0 is available», the running version and what's new.
    private func available(_ feed: AppUpdateFeed) -> some View {
        found(feed, title: String(format: L10n("SkyCut %@ is available"), feed.version.description), subtitle: youreOn)
    }

    /// The header and what's new of a release the check found.
    @ViewBuilder
    private func found(_ feed: AppUpdateFeed, title: String, subtitle: String) -> some View {
        AppUpdateHeader(icon: "arrow.down.to.line", title: title, subtitle: subtitle)
        AppUpdateNotes(heading: "What’s new", lines: feed.notes(forLanguage: language.language.resolvedCode))
    }

    /// The updater's own progress (AppUpdateState.progress): the percent and the megabytes over a bar; once every byte is
    /// in, «Verifying…» over a moving bar until the copy is checked and staged.
    private func progress(_ feed: AppUpdateFeed, _ fraction: Double?) -> some View {
        let done = min(1, max(0, fraction ?? 0))
        let verifying = done >= 1
        let total = MediaFormatting.bytes(feed.dmgSize)
        let amount = done > 0 ? "\(MediaFormatting.bytes(Int64(Double(feed.dmgSize) * done))) / \(total)" : total
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: verifying ? L10n("Verifying…") : String(format: L10n("Downloading %d%%"), AppUpdateCheckDisplay.percent(fraction)))
                Spacer(minLength: 8)
                Text(verbatim: amount).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Group {
                if fraction != nil, !verifying {
                    ProgressView(value: done)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(AppThemePalette.current.accent)
        }
        .padding(.top, 14)
    }

    private func line(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
    }

    /// The buttons, on the right.
    private func buttonRow<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            Spacer()
            buttons()
        }
        .padding(.top, 16)
    }

    /// Cancel, Later (Escape does the same: AppUpdateCheckPanel).
    private func secondaryButton(_ title: LocalizedStringKey, _ action: AppUpdateCheckAction) -> some View {
        Button(title) { perform(action) }
    }

    /// The filled one: Return.
    private func defaultButton(_ title: LocalizedStringKey, _ action: AppUpdateCheckAction) -> some View {
        Button(title) { perform(action) }
            .buttonStyle(.borderedProminent)
            .tint(AppThemePalette.current.accent)
            .keyboardShortcut(.defaultAction)
    }
}
