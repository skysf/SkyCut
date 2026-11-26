import AppKit
import SwiftUI

// MARK: - The update popover's other contents and the parts they share
//
// What it does: a new version SkyCut only tells about (auto install off: Download and Install, its progress, a download
// that didn't finish; a copy that can't update itself: Open Download Page), the first launch after an update (what's new,
// the AI line only when Connect AI has a client set up, OK), and the shared header, notes list and note box, in the
// mockup's layout with the theme's colours.
// What it doesn't: choose the content (AppUpdatePopover), act (AppUpdater).
// Rules: docs/architecture/app-updates.md "What the person sees".

// MARK: - A new version, auto install off

struct AppUpdateAvailableContent: View {
    let feed: AppUpdateFeed
    let running: String
    let close: () -> Void
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            AppUpdateHeader(icon: "arrow.down.to.line", title: String(format: L10n("New version: SkyCut %@"), feed.version.description),
                            subtitle: String(format: L10n("You’re on %@ now"), running))
            AppUpdateNotes(heading: "What’s new", lines: feed.notes(forLanguage: language.language.resolvedCode))
            if updater.state.phase == .downloading {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: String(format: L10n("Downloading %d%%"), Int(((updater.state.progress ?? 0) * 100).rounded(.down))))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(1, max(0, updater.state.progress ?? 0)))
                        .progressViewStyle(.linear)
                        .tint(AppThemePalette.current.accent)
                }
                .padding(.top, 14)
            } else if updater.state.downloadFailed {
                AppUpdateNoteBox(text: L10n("The download didn’t finish. Try again later."), tone: .amber)
                    .padding(.top, 14)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Later") { close() }
                if updater.state.phase != .downloading {
                    Button("Download and Install") { updater.downloadAndInstall() }
                        .buttonStyle(.borderedProminent)
                        .tint(AppThemePalette.current.accent)
                        .accessibilityIdentifier("app-update-download")
                }
            }
            .padding(.top, 14)
        }
    }
}

// MARK: - A new version this copy can't install

struct AppUpdateCannotContent: View {
    let feed: AppUpdateFeed
    let close: () -> Void

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            AppUpdateHeader(icon: "arrow.down.to.line", title: String(format: L10n("New version: SkyCut %@"), feed.version.description),
                            subtitle: L10n("This copy of SkyCut can’t update itself"))
            Text("It isn’t in the Applications folder, or that folder can’t be written to. Download the new version from the website and drag it into Applications to replace this one.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            HStack(spacing: 8) {
                Spacer()
                Button("Later") { close() }
                Button("Open Download Page") {
                    NSWorkspace.shared.open(AppUpdateFeed.downloadPageURL)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppThemePalette.current.accent)
            }
            .padding(.top, 16)
        }
    }
}

// MARK: - The first launch after an update

struct AppUpdateUpdatedContent: View {
    let note: AppUpdateInstalledNote
    let close: () -> Void
    /// The renders' choice (scripts/render-app-updates.sh); nil asks Connect AI.
    var aiLine: Bool?
    @ObservedObject private var language = AppLanguageStore.shared
    @ObservedObject private var clients = AIClientSetup.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            AppUpdateHeader(icon: "checkmark", title: String(format: L10n("Updated to SkyCut %@"), note.to.description),
                            subtitle: L10n("Installed when you quit"))
            AppUpdateNotes(heading: "What’s new in this version",
                           lines: AppUpdateFeed.notes(note.notes, forLanguage: language.language.resolvedCode))
            if aiLine ?? aiClientSetUp {
                AppUpdateNoteBox(text: L10n("AI chats started before this update, in ChatGPT for example, may need a restart to use the new tools."),
                                 tone: .green)
                    .padding(.top, 14)
            }
            HStack {
                Spacer()
                Button("OK") { close() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppThemePalette.current.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .onAppear { if aiLine == nil { clients.refresh() } }
    }

    /// Connect AI has a client set up for this SkyCut (connected, or connected and still asking per tool).
    private var aiClientSetUp: Bool {
        clients.statuses.values.contains { $0 == .connected || $0 == .connectedAsking }
    }
}

// MARK: - Shared parts

/// The icon tile, the title and the line under it.
struct AppUpdateHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(AppThemePalette.current.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 15, weight: .semibold))
                Text(verbatim: subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "What's new" and the release's lines in the in-app language (English when the feed has none in it).
struct AppUpdateNotes: View {
    let heading: LocalizedStringKey
    let lines: [String]

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: "•")
                        Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(.top, 16)
        }
    }
}

/// The green note (installs at quit, the AI line) and the amber one (recording, a download that didn't finish).
struct AppUpdateNoteBox: View {
    enum Tone { case green, amber }
    let text: String
    let tone: Tone

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Text(verbatim: text)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tone == .green ? AppThemePalette.current.selectionFill : Color.yellow.opacity(0.18))
            }
    }
}
