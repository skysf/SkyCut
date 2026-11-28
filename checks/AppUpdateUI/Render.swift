import AppKit
import SwiftUI
@testable import SrtFlow

// Off-screen renders of SkyCut's update UI (scripts/render-app-updates.sh) in en / zh-Hans / es: the toolbar pill's three
// looks in a toolbar strip; every popover (ready; waiting for running work, with the recording note; auto install off;
// downloading; a download that didn't finish; a copy that can't update itself; after an update with and without the AI
// line); the window of a check started from the menu, in each state (the production panel around the production content:
// checking, up to date, couldn't check, downloading at 29%, verifying, downloaded and ready, a download that didn't finish,
// found with auto install off, found by a copy that can't update itself); the app menu's item in its four titles, greyed
// while a check runs (a SwiftUI stand-in: the real menu bar can't be captured off-screen); Settings › General › Software
// Update (on, off, ready, can't, checking with its spinner, and with the test hook set). It also prints how the check
// window's frame changes from checking to a download (its top edge should stay where it is).
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

    static let running = AppUpdateVersion("0.18.73")!
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

    /// The longest notes a feed may hold: 8 lines of 300 characters (what's new then scrolls in the check window).
    static let longFeed: AppUpdateFeed = {
        func line(_ text: String) -> String { String(String(repeating: text, count: 300).prefix(300)) }
        let notes = ["zh-Hans": Array(repeating: line("新版本会在后台下载好，退出时自动装上。"), count: 8),
                     "en": Array(repeating: line("New versions download in the background and install when you quit. "), count: 8),
                     "es": Array(repeating: line("Las versiones nuevas se descargan en segundo plano y se instalan al salir. "), count: 8)]
        let object: [String: Any] = [
            "schema": 1, "bundle_id": "com.srtflow.SrtFlow", "version": "0.19.0", "build": "1", "minimum_macos": "15.0",
            "dmg_url": "https://downloads.skylu.ai/skycut/SkyCut-0.19.0-abababababab-arm64.dmg", "dmg_size": 42_431_367,
            "dmg_sha256": String(repeating: "ab", count: 32), "notes": notes,
        ]
        return AppUpdateFeed.parse(try! JSONSerialization.data(withJSONObject: object), from: .production)!
    }()

    @MainActor
    private static func show(_ phase: AppUpdateState.Phase, decision: AppUpdateEligibility.Decision = .updates, automatic: Bool = true,
                             progress: Double? = nil, failed: Bool = false, asked: Bool = false, checking: Bool = false,
                             testFeed: URL? = nil) {
        var state = AppUpdateState()
        state.phase = phase
        state.offer = phase == .idle ? nil : feed
        state.progress = progress
        state.downloadFailed = failed
        state.downloadAsked = asked
        state.checking = checking
        let today = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: Date())
        AppUpdater.shared.showForRender(state, decision: decision, automatic: automatic, running: running, lastUpToDate: today,
                                        testFeed: testFeed)
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
        // 0.2905 of the sample DMG is 12.3 MB of 42.4 MB, 29% (the window floors whole percents as Settings and the popover
        // do, and 0.29 × 100 is just under 29 in floating point); at 1 every byte is in and the copy is being verified.
        for (name, display) in [("checking", AppUpdateCheckDisplay.checking), ("up-to-date", .upToDate), ("failed", .couldNotCheck),
                                ("downloading", .downloading(feed, fraction: 0.2905)), ("verifying", .downloading(feed, fraction: 1)),
                                ("ready", .ready(feed)), ("download-failed", .downloadFailed(feed, asked: false)),
                                ("found-auto-off", .askToDownload(feed)), ("found-cannot-update", .cannotUpdate(feed))] {
            let host = NSHostingView(rootView: AppUpdateCheckContent(display: display, running: running.description) { _ in }.appLanguage())
            try await Snapshot.takeWindow(behindEverything(AppUpdateCheckWindow.panel(around: host)), to: file("check-window-\(name)"))
        }
        // The longest notes a feed allows: what's new scrolls, the buttons stay in the window.
        let longHost = NSHostingView(rootView: AppUpdateCheckContent(display: .downloading(longFeed, fraction: 0.2905),
                                                                     running: running.description) { _ in }.appLanguage())
        try await Snapshot.takeWindow(behindEverything(AppUpdateCheckWindow.panel(around: longHost)), to: file("check-window-long-notes"))
        if code == "en" {
            try await probeResize()
            // Classic, in the system's light and dark: the window is new, so both appearances get a look. Classic follows the
            // system (SystemColorScheme reads NSApp.effectiveAppearance), so this render app plays a dark system by setting
            // its own appearance for the dark pictures (SkyCut itself never sets NSApp.appearance).
            AppThemeStore.shared.setTheme(.classic)
            for (look, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
                NSApp.appearance = appearance
                try await Task.sleep(nanoseconds: 300_000_000)
                for (name, display) in [("checking", AppUpdateCheckDisplay.checking), ("downloading", .downloading(feed, fraction: 0.2905))] {
                    let host = NSHostingView(rootView: AppUpdateCheckContent(display: display, running: running.description) { _ in }.appLanguage())
                    try await Snapshot.takeWindow(behindEverything(AppUpdateCheckWindow.panel(around: host)),
                                                  to: file("check-window-classic-\(look)-\(name)"), appearance: appearance)
                }
            }
            NSApp.appearance = nil
            AppThemeStore.shared.setTheme(.forest)
        }
        try await Snapshot.take(AppUpdateMenuStandIn(), to: file("menu"))
        for (name, phase, decision, automatic, checking) in [
            ("on", AppUpdateState.Phase.idle, AppUpdateEligibility.Decision.updates, true, false), ("off", .idle, .updates, false, false),
            ("ready", .ready, .updates, true, false), ("cannot-update", .idle, .notifyOnly(.folderNotWritable), true, false),
            ("checking", .idle, .updates, true, true),
        ] {
            show(phase, decision: decision, automatic: automatic, checking: checking)
            try await Snapshot.take(Form { AppUpdateSettingsSection() }.formStyle(.grouped).scrollDisabled(true),
                                    to: file("settings-\(name)"), size: CGSize(width: 586, height: 250))
        }
        // A test hook left set: its address under the status line.
        show(.idle, testFeed: URL(string: "http://127.0.0.1:8123/skycut.json"))
        try await Snapshot.take(Form { AppUpdateSettingsSection() }.formStyle(.grouped).scrollDisabled(true),
                                to: file("settings-test-feed"), size: CGSize(width: 586, height: 270))
    }

    /// The check window's panel as the app makes it, at the normal level and never hidden for the capture: the render app is
    /// never active, and a floating panel ordered back would still sit above every normal window on the screen.
    @MainActor
    private static func behindEverything(_ panel: NSPanel) -> NSPanel {
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        return panel
    }

    /// The check window turning from checking into a download with notes and a bar, in one panel, twice: in the middle of
    /// the screen (its top edge stays, it grows downward) and moved low (it is lifted just enough to stay whole on screen).
    @MainActor
    private static func probeResize() async throws {
        let visible = NSScreen.main?.visibleFrame ?? .zero
        for (place, y) in [("middle", visible.midY), ("low", visible.minY + 40)] {
            let model = AppUpdateResizeProbe()
            let panel = behindEverything(AppUpdateCheckWindow.panel(around: NSHostingView(rootView: AppUpdateResizeProbeRoot(model: model).appLanguage())))
            panel.ignoresMouseEvents = true
            panel.setFrameOrigin(NSPoint(x: visible.minX, y: y))
            panel.orderBack(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            let before = panel.frame
            model.display = .downloading(feed, fraction: 0.29)
            try await Task.sleep(nanoseconds: 300_000_000)
            let after = panel.frame
            let verdict = after.minY < visible.minY ? "OFF SCREEN at the bottom"
                : before.maxY == after.maxY ? "top edge kept" : "lifted to stay whole on screen"
            print("resize probe (\(place)): checking \(before) → download \(after); \(verdict)")
            panel.orderOut(nil)
        }
    }
}

@MainActor
private final class AppUpdateResizeProbe: ObservableObject {
    @Published var display: AppUpdateCheckDisplay = .checking
}

private struct AppUpdateResizeProbeRoot: View {
    @ObservedObject var model: AppUpdateResizeProbe

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        AppUpdateCheckContent(display: model.display, running: AppUpdateRender.running.description) { _ in }
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

/// The app menu's item as a stand-in (the menu bar can't be captured off-screen): normally, greyed while a check runs (in
/// the colour AppKit gives a disabled menu item), while a download runs (29%), and once an update is ready.
private struct AppUpdateMenuStandIn: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(alignment: .top, spacing: 24) {
            item(Text("Check for Updates…"))
            item(Text("Checking for Updates…").foregroundStyle(Color(nsColor: .disabledControlTextColor)))
            item(Text(verbatim: String(format: L10n("Downloading Update (%d%%)…"), 29)))
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
