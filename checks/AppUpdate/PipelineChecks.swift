import Foundation

// scripts/check-app-update.sh: the work behind a download (AppUpdatePipeline) against the loopback server and real images:
// a release staged and its DMG kept until installed; the same release taken from its staged copy; a finished download kept
// from an earlier run (a quit during staging) used without asking the server again; a kept download that no longer matches
// removed and downloaded again; other DMGs removed; a wrong SHA-256 and a failing staging rejected (counted by the retry
// record, the DMG removed); a missing DMG not downloaded (not counted). Then the verifier's steps on their own: a copy that
// fails only at Gatekeeper, and the running app unreadable told apart from a bad copy. Every address is the loopback
// server's (checks/app-update-wiring.sh).

enum PipelineChecks {
    static func run(server: LoopbackServer, root: URL, dmg: URL, old: URL, check: @escaping (Bool, String) -> Void) async throws {
        print("==> the pipeline: kept downloads, staged copies, what counts")
        let running = AppUpdateVersion("1.0.0")!
        let size = UpdateFixture.size(dmg), sha = UpdateFixture.sha256(dmg)
        try FileManager.default.createDirectory(at: server.folder.appendingPathComponent("pipeline"), withIntermediateDirectories: true)
        try server.copy(dmg, to: "pipeline/SkyCut-1.1.0.dmg")
        let source = server.source("feed.json")
        func feed(_ path: String = "pipeline/SkyCut-1.1.0.dmg", sha: String = sha) -> AppUpdateFeed {
            AppUpdateFeed.parse(UpdateFixture.feedJSON(version: "1.1.0", build: "2", url: server.url(path).absoluteString, size: size, sha: sha),
                                from: source)!
        }
        let files = AppUpdateFiles(root: root.appendingPathComponent("Updates"))
        let good = feed()
        let kept = files.dmg(for: good)
        // What the check window would show, read at every report and when the staging's verification runs.
        let reported = ProgressLog()
        func fetch(_ feed: AppUpdateFeed, verify extra: @escaping (URL) throws -> Void = { _ in }) async -> AppUpdateFetchOutcome {
            reported.clear()
            let stager = FlowChecks.stager(files, running: running) { copy in
                reported.verifying()
                try extra(copy)
            }
            return await AppUpdatePipeline.run(feed, files: files, stager: stager, appName: "SkyCut.app", asked: false) { value in
                reported.add(value, keptThere: FileManager.default.fileExists(atPath: kept.path))
            }
        }
        try files.makeFolders()
        let other = files.downloads.appendingPathComponent("SkyCut-1.0.5-abababababab.dmg")
        try Data("another release".utf8).write(to: other)
        check(await fetch(good) == .staged && files.readStaged()?.feed.isSameRelease(as: good) == true, "a release downloads, verifies and stages")
        check(reported.values.last == 1 && reported.atVerification == 1,
              "its progress is at 1 when the copy is verified: the window says «Verifying…» (got \(reported.values))")
        check(UpdateFixture.sha256(kept) == sha, "its DMG is kept until the update is installed")
        check(!FileManager.default.fileExists(atPath: other.path), "a download of another DMG is removed")
        check(await fetch(good) == .staged, "the same release again: its staged copy is taken as it is")
        // A quit during staging: the DMG stayed, no staged copy. The server no longer has it: only the kept one can stage.
        files.removeStaged(except: nil)
        try FileManager.default.removeItem(at: server.folder.appendingPathComponent("pipeline/SkyCut-1.1.0.dmg"))
        check(await fetch(good) == .staged && files.readStaged() != nil,
              "a finished download kept from an earlier run is staged without downloading it again")
        // Reviews CXU1 §4, CXU2: with no bytes to report, the check window said «Downloading 0%» through the kept file's
        // SHA-256 and the staging. It reports 1 as the check begins (the file still there), long before the verification.
        check(reported.values == [1] && reported.first?.keptThere == true && reported.atVerification == 1,
              "…«Verifying…» from the start of its check through the staging, never a download's percent (got \(reported.entries))")
        // A kept download that no longer matches the feed: removed, downloaded again. As long as the feed's size, so its whole
        // SHA-256 is computed first: «Verifying…» while the old bytes are still there, then the transfer's own percent.
        try server.copy(dmg, to: "pipeline/SkyCut-1.1.0.dmg")
        files.removeStaged(except: nil)
        try Data(count: Int(size)).write(to: kept)
        check(await fetch(good) == .staged && UpdateFixture.sha256(kept) == sha, "a kept download that no longer matches is removed and downloaded again")
        check(reported.first?.value == 1 && reported.first?.keptThere == true && reported.values.last == 1 && reported.atVerification == 1,
              "…«Verifying…» while its old bytes are checked, then the new download up to 1 (got \(reported.entries))")
        // Came down whole and failed: rejected (counted), nothing kept. Didn't come down: not counted.
        files.removeStaged(except: nil)
        files.removeDownloads()
        check(await fetch(feed(sha: String(repeating: "0", count: 64))) == .rejected
              && UpdateFixture.contents(of: files.downloads).isEmpty && files.readStaged() == nil,
              "a DMG whose SHA-256 isn't the feed's is rejected (counted), nothing kept")
        check(await fetch(good, verify: { _ in throw AppUpdateError("verification") }) == .rejected
              && UpdateFixture.contents(of: files.downloads).isEmpty && files.readStaged() == nil,
              "a DMG that fails its staging is rejected (counted) and removed")
        check(await fetch(feed("pipeline/missing.dmg")) == .notDownloaded && files.readStaged() == nil,
              "a DMG the server doesn't have didn't download (not counted)")
        try verifierSteps(root: root, old: old, running: running, check: check)
    }

    /// What a run reported, in order (the callbacks may come from any thread): each progress value with whether the kept
    /// DMG was on disk then, and the moment the staging's verification ran.
    final class ProgressLog: @unchecked Sendable {
        struct Entry: Equatable, CustomStringConvertible {
            let value: Double?
            let keptThere: Bool
            var description: String { value.map { "\($0)\(keptThere ? " (file there)" : "")" } ?? "verification" }
        }
        private let lock = NSLock()
        private var stored: [Entry] = []
        var entries: [Entry] { lock.withLock { stored } }
        var values: [Double] { entries.compactMap(\.value) }
        var first: Entry? { entries.first { $0.value != nil } }
        /// The progress when the copy's verification began: what the window showed then (nil: nothing reported before).
        var atVerification: Double? {
            let all = entries
            guard let mark = all.firstIndex(where: { $0.value == nil }) else { return nil }
            return all[..<mark].last { $0.value != nil }?.value
        }
        func add(_ value: Double, keptThere: Bool) { lock.withLock { stored.append(Entry(value: value, keptThere: keptThere)) } }
        func verifying() { lock.withLock { stored.append(Entry(value: nil, keptThere: false)) } }
        func clear() { lock.withLock { stored.removeAll() } }
    }

    /// The verifier's steps (AppUpdateVerifier.Steps), each on its own: Gatekeeper alone refuses a copy when staging and is
    /// never asked at quit; a running app that can't be read is the running app's error, never the copy's.
    private static func verifierSteps(root: URL, old: URL, running: AppUpdateVersion, check: (Bool, String) -> Void) throws {
        let copy = try UpdateFixture.app(in: root.appendingPathComponent("verify"), version: "1.1.0", build: "2", marker: "new")
        let feed = InstallChecks.feed
        let asked = Counter()
        var steps = AppUpdateVerifier.Steps()
        steps.requirement = { _ in UpdateFixture.identifierRequirement() }
        let rejected = AppUpdateTool.Result(status: 3, output: "\(copy.path): rejected\nsource=no usable signature\n")
        let accepted = AppUpdateTool.Result(status: 0, output: "\(copy.path): accepted\nsource=Notarized Developer ID\n")
        steps.gatekeeper = { _ in asked.add(); return rejected }
        do {
            try AppUpdateVerifier.verify(copy, feed: feed, runningApp: old, running: running, atQuit: false, steps: steps)
            check(false, "a copy Gatekeeper rejects is refused when staging")
        } catch {
            check("\(error)".hasPrefix("Gatekeeper") && asked.count == 1,
                  "a copy that passes every other step is refused when staging by Gatekeeper alone (\(error))")
        }
        check((try? AppUpdateVerifier.verify(copy, feed: feed, runningApp: old, running: running, atQuit: true, steps: steps)) != nil
              && asked.count == 1, "at quit Gatekeeper isn't asked (the check runs offline)")
        steps.gatekeeper = { _ in accepted }
        check((try? AppUpdateVerifier.verify(copy, feed: feed, runningApp: old, running: running, atQuit: false, steps: steps)) != nil,
              "the same copy passes once Gatekeeper accepts it as notarized")
        let gone = root.appendingPathComponent("verify/Moved.app")
        do {
            try AppUpdateVerifier.verify(copy, feed: feed, runningApp: gone, running: running, atQuit: true, steps: steps)
            check(false, "the running app moved away: refused")
        } catch {
            check(error is AppUpdateRunningAppError, "the running app moved away is the running app's error, not the copy's")
        }
        var unreadable = steps
        unreadable.requirement = { _ in throw AppUpdateError("no signature") }
        do {
            try AppUpdateVerifier.verify(copy, feed: feed, runningApp: old, running: running, atQuit: true, steps: unreadable)
            check(false, "the running app's requirement unreadable: refused")
        } catch {
            check(error is AppUpdateRunningAppError, "the running app's requirement unreadable is the running app's error")
        }
        try Data("changed".utf8).write(to: copy.appendingPathComponent("Contents/Resources/marker.txt"))
        do {
            try AppUpdateVerifier.verify(copy, feed: feed, runningApp: old, running: running, atQuit: true, steps: steps)
            check(false, "a changed copy is refused")
        } catch {
            check(!(error is AppUpdateRunningAppError), "a changed copy is the copy's error (it is removed)")
        }
    }
}

/// Counts calls from closures (the steps the verifier is given).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
