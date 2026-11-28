import AppKit
import Combine
import Foundation
import os

// MARK: - The updater: checks quietly, downloads in the background, installs at quit
//
// What it does: SkyCut's one updater, on the main actor. Started with the launch's services, it reads what it needs off the
// main thread, checks about a minute later and then every 24 hours while SkyCut runs (the app menu and the Settings button
// check at once), downloads, verifies and stages a newer release in the background (auto install on, or after Download and
// Install), and installs the staged copy at every quit (applicationWillTerminate, after the quit flow). It publishes the
// state the toolbar pill, its popovers, the app menu and Settings show, and the test hook's address while one is set.
// Nothing pops up by itself: the only window is the one of a check the person started from the menu (AppUpdateCheckWindow,
// shown from run-loop turns, never inside a Swift task); its Cancel stops that check. Offline or any failure: nothing is
// said; the next check tries again (a DMG that keeps failing is held back: AppUpdateRetryRecord).
// The transitions are AppUpdateState's (pure, checked); this file runs their effects.
// What it doesn't: the rules (AppUpdateEligibility, AppUpdateState), transfers (AppUpdatePipeline, AppUpdateHTTP,
// AppUpdateStager), the swap (AppUpdateInstaller), the restart's waiting and relaunch (AppUpdateRestart), the views.
// Rules: docs/architecture/app-updates.md.

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    /// The Settings switch (default on). Identity-class key names keep the SrtFlow prefix (docs/architecture/product-name.md).
    static let automaticKey = "SrtFlow.update.automatic.v1"
    /// When a check last found nothing newer (the Settings status line).
    static let lastUpToDateKey = "SrtFlow.update.lastUpToDate.v1"
    static let firstCheckDelay: Duration = .seconds(60)
    static let checkInterval: Duration = .seconds(24 * 60 * 60)
    nonisolated static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "update")

    @Published private(set) var state = AppUpdateState()
    @Published private(set) var lastUpToDate: Date?
    /// How this copy takes updates; nil until the launch's reading is in, and for a copy that never updates (SkyCut Beta,
    /// dev, check and smoke builds): no menu item, no Settings section, no pill.
    @Published private(set) var decision: AppUpdateEligibility.Decision?
    /// The test hook's address while it is set to one SkyCut uses (Settings shows it: a leftover hook is never silent).
    @Published private(set) var testFeedURL: URL?
    @Published var automatic: Bool {
        didSet {
            guard automatic != oldValue else { return }
            defaults.set(automatic, forKey: Self.automaticKey)
            send(.automaticChanged)
        }
    }
    /// The running version (nil only for a copy that never updates).
    private(set) var running: AppUpdateVersion?

    private let defaults = UserDefaults.standard
    private let files = AppUpdateFiles.standard()
    private var started = false
    /// The check in flight (its window's Cancel stops it).
    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var restartTimer: Timer?
    private var lastProgressPercent: Int?

    private init() {
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        lastUpToDate = defaults.object(forKey: Self.lastUpToDateKey) as? Date
    }

    var mode: AppUpdateMode? {
        switch decision {
        case .updates: return .install(automatic: automatic)
        case .notifyOnly(let reason): return .notifyOnly(reason)
        case .never, nil: return nil
        }
    }

    /// The release the pill, popovers and menu talk about.
    var offerVersion: String? { state.offer?.version.description }

    /// The UI's names of the buttons get_status's hints quote, in the App's language (the same keys as the pill, popovers
    /// and menu).
    static var buttonNames: AppUpdateStatusReport.Buttons {
        AppUpdateStatusReport.Buttons(update: L10n("Update"), newVersion: L10n("New Version"), restartAndUpdate: L10n("Restart and Update"),
                                      downloadInstallButton: L10n("Download and Install"), openDownloadPage: L10n("Open Download Page"),
                                      checkForUpdates: L10n("Check for Updates…"))
    }

    /// get_status's `app_update`: what the pill and Settings show, read as it is now. Never a check, a download or an install.
    var statusReport: AppUpdateStatusReport {
        AppUpdateStatusReport.make(state, decision: decision, automatic: automatic, lastUpToDate: lastUpToDate,
                                   language: AppLanguageStore.shared.language.resolvedCode, buttons: Self.buttonNames)
    }

    // MARK: Starting and checking

    /// From startServices. Everything blocking happens off the main thread; the first check waits about a minute.
    func start() {
        guard !started else { return }
        started = true
        AppUpdateRestart.reopenProjectsIfRestarted()
        let files = files
        let source = currentSource()
        Task { @MainActor in
            let reading = await AppUpdateWork.run { AppUpdateLaunch.read(files: files, source: source) }
            adopt(reading)
        }
    }

    private func adopt(_ reading: AppUpdateLaunch.Reading) {
        running = reading.running
        decision = reading.decision
        guard let mode, let running = reading.running else { return }
        state = AppUpdateState.atLaunch(staged: reading.files.staged, updated: reading.files.installed, retry: reading.files.retry,
                                        mode: mode, running: running)
        scheduleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                self?.check(from: .schedule)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Checks now. The menu's check has a window (it opens at once, then shows the answer); Settings' and the schedule's
    /// don't. The person's (menu, Settings) also fetches a DMG an automatic check holds back.
    func check(from origin: AppUpdateCheckOrigin) {
        guard mode != nil, let running else { return }
        let alreadyChecking = state.checking
        send(.checkStarted(origin))
        guard !alreadyChecking else { return }   // the check in flight answers
        let source = currentSource()
        checkTask = Task { @MainActor in
            let result = await AppUpdateHTTP.check(source, running: running)
            // Cancelled from its window: checkCancelled has ended it (a newer check may already run). Nothing is reported.
            guard !Task.isCancelled else { return }
            if result == .upToDate {
                let now = Date()
                lastUpToDate = now
                defaults.set(now, forKey: Self.lastUpToDateKey)
            }
            send(.checkFinished(result, at: Date()))
        }
    }

    /// The feed's address now: the test hook when set to one SkyCut accepts (read at every check, and shown in Settings).
    private func currentSource() -> AppUpdateFeed.Source {
        let source = AppUpdateFeed.Source.resolve(override: defaults.string(forKey: AppUpdateFeed.Source.overrideKey))
        if !renderOnly {
            let hook = source.isTestHook ? source.feedURL : nil
            if testFeedURL != hook { testFeedURL = hook }
        }
        return source
    }

    /// Settings appearing: the test hook read again (`defaults write` / `delete` while SkyCut runs).
    func refreshTestFeed() { _ = currentSource() }

    // MARK: The person's buttons

    /// The app menu's "Restart and Update to …" asked for the pill's popover in the window of this project (the focused one):
    /// that window's pill opens it (AppUpdatePill), now or when the window appears.
    @Published private(set) var popoverRequest: ObjectIdentifier?

    func requestPopover(for project: VideoEditProject) { popoverRequest = ObjectIdentifier(project) }

    func popoverPresented() { popoverRequest = nil }

    /// Download and Install (auto install off).
    func downloadAndInstall() { send(.downloadAsked) }

    /// Cancel in the menu check's window: the check stops, unless the schedule's check shares it (it then goes on, unanswered).
    func cancelCheck() { send(.checkCancelled) }

    func notesViewed() { send(.notesViewed) }

    /// Restart and Update: now if nothing runs, else when what runs has finished (AppUpdateBusy), checked every second.
    func requestRestart() {
        send(.restartRequested)
        guard state.restartPending else { return }
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.restartIfIdle() }
        }
        restartIfIdle()
    }

    func cancelRestart() {
        send(.restartCancelled)
        restartTimer?.invalidate()
        restartTimer = nil
    }

    private func restartIfIdle() {
        guard state.restartPending else {
            restartTimer?.invalidate()
            restartTimer = nil
            return
        }
        guard AppUpdateBusyProbe.current(for: nil).isIdle else { return }
        cancelRestart()
        AppUpdateRestart.quitToRestart()
    }

    /// The off-screen renders only (scripts/render-app-updates.sh): show `state` as a copy in `decision` would. From then on
    /// nothing runs: no transition, no download, no file, no defaults read (the switch set here would otherwise start one).
    func showForRender(_ state: AppUpdateState, decision: AppUpdateEligibility.Decision, automatic: Bool, running: AppUpdateVersion,
                       lastUpToDate: Date?, testFeed: URL? = nil) {
        renderOnly = true
        self.automatic = automatic
        self.state = state
        self.decision = decision
        self.running = running
        self.lastUpToDate = lastUpToDate
        testFeedURL = testFeed
    }

    /// Set by showForRender: events change nothing and start nothing.
    private var renderOnly = false

    // MARK: Quit

    /// applicationWillTerminate (the quit flow has saved and asked about every project): installs the staged copy if this
    /// copy installs it, then relaunches when the quit is Restart and Update's. A copy an earlier run staged is installed
    /// only once this launch's first check has confirmed it or failed to reach the feed (until then the phase isn't ready).
    func installAtQuit() {
        defer { AppUpdateRestart.finishQuit() }
        guard decision == .updates, state.phase == .ready, let offer = state.offer, let running,
              let record = files.readStaged(), record.feed.isSameRelease(as: offer) else { return }
        downloadTask?.cancel()
        let bundle = Bundle.main.bundleURL
        let installer = AppUpdateInstaller(
            destination: bundle, files: files,
            verify: { staged, feed in
                try AppUpdateVerifier.verify(staged, feed: feed, runningApp: bundle, running: running, atQuit: true)
            },
            othersRunning: { RunningBundleProbe.processes(inside: $0).contains { $0 != getpid() } },
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        let outcome = installer.install(record, running: running)
        Self.log.notice("install at quit: \(String(describing: outcome), privacy: .public)")
    }

    // MARK: Effects

    private func send(_ event: AppUpdateEvent) {
        guard let mode, !renderOnly else { return }
        for effect in state.apply(event, mode: mode) { run(effect) }
    }

    /// File effects go straight onto AppUpdateWork's serial queue, in order, ahead of anything a download started by the same
    /// transition queues there; and only for a copy that installs (the state machine gives a copy that only tells none).
    private func run(_ effect: AppUpdateEffect) {
        let files = files
        if effect.touchesFiles {
            guard decision == .updates else { return }
        }
        switch effect {
        case .download(let feed):
            startDownload(feed)
        case .cancelDownload:
            downloadTask?.cancel()
            downloadTask = nil
        case .discardStaged:
            AppUpdateWork.queue.addOperation { files.removeStaged(except: nil) }
        case .discardDownloads(let kept):
            AppUpdateWork.queue.addOperation { files.removeDownloads(except: kept.map(files.dmg(for:))) }
        case .saveRetry(let record):
            AppUpdateWork.queue.addOperation { files.writeRetry(record) }
        case .stopCheck:
            checkTask?.cancel()
            checkTask = nil
        // The window is shown from run-loop turns after this one, never inside a transition and never inside a Swift task
        // (the answer comes from the check's task): an Objective-C exception raised there would unwind the task and leave
        // the runtime's executor tracking dangling, and the next isolation check crashed SkyCut. Not DispatchQueue.main.async
        // either: an exception escaping a dispatch block ends the app. The window is not modal: no runModal anywhere
        // (docs/bugfixes/2026-11-27-check-for-updates-crash-tracking-owner-selectors.md, system-file-windows.md rule 10).
        case .openCheckWindow:
            RunLoop.main.perform { MainActor.assumeIsolated { AppUpdateCheckWindow.shared.open() } }
        case .answer(let answer):
            RunLoop.main.perform { MainActor.assumeIsolated { AppUpdateCheckWindow.shared.show(answer) } }
        }
    }

    private func startDownload(_ feed: AppUpdateFeed) {
        downloadTask?.cancel()
        guard let running else { return }
        let files = files
        let asked = state.downloadAsked
        let bundle = Bundle.main.bundleURL
        let stager = AppUpdateStager(files: files, bundleIdentifier: Bundle.main.bundleIdentifier ?? "") { copy, feed in
            try AppUpdateVerifier.verify(copy, feed: feed, runningApp: bundle, running: running, atQuit: false)
        }
        lastProgressPercent = nil
        downloadTask = Task { @MainActor [weak self] in
            let outcome = await AppUpdatePipeline.run(feed, files: files, stager: stager, appName: bundle.lastPathComponent,
                                                      asked: asked) { fraction in
                Task { @MainActor in self?.progressed(fraction) }
            }
            guard !Task.isCancelled, let self else { return }
            self.send(outcome.event(for: feed, at: Date()))
        }
    }

    /// Whole percents only: the pill and Settings don't redraw for every block of a download.
    private func progressed(_ fraction: Double) {
        let percent = Int((fraction * 100).rounded(.down))
        guard percent != lastProgressPercent else { return }
        lastProgressPercent = percent
        send(.downloadProgress(fraction))
    }
}
