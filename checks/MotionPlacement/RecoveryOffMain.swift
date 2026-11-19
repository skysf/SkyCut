import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Recovery asks the drive which movies are there off the main thread (docs/bugfixes/2026-11-19-drive-checks-on-main-thread.md):
// with a drive that takes 1.2 s for each of its first answers (asleep, slow, on a network), the real entry every preview
// rebuild and app activation calls (`revalidateMediaLocations`) leaves the main thread free, no question is asked on it, and the
// deleted movie still comes back as a document repair without an undo step. checks/file-io-off-main-wiring.sh pins the wiring.
@MainActor func runMotionRecoveryOffMainChecks(_ fixture: MotionFixture) async throws {
    let project = fixture.project
    guard let clip = project.state.allClips.first(where: { $0.webMotion != nil }) else {
        throw AIToolError("The off-main recovery checks need a placed web-motion clip")
    }
    try FileManager.default.removeItem(at: clip.sourceURL)
    fixture.resetUndo()
    let drive = SlowDrive(slowAnswers: 3, delay: 1.2)
    WebMotionRecovery.existsForChecks = { drive.exists($0) }
    defer { WebMotionRecovery.existsForChecks = nil }

    let meter = RecoveryGapMeter()
    meter.start()
    project.revalidateMediaLocations()
    try await Task.sleep(for: .seconds(2.5))
    let gap = meter.stop()
    motionRequire(drive.asked > 0, "recovery asks the drive which movies are there (asked \(drive.asked))")
    motionRequire(!drive.askedOnMain, "no question about the drive is asked on the main thread")
    motionRequire(gap < 0.5, "the main thread is free while a slow drive answers recovery: longest gap \(gap) s")

    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline, !(FileManager.default.fileExists(atPath: clip.sourceURL.path) && recoveryFinished(project)) {
        try await Task.sleep(for: .milliseconds(100))
    }
    motionRequire(FileManager.default.fileExists(atPath: clip.sourceURL.path) && recoveryFinished(project),
                  "the deleted movie comes back after the slow drive answered")
    motionRequire(project.state.clip(with: clip.id)?.webMotion?.provenance == clip.webMotion?.provenance
                    && !project.ownUndoManager.canUndo,
                  "the slow-drive recovery is a document repair of the same pixels, not an undo step")
}

/// A drive whose first answers each take `delay`; it notes whether any question came on the main thread.
private final class SlowDrive: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var onMain = false
    private let slowAnswers: Int
    private let delay: TimeInterval

    init(slowAnswers: Int, delay: TimeInterval) {
        self.slowAnswers = slowAnswers
        self.delay = delay
    }

    var asked: Int { lock.withLock { count } }
    var askedOnMain: Bool { lock.withLock { onMain } }

    func exists(_ url: URL) -> Bool {
        let slow = lock.withLock { () -> Bool in
            count += 1
            onMain = onMain || Thread.isMainThread
            return count <= slowAnswers
        }
        if slow { Thread.sleep(forTimeInterval: delay) }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// The longest the main thread took to run a block posted to it while this ran (the export checks' MainThreadGapMeter).
private final class RecoveryGapMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var worst: TimeInterval = 0
    private var pendingSince: TimeInterval?
    private var running = true

    func start() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
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
            return max(worst, pendingSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
        }
    }
}
