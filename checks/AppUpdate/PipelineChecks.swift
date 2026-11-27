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
        func fetch(_ feed: AppUpdateFeed, verify extra: @escaping (URL) throws -> Void = { _ in }) async -> AppUpdateFetchOutcome {
            await AppUpdatePipeline.run(feed, files: files, stager: FlowChecks.stager(files, running: running, verify: extra),
                                        appName: "SkyCut.app", asked: false) { _ in }
        }
        let good = feed()
        let kept = files.dmg(for: good)
        try files.makeFolders()
        let other = files.downloads.appendingPathComponent("SkyCut-1.0.5-abababababab.dmg")
        try Data("another release".utf8).write(to: other)
        check(await fetch(good) == .staged && files.readStaged()?.feed.isSameRelease(as: good) == true, "a release downloads, verifies and stages")
        check(UpdateFixture.sha256(kept) == sha, "its DMG is kept until the update is installed")
        check(!FileManager.default.fileExists(atPath: other.path), "a download of another DMG is removed")
        check(await fetch(good) == .staged, "the same release again: its staged copy is taken as it is")
        // A quit during staging: the DMG stayed, no staged copy. The server no longer has it: only the kept one can stage.
        files.removeStaged(except: nil)
        try FileManager.default.removeItem(at: server.folder.appendingPathComponent("pipeline/SkyCut-1.1.0.dmg"))
        check(await fetch(good) == .staged && files.readStaged() != nil,
              "a finished download kept from an earlier run is staged without downloading it again")
        // A kept download that no longer matches the feed: removed, downloaded again.
        try server.copy(dmg, to: "pipeline/SkyCut-1.1.0.dmg")
        files.removeStaged(except: nil)
        try Data("damaged".utf8).write(to: kept)
        check(await fetch(good) == .staged && UpdateFixture.sha256(kept) == sha, "a kept download that no longer matches is removed and downloaded again")
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
