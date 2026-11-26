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
// state the toolbar pill, its popovers, the app menu and Settings show. Nothing pops up by itself: the only window is the
// answer to a check the person started from the menu. Offline or any failure: nothing is said; the next check tries again.
// The transitions are AppUpdateState's (pure, checked); this file runs their effects.
// What it doesn't: the rules (AppUpdateEligibility, AppUpdateState), transfers (AppUpdateHTTP, AppUpdateStager), the swap
// (AppUpdateInstaller), the restart's waiting and relaunch (AppUpdateRestart), the views.
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
        state = AppUpdateState.atLaunch(staged: reading.staged, updated: reading.installed, mode: mode, running: running)
        scheduleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                self?.check(byPerson: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Checks now. `byPerson` (the app menu) gets an answer window; the Settings button and the schedule don't.
    func check(byPerson: Bool) {
        guard mode != nil, let running else { return }
        let alreadyChecking = state.checking
        send(.checkStarted(byPerson: byPerson))
        guard !alreadyChecking else { return }   // the check in flight answers
        let source = currentSource()
        Task { @MainActor in
            let result = await AppUpdateHTTP.check(source, running: running)
            if result == .upToDate {
                let now = Date()
                lastUpToDate = now
                defaults.set(now, forKey: Self.lastUpToDateKey)
            }
            send(.checkFinished(result))
        }
    }

    /// The feed's address now: the test hook when set to one SkyCut accepts (read at every check).
    private func currentSource() -> AppUpdateFeed.Source {
        AppUpdateFeed.Source.resolve(override: defaults.string(forKey: AppUpdateFeed.Source.overrideKey))
    }

    // MARK: The person's buttons

    /// The app menu's "Restart and Update to …" asked for the pill's popover in the window of this project (the focused one):
    /// that window's pill opens it (AppUpdatePill), now or when the window appears.
    @Published private(set) var popoverRequest: ObjectIdentifier?

    func requestPopover(for project: VideoEditProject) { popoverRequest = ObjectIdentifier(project) }

    func popoverPresented() { popoverRequest = nil }

    /// Download and Install (auto install off).
    func downloadAndInstall() { send(.downloadAsked) }

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

    /// The off-screen renders only (scripts/render-app-updates.sh): show `state` as a copy in `decision` would. Nothing runs.
    func showForRender(_ state: AppUpdateState, decision: AppUpdateEligibility.Decision, running: AppUpdateVersion, lastUpToDate: Date?) {
        self.state = state
        self.decision = decision
        self.running = running
        self.lastUpToDate = lastUpToDate
    }

    // MARK: Quit

    /// applicationWillTerminate (the quit flow has saved and asked about every project): installs the staged copy if this
    /// copy installs it, then relaunches when the quit is Restart and Update's.
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
        guard let mode else { return }
        for effect in state.apply(event, mode: mode) { run(effect) }
    }

    private func run(_ effect: AppUpdateEffect) {
        switch effect {
        case .download(let feed):
            startDownload(feed)
        case .cancelDownload:
            downloadTask?.cancel()
            downloadTask = nil
        case .discardStaged:
            let files = files
            Task { await AppUpdateWork.run { files.removeStaged(except: nil); files.removeDownloads() } }
        case .answer(let answer):
            // After this turn: the answer window must not run its modal loop inside a transition.
            Task { @MainActor in AppUpdateAlerts.show(answer) }
        }
    }

    private func startDownload(_ feed: AppUpdateFeed) {
        downloadTask?.cancel()
        guard let running else { return }
        let files = files
        let asked = state.downloadAsked
        lastProgressPercent = nil
        downloadTask = Task { @MainActor [weak self] in
            let staged = await Self.downloadAndStage(feed, files: files, asked: asked, running: running) { fraction in
                Task { @MainActor in self?.progressed(fraction) }
            }
            guard !Task.isCancelled, let self else { return }
            self.send(staged ? .staged(feed) : .downloadFailed)
        }
    }

    /// Whole percents only: the pill and Settings don't redraw for every block of a download.
    private func progressed(_ fraction: Double) {
        let percent = Int((fraction * 100).rounded(.down))
        guard percent != lastProgressPercent else { return }
        lastProgressPercent = percent
        send(.downloadProgress(fraction))
    }

    /// A copy of this release already staged (auto install off, then Download and Install; or an earlier run's), else
    /// download, check, open, copy, verify and stage it. False for any failure (said to nobody).
    nonisolated static func downloadAndStage(_ feed: AppUpdateFeed, files: AppUpdateFiles, asked: Bool, running: AppUpdateVersion,
                                             progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let bundle = Bundle.main.bundleURL
        let adopted = await AppUpdateWork.run { () -> Bool in
            guard var record = files.readStaged(), record.feed.isSameRelease(as: feed),
                  FileManager.default.fileExists(atPath: record.appPath) else { return false }
            if asked, !record.asked {
                record.asked = true
                try? files.writeStaged(record)
            }
            return true
        }
        if adopted { return true }
        let dmg = files.dmg(for: feed)
        do {
            try await AppUpdateWork.run { Result { try files.makeFolders() } }.get()
            try await AppUpdateHTTP.download(feed, to: dmg, progress: progress)
            try Task.checkCancellation()
        } catch {
            log.notice("download failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let stager = AppUpdateStager(files: files, bundleIdentifier: Bundle.main.bundleIdentifier ?? "") { copy, feed in
            try AppUpdateVerifier.verify(copy, feed: feed, runningApp: bundle, running: running, atQuit: false)
        }
        let staged = await AppUpdateWork.run { () -> Result<AppUpdateStagedRecord, Error> in
            defer { files.removeDownloads() }
            return Result { try stager.stage(dmg, feed: feed, appName: bundle.lastPathComponent, asked: asked) }
        }
        if case .failure(let error) = staged { log.notice("staging failed: \(error.localizedDescription, privacy: .public)") }
        return (try? staged.get()) != nil
    }
}
