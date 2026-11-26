import Foundation

// scripts/check-app-update.sh: the real transfers against the loopback server the script started (never the network):
// the feed (200, 404, a redirect, too big), the DMG (exact, a wrong SHA-256, a wrong size either way, a redirect, cancelled;
// which of them came down but aren't the feed's DMG, the retry record's count), then staging from real read-only images
// (the copy verified, the quarantine cleared, the image detached, only the newest staged copy kept, under staged.noindex;
// a wrong bundle id, a wrong version, two apps or a failed verification leave nothing), and images a killed run left
// attached. The pipeline, the verifier's steps and the launch cleanup: PipelineChecks, LaunchChecks.

enum FlowChecks {
    static func run(server: LoopbackServer, root: URL, check: @escaping (Bool, String) -> Void) async throws {
        print("==> the feed and the DMG over loopback")
        let running = AppUpdateVersion("1.0.0")!
        let apps = root.appendingPathComponent("apps")
        let old = try UpdateFixture.app(in: apps.appendingPathComponent("old"), version: "1.0.0", marker: "old")
        let new = try UpdateFixture.app(in: apps.appendingPathComponent("new"), version: "1.1.0", build: "2", marker: "new")
        let dmg = root.appendingPathComponent("SkyCut-1.1.0.dmg")
        try UpdateFixture.image(of: new, at: dmg)
        try server.copy(dmg, to: "SkyCut-1.1.0.dmg")
        let size = UpdateFixture.size(dmg), sha = UpdateFixture.sha256(dmg)
        try await feeds(server, size: size, sha: sha, check: check)
        try await downloads(server, root: root, size: size, sha: sha, check: check)
        print("==> staging from real images")
        try staging(root: root, old: old, new: new, dmg: dmg, running: running, check: check)
        try leftovers(root: root, dmg: dmg, check: check)
        try await PipelineChecks.run(server: server, root: root.appendingPathComponent("pipeline"), dmg: dmg, old: old, check: check)
    }

    private static func feed(_ server: LoopbackServer, _ path: String, size: Int64, sha: String, version: String = "1.1.0") -> Data {
        UpdateFixture.feedJSON(version: version, build: "2", url: server.url("SkyCut-1.1.0.dmg").absoluteString, size: size, sha: sha)
    }

    private static func feeds(_ server: LoopbackServer, size: Int64, sha: String, check: (Bool, String) -> Void) async throws {
        try server.put(feed(server, "feed.json", size: size, sha: sha), at: "feed.json")
        let source = server.source("feed.json")
        check(source.isLoopback, "the loopback server is a loopback test hook")
        let result = await AppUpdateHTTP.check(source, running: AppUpdateVersion("1.0.0")!)
        if case .offer(let offered) = result {
            check(offered.version.description == "1.1.0" && offered.dmgSize == size, "the feed over loopback offers 1.1.0")
        } else {
            check(false, "the feed over loopback offers 1.1.0 (got \(result))")
        }
        check(await AppUpdateHTTP.check(source, running: AppUpdateVersion("1.1.0")!) == .upToDate, "the same version: up to date")
        check(await AppUpdateHTTP.check(server.source("missing.json"), running: AppUpdateVersion("1.0.0")!) == .failed, "404: failed, silently")
        try FileManager.default.createDirectory(at: server.folder.appendingPathComponent("moved"), withIntermediateDirectories: true)
        check(await AppUpdateHTTP.fetchFeed(server.url("moved")) == nil, "a redirect (301) is not followed")
        try server.put(Data(repeating: 32, count: AppUpdateFeed.maxFeedBytes + 1), at: "huge.json")
        check(await AppUpdateHTTP.fetchFeed(server.url("huge.json")) == nil, "a feed over 64 KB is refused")
        try server.put(Data("{\"schema\": 1".utf8), at: "broken.json")
        check(await AppUpdateHTTP.check(server.source("broken.json"), running: AppUpdateVersion("1.0.0")!) == .failed, "malformed: failed, silently")
    }

    private static func downloads(_ server: LoopbackServer, root: URL, size: Int64, sha: String, check: (Bool, String) -> Void) async throws {
        let source = server.source("feed.json")
        let files = AppUpdateFiles(root: root.appendingPathComponent("http/Updates"))
        try files.makeFolders()
        func parsed(size: Int64, sha: String, path: String = "SkyCut-1.1.0.dmg") -> AppUpdateFeed {
            AppUpdateFeed.parse(UpdateFixture.feedJSON(version: "1.1.0", build: "2", url: server.url(path).absoluteString, size: size, sha: sha),
                                from: source)!
        }
        let progress = ProgressBox()
        let good = parsed(size: size, sha: sha)
        do {
            try await AppUpdateHTTP.download(good, into: files) { progress.add($0) }
            check(UpdateFixture.sha256(files.dmg(for: good)) == sha, "the DMG downloads whole, to its place in downloads/")
            check(progress.last == 1, "progress reaches 100% (last \(progress.last))")
        } catch {
            check(false, "the DMG downloads whole: \(error)")
        }
        files.removeDownloads()
        let wrongSHA = String(repeating: "0", count: 64)
        // Came down but isn't the feed's DMG (counted by the retry record), or didn't come down at all (not counted).
        await refuses("a wrong SHA-256", parsed(size: size, sha: wrongSHA), files, mismatch: true, check)
        await refuses("a feed that says bigger", parsed(size: size + 1, sha: sha), files, mismatch: true, check)
        await refuses("a feed that says smaller (more bytes than it says)", parsed(size: size - 1, sha: sha), files, mismatch: true, check)
        await refuses("a missing DMG (404)", parsed(size: size, sha: sha, path: "nothing.dmg"), files, mismatch: false, check)
        try FileManager.default.createDirectory(at: server.folder.appendingPathComponent("folder.dmg"), withIntermediateDirectories: true)
        await refuses("a redirect", parsed(size: size, sha: sha, path: "folder.dmg"), files, mismatch: false, check)
        let cancelled = Task { try await AppUpdateHTTP.download(good, into: files) { _ in } }
        cancelled.cancel()
        let outcome = await cancelled.result
        if case .failure(let error) = outcome {
            check(!(error is AppUpdateDMGMismatch) && UpdateFixture.contents(of: files.downloads).isEmpty,
                  "a cancelled download leaves no file and isn't a mismatch")
        } else {
            check(false, "a cancelled download is refused")
        }
    }

    private static func refuses(_ label: String, _ feed: AppUpdateFeed, _ files: AppUpdateFiles, mismatch: Bool, _ check: (Bool, String) -> Void) async {
        do {
            try await AppUpdateHTTP.download(feed, into: files) { _ in }
            check(false, "\(label): refused")
        } catch {
            check(UpdateFixture.contents(of: files.downloads).isEmpty, "\(label): refused, no file left (\(error.localizedDescription))")
            check((error is AppUpdateDMGMismatch) == mismatch,
                  "\(label): \(mismatch ? "the DMG isn't the feed's (counted)" : "it didn't come down (not counted)") (got \(type(of: error)))")
        }
    }

    static func stager(_ files: AppUpdateFiles, running: AppUpdateVersion, verify extra: @escaping (URL) throws -> Void = { _ in }) -> AppUpdateStager {
        AppUpdateStager(files: files, bundleIdentifier: UpdateFixture.identifier) { copy, feed in
            try AppUpdateVerifier.checkInfo(of: copy, feed: feed, bundleIdentifier: UpdateFixture.identifier, running: running)
            try AppBundleSignature.verify(copy, satisfies: UpdateFixture.identifierRequirement(), network: false)
            try extra(copy)
        }
    }

    private static func staging(root: URL, old: URL, new: URL, dmg: URL, running: AppUpdateVersion, check: (Bool, String) -> Void) throws {
        let files = AppUpdateFiles(root: root.appendingPathComponent("stage/Updates"))
        let feed = FeedChecks.feed(UpdateFixture.feedJSON(version: "1.1.0", build: "2", url: FeedChecks.url,
                                                          size: UpdateFixture.size(dmg), sha: UpdateFixture.sha256(dmg)))!
        try files.makeFolders()
        try FileManager.default.createDirectory(at: files.stagingFolder(for: AppUpdateVersion("1.0.5")!), withIntermediateDirectories: true)
        Tools.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0281;00000000;Safari;", dmg.path])
        let record = try stager(files, running: running).stage(dmg, feed: feed, appName: "SkyCut.app", asked: false)
        let staged = URL(fileURLWithPath: record.appPath)
        check(UpdateFixture.marker(of: staged) == "new" && UpdateFixture.codesignVerifies(staged), "the staged copy is the new app, intact")
        check(record.appPath == files.root.appendingPathComponent("staged.noindex/1.1.0/SkyCut.app").path && files.stagedCopy(of: record) != nil,
              "the staged copy lies under a .noindex folder (Spotlight never lists it) where the installer takes it (\(record.appPath))")
        check(Quarantine.isFlagged(atPath: staged.path) == false, "no quarantine on the staged copy")
        check(files.readStaged() == record, "the staged record is written")
        check(UpdateFixture.contents(of: files.staging) == ["1.1.0"], "only the newest staged copy is kept (got \(UpdateFixture.contents(of: files.staging)))")
        check(UpdateFixture.contents(of: files.root).filter { $0.hasPrefix("mount-") }.isEmpty, "the image is detached, its mount point gone")
        check(!Tools.run("/usr/bin/hdiutil", ["info"]).output.contains(dmg.lastPathComponent), "nothing of the image stays attached")
        // Refusals: each leaves no staged copy of its own and the earlier record alone.
        let refusals: [(String, AppUpdateFeed, AppUpdateStager)] = [
            ("a version the feed doesn't name", FeedChecks.feed(UpdateFixture.feedJSON(version: "1.2.0", build: "2", url: FeedChecks.url,
                size: 1, sha: FeedChecks.sha))!, stager(files, running: running)),
            ("a build the feed doesn't name", FeedChecks.feed(UpdateFixture.feedJSON(version: "1.1.0", build: "9", url: FeedChecks.url,
                size: 1, sha: FeedChecks.sha))!, stager(files, running: running)),
            ("a version not newer than the running one", feed, stager(files, running: AppUpdateVersion("1.1.0")!)),
            ("a failed signature check", feed, stager(files, running: running) { _ in throw AppUpdateError("signature") }),
            ("another app's bundle id", feed, AppUpdateStager(files: files, bundleIdentifier: "com.srtflow.SrtFlow.other") { _, _ in }),
        ]
        for (label, wrongFeed, wrongStager) in refusals {
            let refused = (try? wrongStager.stage(dmg, feed: wrongFeed, appName: "SkyCut.app", asked: false)) == nil
            check(refused, "\(label): refused")
            check(files.readStaged() == record && UpdateFixture.marker(of: staged) == "new", "\(label): the earlier staged copy stays")
            check(UpdateFixture.contents(of: files.root).filter { $0.hasPrefix("mount-") }.isEmpty, "\(label): the image is detached")
        }
        let two = root.appendingPathComponent("two.dmg")
        try UpdateFixture.image(of: new, at: two, extraApp: new)
        check((try? stager(files, running: running).stage(two, feed: feed, appName: "SkyCut.app", asked: false)) == nil,
              "an image with two such apps is refused")
        // The production verifier refuses an ad-hoc build: no notarization, another code hash (the running fixture's).
        check((try? AppUpdateVerifier.verify(staged, feed: feed, runningApp: old, running: running, atQuit: true)) == nil,
              "the production check refuses an ad-hoc copy (not notarized)")
        check((try? AppBundleSignature.verify(staged, matchesNotarized: staged, network: false)) == nil,
              "the notarized requirement refuses even an identical ad-hoc copy")
        check((try? AppBundleSignature.verify(staged, matches: old)) == nil, "another build doesn't pass as the running app")
        if Tools.run("/usr/sbin/spctl", ["--status"]).output.contains("assessments enabled") {
            check((try? AppUpdateVerifier.gatekeeper(staged)) == nil, "Gatekeeper rejects an ad-hoc copy")
        } else {
            print("note: Gatekeeper assessments are off on this Mac; its verdict on an ad-hoc copy is not checked here")
        }
        check(AppUpdateVerifier.gatekeeperAccepts(status: 0, output: "/A.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: X (26TVX3S9FR)\n"),
              "Gatekeeper: accepted as Notarized Developer ID")
        check(!AppUpdateVerifier.gatekeeperAccepts(status: 0, output: "/A.app: accepted\nsource=Apple Development\n"), "Gatekeeper: another source is refused")
        check(!AppUpdateVerifier.gatekeeperAccepts(status: 3, output: "/A.app: rejected\nsource=Notarized Developer ID\n"), "Gatekeeper: rejected")
        check(AppUpdateVerifier.gatekeeperAccepts(status: 0, output: "/A.app: accepted\noverride=security disabled\n"),
              "Gatekeeper off on the Mac: its accepted verdict is taken (the notarized requirement still applies)")
    }

    private static func leftovers(root: URL, dmg: URL, check: (Bool, String) -> Void) throws {
        let files = AppUpdateFiles(root: root.appendingPathComponent("leftover/Updates"))
        try files.makeFolders()
        let mount = files.root.appendingPathComponent("mount-killed")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let attached = Tools.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mount.path, dmg.path])
        check(attached.status == 0 && Tools.isMounted(mount), "a killed run's image is attached under Updates/")
        AppUpdateStager.detachLeftovers(in: files)
        check(!Tools.isMounted(mount) && !FileManager.default.fileExists(atPath: mount.path), "the next launch detaches it and removes its mount point")
        // A `mount-…` link to a volume mounted elsewhere: never followed, what it points to never detached; the link goes.
        let elsewhere = root.appendingPathComponent("leftover/elsewhere-mount")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let mountedElsewhere = Tools.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint",
                                                              elsewhere.path, dmg.path])
        defer { Tools.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", elsewhere.path]) }
        let link = files.root.appendingPathComponent("mount-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        check(mountedElsewhere.status == 0 && Tools.isMounted(elsewhere), "a volume is mounted outside Updates/, a mount-… link to it inside")
        AppUpdateStager.detachLeftovers(in: files)
        check(Tools.isMounted(elsewhere) && !AppUpdateFiles.isLink(link), "a mount-… link: the volume it points to stays mounted, the link itself goes")
    }
}

/// Progress callbacks arrive on the download's own queue.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double { lock.withLock { values.last ?? -1 } }
}
