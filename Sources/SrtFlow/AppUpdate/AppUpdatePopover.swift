import AppKit
import SwiftUI

// MARK: - The update pill's popover: what it says in each state
//
// What it does: one popover, its content chosen by the updater's state: ready (what's new, the green note, Later / Restart
// and Update, the small print), waiting to restart (what it waits for, the recording note, Cancel Restart), a new version
// SkyCut only tells about (auto install off: Download and Install, then its progress; a copy that can't update itself:
// Open Download Page), and the first launch after an update (what's new, the AI line when Connect AI has a client, OK).
// Presented by AppUpdatePill (with `.appLanguage()`); the renders draw the same views.
// What it doesn't: the pill (AppUpdatePill), the updater's rules (AppUpdater, AppUpdateState, AppUpdateBusy).
// Rules: docs/architecture/app-updates.md "What the person sees".

struct AppUpdatePopover: View {
    let project: VideoEditProject
    let close: () -> Void
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Group {
            switch content {
            case .ready(let feed): AppUpdateReadyContent(feed: feed, running: running, close: close)
            case .waiting(let feed): AppUpdateWaitingContent(feed: feed, project: project, close: close)
            case .available(let feed): AppUpdateAvailableContent(feed: feed, running: running, close: close)
            case .cannotUpdate(let feed): AppUpdateCannotContent(feed: feed, close: close)
            case .updated(let note): AppUpdateUpdatedContent(note: note, close: close)
            case .none: EmptyView()
            }
        }
        .modifier(AppUpdatePopoverChrome())
    }

    private var running: String { updater.running?.description ?? "" }

    private var content: AppUpdatePopoverContent {
        AppUpdatePopoverContent.choose(updater.state, mode: updater.mode)
    }
}

/// The popover's margins and width (the renders draw each content with it too).
struct AppUpdatePopoverChrome: ViewModifier {
    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content
            .padding(18)
            .frame(width: 360, alignment: .leading)
    }
}

// MARK: - Downloaded and verified

struct AppUpdateReadyContent: View {
    let feed: AppUpdateFeed
    let running: String
    let close: () -> Void
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            AppUpdateHeader(icon: "arrow.clockwise", title: String(format: L10n("SkyCut %@ is ready"), feed.version.description),
                            subtitle: String(format: L10n("You’re on %@ now"), running))
            AppUpdateNotes(heading: "What’s new", lines: feed.notes(forLanguage: language.language.resolvedCode))
            AppUpdateNoteBox(text: L10n("No need to click: it installs the next time you quit SkyCut, so you’ll have it when you open SkyCut again."),
                             tone: .green)
                .padding(.top, 14)
            HStack(spacing: 8) {
                Spacer()
                Button("Later") { close() }
                Button("Restart and Update") { AppUpdater.shared.requestRestart() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppThemePalette.current.accent)
                    .accessibilityIdentifier("app-update-restart")
            }
            .padding(.top, 14)
            Text("Restarting works like quitting: you’re asked about unsaved projects first. SkyCut then reopens this project.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }
}

// MARK: - Restart and Update, waiting for running work

struct AppUpdateWaitingContent: View {
    let feed: AppUpdateFeed
    /// The window's project ("The AI is editing this project").
    let project: VideoEditProject?
    let close: () -> Void
    /// The renders' sample of running work (scripts/render-app-updates.sh); nil reads the app's stores.
    var sample: AppUpdateBusy?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            AppUpdateHeader(icon: "arrow.clockwise", title: String(format: L10n("SkyCut %@ is ready"), feed.version.description),
                            subtitle: L10n("Restarts as soon as these finish"))
            // Only while the popover is open: what runs is read again every second (AppUpdateBusyProbe), never the clock.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                AppUpdateWaitList(busy: sample ?? AppUpdateBusyProbe.current(for: project))
            }
            HStack {
                Spacer()
                Button("Cancel Restart") {
                    AppUpdater.shared.cancelRestart()
                    close()
                }
                .accessibilityIdentifier("app-update-cancel-restart")
            }
            .padding(.top, 14)
        }
    }
}

/// The rows a waiting restart lists, and the recording note.
struct AppUpdateWaitList: View {
    let busy: AppUpdateBusy

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(busy.rows.enumerated()), id: \.offset) { _, row in
                AppUpdateWaitRow(row: row)
            }
            if busy.recording {
                AppUpdateNoteBox(text: L10n("SkyCut won’t restart while it’s recording. Stop the recording first."), tone: .amber)
            }
        }
        .padding(.top, 14)
    }
}

struct AppUpdateWaitRow: View {
    let row: AppUpdateBusy.Row

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 15)
                Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    Text(verbatim: detail).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.system(size: 13))
            if case .export(_, let progress?) = row {
                ProgressView(value: min(1, max(0, progress)))
                    .progressViewStyle(.linear)
                    .tint(AppThemePalette.current.accent)
                    .padding(.leading, 23)
            }
        }
    }

    private var icon: String {
        switch row {
        case .export: return "square.and.arrow.up"
        case .aiThisProject, .aiProject: return "cpu"
        case .compress: return "film.stack"
        case .burnIn, .generatingSubtitles: return "captions.bubble"
        case .translatingSubtitles: return "character.bubble"
        case .cloudTasks: return "cloud"
        }
    }

    private var text: String {
        switch row {
        case .export(let title, _): return String(format: L10n("Exporting “%@”"), title)
        case .aiThisProject: return L10n("The AI is editing this project")
        case .aiProject(let name): return String(format: L10n("The AI is editing “%@”"), name)
        case .compress(let left): return String(format: L10n("Compressing videos (%d left)"), left)
        case .burnIn(let left): return String(format: L10n("Burning in subtitles (%d left)"), left)
        case .generatingSubtitles: return L10n("Generating subtitles")
        case .translatingSubtitles: return L10n("Translating subtitles")
        case .cloudTasks(let count): return String(format: L10n("Sky Studio tasks (%d)"), count)
        }
    }

    private var detail: String? {
        switch row {
        case .export(_, let progress): return progress.map { MediaFormatting.percent($0) }
        case .aiThisProject, .aiProject: return L10n("When this round ends")
        default: return nil
        }
    }
}
