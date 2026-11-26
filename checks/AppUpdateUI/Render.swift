import AppKit
import SwiftUI
@testable import SrtFlow

// Off-screen renders of SkyCut's update UI (scripts/render-app-updates.sh) in en / zh-Hans / es: the toolbar pill's three
// looks in a toolbar strip; every popover (ready; waiting for running work, with the recording note; auto install off;
// downloading; a download that didn't finish; a copy that can't update itself; after an update with and without the AI
// line); the answers to a check started from the menu (the production NSAlerts); the app menu's item in both titles (a
// SwiftUI stand-in: the real menu bar can't be captured off-screen); Settings › General › Software Update (on, off, can't).
// The production views, fed sample states (AppUpdater.showForRender) and sample notes. Only images, no verdicts: the
// behaviour is pinned by scripts/check-app-update.sh.

@main enum AppUpdateRender {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.appupdaterender"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("The update render requires the isolated bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["SRTFLOW_UPDATE_RENDER_OUT"]!)
        if let icon = environment["SRTFLOW_UPDATE_RENDER_ICON"].flatMap(NSImage.init(contentsOfFile:)) {
            NSApp.applicationIconImage = icon
        }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                AppLanguageStore.shared.language = language
                try await render(language.rawValue, to: out)
            }
        } catch {
            print("FAIL: update render: \(error)")
            exit(1)
        }
        print("PASS: rendered the update UI in en, zh-Hans and es to \(out.path)")
        exit(0)
    }

    static let running = AppUpdateVersion("0.18.68")!
    static let notes = [
        "zh-Hans": ["新版本会在后台下载好，退出时自动装上", "字幕的长句在更合适的地方折行", "修了几处偶尔卡住的问题"],
        "en": ["New versions download in the background and install when you quit", "Long subtitle lines break in better places",
               "Fixed a few rare hangs"],
        "es": ["Las versiones nuevas se descargan en segundo plano y se instalan al salir",
               "Las líneas largas de subtítulos se cortan en mejores sitios", "Arreglados algunos bloqueos poco frecuentes"],
    ]
    static let feed: AppUpdateFeed = {
        let object: [String: Any] = [
            "schema": 1, "bundle_id": "com.srtflow.SrtFlow", "version": "0.19.0", "build": "1", "minimum_macos": "15.0",
            "dmg_url": "https://downloads.skylu.ai/skycut/SkyCut-0.19.0-abababababab-arm64.dmg", "dmg_size": 42_431_367,
            "dmg_sha256": String(repeating: "ab", count: 32), "notes": notes,
        ]
        return AppUpdateFeed.parse(try! JSONSerialization.data(withJSONObject: object), from: .production)!
    }()

    @MainActor
    private static func show(_ phase: AppUpdateState.Phase, decision: AppUpdateEligibility.Decision = .updates, automatic: Bool = true,
                             progress: Double? = nil, failed: Bool = false, asked: Bool = false) {
        AppUpdater.shared.automatic = automatic
        var state = AppUpdateState()
        state.phase = phase
        state.offer = phase == .idle ? nil : feed
        state.progress = progress
        state.downloadFailed = failed
        state.downloadAsked = asked
        let today = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: Date())
        AppUpdater.shared.showForRender(state, decision: decision, running: running, lastUpToDate: today)
    }

    @MainActor
    private static func render(_ code: String, to out: URL) async throws {
        func file(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(code).png") }
        let close = {}
        try await Snapshot.take(AppUpdatePillStrip(), to: file("pills"))
        show(.ready)
        try await Snapshot.take(AppUpdateReadyContent(feed: feed, running: running.description, close: close)
            .modifier(AppUpdatePopoverChrome()), to: file("popover-ready"))
        let busy = AppUpdateBusy(exports: [.init(title: "南极预告片 Trailer", progress: 0.62)],
                                 aiEditing: [.init(projectName: "Trailer", isThisProject: true)], compressLeft: 2, recording: true)
        try await Snapshot.take(AppUpdateWaitingContent(feed: feed, project: nil, close: close, sample: busy)
            .modifier(AppUpdatePopoverChrome()), to: file("popover-waiting"))
        show(.available, automatic: false)
        try await Snapshot.take(AppUpdateAvailableContent(feed: feed, running: running.description, close: close)
            .modifier(AppUpdatePopoverChrome()), to: file("popover-auto-off"))
        show(.downloading, automatic: false, progress: 0.42, asked: true)
        try await Snapshot.take(AppUpdateAvailableContent(feed: feed, running: running.description, close: close)
            .modifier(AppUpdatePopoverChrome()), to: file("popover-downloading"))
        show(.available, automatic: false, failed: true)
        try await Snapshot.take(AppUpdateAvailableContent(feed: feed, running: running.description, close: close)
            .modifier(AppUpdatePopoverChrome()), to: file("popover-download-failed"))
        try await Snapshot.take(AppUpdateCannotContent(feed: feed, close: close).modifier(AppUpdatePopoverChrome()),
                                to: file("popover-cannot-update"))
        let note = AppUpdateInstalledNote(from: running, to: feed.version, notes: notes)
        try await Snapshot.take(AppUpdateUpdatedContent(note: note, close: close, aiLine: true).modifier(AppUpdatePopoverChrome()),
                                to: file("popover-updated"))
        try await Snapshot.take(AppUpdateUpdatedContent(note: note, close: close, aiLine: false).modifier(AppUpdatePopoverChrome()),
                                to: file("popover-updated-no-ai"))
        for (name, answer) in [("up-to-date", AppUpdateCheckAnswer.upToDate), ("found", .downloading(feed)),
                               ("found-auto-off", .askToDownload(feed)), ("found-cannot-update", .cannotUpdate(feed)), ("failed", .failed)] {
            let alert = AppUpdateAlerts.make(answer, running: name == "up-to-date" ? feed.version.description : running.description)
            if let icon = NSApp.applicationIconImage { alert.icon = icon }
            alert.layout()
            try await Snapshot.takeWindow(alert.window, to: file("check-\(name)"))
        }
        try await Snapshot.take(AppUpdateMenuStandIn(), to: file("menu"))
        for (name, phase, decision, automatic) in [("on", AppUpdateState.Phase.idle, AppUpdateEligibility.Decision.updates, true),
                                                   ("off", .idle, .updates, false), ("ready", .ready, .updates, true),
                                                   ("cannot-update", .idle, .notifyOnly(.folderNotWritable), true)] {
            show(phase, decision: decision, automatic: automatic)
            try await Snapshot.take(Form { AppUpdateSettingsSection() }.formStyle(.grouped).scrollDisabled(true),
                                    to: file("settings-\(name)"), size: CGSize(width: 586, height: 250))
        }
    }
}

/// The three looks of the pill in a strip of the toolbar's right group.
private struct AppUpdatePillStrip: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 12) {
            ForEach([AppUpdateState.Pill.ready, .newVersion, .updated], id: \.self) { pill in
                HStack(spacing: 14) {
                    AppUpdatePillLabel(pill: pill)
                    ForEach(["cloud", "square.and.arrow.up", "gearshape", "ellipsis"], id: \.self) { Image(systemName: $0) }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(AppThemePalette.current.window))
            }
        }
        .padding(16)
    }
}

/// The app menu's item as a stand-in (the menu bar can't be captured off-screen): normally, and once an update is ready.
private struct AppUpdateMenuStandIn: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(alignment: .top, spacing: 24) {
            item(Text("Check for Updates…"))
            item(Text(verbatim: String(format: L10n("Restart and Update to %@…"), "0.19.0")))
        }
        .padding(16)
    }

    private func item(_ title: Text) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "SkyCut").font(.caption).foregroundStyle(.secondary)
            Divider()
            title.padding(.vertical, 2)
            Divider()
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
    }
}
