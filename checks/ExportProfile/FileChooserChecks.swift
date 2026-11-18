import AppKit
import Foundation
@testable import SrtFlow

// The macOS open / save window (SystemFileChooser; the export panel's folder window drives one), driven through a fake
// window that behaves the way the macOS panel service was measured to behave
// (docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md): answers; a person cancels; comes back empty at once;
// never appears (AppKit after its 60 s wait); appears then vanishes without an answer (service crash); stays on screen and
// never answers (service hung). Plus the record a force quit leaves behind. No real NSOpenPanel: that needs the window
// server and the user's panel service. The shared windows and their helper: FileWindowsChecks.swift.
@MainActor enum FileChooserChecks {
    static func run(require: (Bool, String) -> Void) async {
        let suite = "com.srtflow.SrtFlow.exportprofilecheck.chooser"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let record = SystemFileWindowRecord(suiteName: suite)
        let start = URL(fileURLWithPath: "/tmp/start", isDirectory: true)
        let picked = URL(fileURLWithPath: "/tmp/picked", isDirectory: true)

        // A folder comes back: taken, record cleared; the record existed while AppKit was being asked for the window.
        var recordWhileMaking = false
        let answering = Harness(record: record) { _ in
            recordWhileMaking = UserDefaults(suiteName: suite)?.dictionary(forKey: SystemFileWindowRecord.key) != nil
            return FakeFolderPanel(.answers(picked, after: 0.2))
        }
        answering.chooser.choose(.exportFolder(startingAt: start)) { answering.chosen = $0?.first }
        require(answering.chooser.phase == .choosing, "the chooser is choosing while the window is up")
        await answering.settle(seconds: 1)
        require(answering.chosen == picked && answering.chooser.phase == .idle, "a chosen folder is handed over")
        require(recordWhileMaking, "the in-flight record is written before AppKit is asked for the window")
        require(!hasRecord(suite), "the record is cleared once the window answered")

        // A person cancels after looking: no folder, no failure.
        let cancelling = Harness(record: record) { _ in FakeFolderPanel(.answers(nil, after: 1.4)) }
        cancelling.chooser.choose(.exportFolder(startingAt: start)) { cancelling.chosen = $0?.first }
        await cancelling.settle(seconds: 2)
        require(cancelling.chosen == nil && cancelling.chooser.phase == .idle, "a person's cancel is just a cancel")

        // Empty at once: AppKit failing, faster than a person can cancel.
        let atOnce = Harness(record: record) { _ in FakeFolderPanel(.answers(nil, after: 0.05)) }
        atOnce.chooser.choose(.exportFolder(startingAt: start)) { atOnce.chosen = $0?.first }
        await atOnce.settle(seconds: 0.5)
        require(atOnce.chooser.phase == .failed(.returnedAtOnce), "an empty answer at once counts as a failed window")

        // Never appears, never answers (AppKit after its 60 s wait): given up after the deadline, not waited on forever.
        let never = Harness(record: record) { _ in FakeFolderPanel(.neverShows) }
        let meter = MainThreadGapMeter()
        meter.start()
        never.chooser.choose(.exportFolder(startingAt: start)) { never.chosen = $0?.first }
        await never.settle(seconds: 2)
        let gap = meter.stop()
        require(never.chooser.phase == .failed(.noWindow), "a window that never appears is a failure after the deadline")
        require(never.panels.first?.cancels == 1, "the window that never came is cancelled, nothing left behind")
        require(!hasRecord(suite), "the record is cleared after a failure SkyCut lived through")
        require(gap < 0.5, "waiting for a window that never comes keeps the main thread free: longest gap \(gap) s")

        // Appears, then vanishes without an answer (service crash).
        let vanishing = Harness(record: record) { _ in FakeFolderPanel(.showsThenVanishes(after: 0.3)) }
        vanishing.chooser.choose(.exportFolder(startingAt: start)) { vanishing.chosen = $0?.first }
        await vanishing.settle(seconds: 2)
        require(vanishing.chooser.phase == .failed(.noWindow), "a window gone without an answer is a failure")

        // On screen and never answering (service hung): still choosing; "Close It" closes it and offers typing.
        let stuck = Harness(record: record) { _ in FakeFolderPanel(.staysStuck) }
        stuck.chooser.choose(.exportFolder(startingAt: start)) { stuck.chosen = $0?.first }
        await stuck.settle(seconds: 1.2)
        require(stuck.chooser.phase == .choosing, "a window on screen is not given up on by the clock")
        stuck.chooser.closeStuckWindow()
        require(stuck.chooser.phase == .failed(.closedByUser) && stuck.panels.first?.cancels == 1,
                "Close It cancels the stuck window and shows the typed path")
        require(stuck.chosen == nil && !hasRecord(suite), "closing it hands nothing over and clears the record")

        // The panel went away while choosing: no window left for nobody.
        let leaving = Harness(record: record) { _ in FakeFolderPanel(.staysStuck) }
        leaving.chooser.choose(.exportFolder(startingAt: start)) { leaving.chosen = $0?.first }
        leaving.chooser.cancelIfChoosing()
        require(leaving.chooser.phase == .idle && leaving.panels.first?.cancels == 1, "closing the export panel cancels the window")

        // A record from another process = that run ended with the window open: offer typing, don't ask AppKit again.
        var previous = record
        previous.processID = record.processID &+ 1
        previous.markStarted()
        let detour = Harness(record: record) { _ in FakeFolderPanel(.answers(picked, after: 0.1)) }
        detour.chooser.choose(.exportFolder(startingAt: start)) { detour.chosen = $0?.first }
        require(detour.chooser.phase == .failed(.lastRunDidNotFinish) && detour.panels.isEmpty,
                "after a run that ended with the window open, the typed path comes first and AppKit is not asked")
        require(!hasRecord(suite), "the old record is used once")
        detour.chooser.choose(.exportFolder(startingAt: start), force: true) { detour.chosen = $0?.first }
        await detour.settle(seconds: 0.6)
        require(detour.panels.count == 1 && detour.chosen == picked, "Try Again asks AppKit after all")
    }

    private static func hasRecord(_ suite: String) -> Bool {
        UserDefaults(suiteName: suite)?.dictionary(forKey: SystemFileWindowRecord.key) != nil
    }

    /// One chooser with short deadlines and a factory that keeps every fake window it made.
    @MainActor final class Harness {
        @MainActor final class Made { var panels: [FakeFolderPanel] = [] }

        let chooser: SystemFileChooser
        private let made: Made
        var panels: [FakeFolderPanel] { made.panels }
        var chosen: URL?

        init(record: SystemFileWindowRecord, make: @escaping (URL) -> FakeFolderPanel) {
            let made = Made()
            self.made = made
            chooser = SystemFileChooser(
                makePanel: { request in
                    let panel = make(request.start ?? URL(fileURLWithPath: "/"))
                    made.panels.append(panel)
                    return panel
                },
                record: record, note: { _ in }, appearDeadline: 0.6, quickReturn: 0.5
            )
        }

        func settle(seconds: TimeInterval) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }
}

/// A stand-in for the macOS window. `cancel()` answers nil synchronously, as AppKit's did in the probe.
@MainActor final class FakeFolderPanel: FileChooserPanel {
    enum Behaviour {
        case answers(URL?, after: TimeInterval)
        case neverShows
        case showsThenVanishes(after: TimeInterval)
        case staysStuck
    }

    private(set) var isVisible = false
    private(set) var cancels = 0
    let frame = NSRect(x: 100, y: 300, width: 600, height: 400)
    private var completion: (([URL]?) -> Void)?
    private let behaviour: Behaviour

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func begin(_ completion: @escaping ([URL]?) -> Void) {
        self.completion = completion
        switch behaviour {
        case .answers(let url, let after):
            isVisible = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                self.isVisible = false
                self.answer(url)
            }
        case .neverShows:
            isVisible = false
        case .showsThenVanishes(let after):
            isVisible = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                self.isVisible = false
            }
        case .staysStuck:
            isVisible = true
        }
    }

    func cancel() {
        cancels += 1
        isVisible = false
        answer(nil)
    }

    private func answer(_ url: URL?) {
        let pending = completion
        completion = nil
        pending?(url.map { [$0] })
    }
}

/// The longest time the main thread was unavailable while measuring: a plain thread posts a block to the main queue
/// every 20 ms and times how long each took to run. `stop()` never waits on the main thread (it may be the one stuck).
final class MainThreadGapMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var worst: TimeInterval = 0
    private var pendingSince: TimeInterval?
    private var running = true

    func start() {
        Thread.detachNewThread { [self] in
            while isRunning {
                let sent = ProcessInfo.processInfo.systemUptime
                let landed = DispatchSemaphore(value: 0)
                lock.withLock { pendingSince = sent }
                DispatchQueue.main.async { landed.signal() }
                landed.wait()
                let waited = ProcessInfo.processInfo.systemUptime - sent
                lock.withLock { pendingSince = nil; worst = max(worst, waited) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    func stop() -> TimeInterval {
        lock.withLock {
            running = false
            let now = ProcessInfo.processInfo.systemUptime
            return max(worst, pendingSince.map { now - $0 } ?? 0)
        }
    }

    private var isRunning: Bool { lock.withLock { running } }
}
