import Foundation

// scripts/check-app-update.sh: what a launch takes from the Updates folder (AppUpdateLaunchFiles) against scratch folders:
// only a copy that installs reads or cleans it (one that only tells, SkyCut Beta, or a copy running from inside the folder
// leaves everything as it is); the marker read once; the cleanup after an update (only the app a swap replaced, older than
// the running one and its folder's version, goes to the Trash; a staged copy never installed is deleted, never trashed;
// the newest recorded copy and a finished download of a newer release stay; the bundle this process runs from and the
// folder around it are never touched; a link is removed, never followed). Then the shell that opens SkyCut again after
// Restart and Update (AppUpdateRelaunch): it waits for the old process, opens the path only while it holds an app, and
// passes the path alone.

/// A scratch Updates folder with its own Trash (moved items are remembered by their marker).
final class LaunchScene {
    let root: URL
    let files: AppUpdateFiles
    let trashFolder: URL
    private(set) var trashed: [String] = []
    var runningBundle: URL { root.appendingPathComponent("Applications/SkyCut.app") }

    init(_ parent: URL, _ name: String) throws {
        root = parent.appendingPathComponent(name)
        files = AppUpdateFiles(root: root.appendingPathComponent("Updates"))
        trashFolder = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        try files.makeFolders()
    }

    func trash(_ item: URL) throws {
        trashed.append(UpdateFixture.marker(of: item) ?? item.lastPathComponent)
        try FileManager.default.moveItem(at: item, to: trashFolder.appendingPathComponent("\(trashed.count)-\(item.lastPathComponent)"))
    }

    @discardableResult
    func app(_ version: String, inFolder folder: String, marker: String) throws -> URL {
        try UpdateFixture.app(in: files.staging.appendingPathComponent(folder), version: version, marker: marker)
    }

    /// Every path under the scene, to tell that nothing changed.
    func listing() -> [String] {
        ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).sorted()
    }

    /// What an update from 1.0.0 to 1.1.0 left: the marker, the replaced app (its trash failed), a newer staged copy with its
    /// record and kept DMG, and a retry record.
    func populateAfterUpdate() throws {
        try files.writeInstalledNote(AppUpdateInstalledNote(from: AppUpdateVersion("1.0.0")!, to: AppUpdateVersion("1.1.0")!,
                                                            notes: ["en": ["New"]]))
        try app("1.0.0", inFolder: "1.1.0", marker: "replaced")
        let staged = try app("1.2.0", inFolder: "1.2.0", marker: "staged")
        try files.writeStaged(AppUpdateStagedRecord(feed: FeedChecks.feed(FeedChecks.valid(version: "1.2.0"))!, appPath: staged.path, asked: false))
        try Data("dmg".utf8).write(to: files.downloads.appendingPathComponent("SkyCut-1.2.0-abababababab.dmg"))
        files.writeRetry(AppUpdateRetryRecord(dmgSHA256: FeedChecks.sha, failures: 2, lastFailure: StateChecks.t0))
    }
}

enum LaunchChecks {
    static func run(root: URL, check: (Bool, String) -> Void) throws {
        print("==> the launch: what it reads and cleans; the relaunch shell")
        try gating(root, check)
        try cleanup(root, check)
        try runningBundle(root, check)
        try relaunch(root, check)
    }

    /// Only a copy that installs touches the Updates folder (E3).
    private static func gating(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let running = AppUpdateVersion("1.1.0")!
        let others: [(String, AppUpdateEligibility.Decision)] = [
            ("a copy that only tells", .notifyOnly(.installerDisk)), ("SkyCut Beta", .never(.otherBundle)),
            ("a copy running from inside the Updates folder", .never(.updatesFolder)),
        ]
        for (label, decision) in others {
            let scene = try LaunchScene(root, label)
            try scene.populateAfterUpdate()
            let before = scene.listing()
            let found = AppUpdateLaunchFiles.take(from: scene.files, decision: decision, running: running, runningBundle: scene.runningBundle,
                                                  trash: scene.trash)
            check(found == AppUpdateLaunchFiles() && scene.listing() == before && scene.trashed.isEmpty,
                  "\(label) reads and cleans nothing in the Updates folder")
        }
        let scene = try LaunchScene(root, "a copy that installs")
        try scene.populateAfterUpdate()
        let found = AppUpdateLaunchFiles.take(from: scene.files, decision: .updates, running: running, runningBundle: scene.runningBundle,
                                              trash: scene.trash)
        check(found.installed?.to == running && scene.files.readInstalledNote() == nil, "a copy that installs reads the marker once")
        check(found.staged?.feed.version.description == "1.2.0" && found.retry?.failures == 2, "…and the staged and retry records")
        check(scene.trashed == ["replaced"], "…and cleans up after the update (got \(scene.trashed))")
    }

    /// The cleanup after an update (E3, U3), links included.
    private static func cleanup(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try LaunchScene(root, "cleanup")
        let files = scene.files
        let running = AppUpdateVersion("1.1.0")!
        try scene.app("1.0.0", inFolder: "1.1.0", marker: "replaced")
        try scene.app("1.0.5", inFolder: "1.0.5", marker: "older staged")
        let kept = try scene.app("1.2.0", inFolder: "1.2.0", marker: "kept")
        try scene.app("1.3.0", inFolder: "1.3.0", marker: "unrecorded")
        try FileManager.default.createDirectory(at: files.staging.appendingPathComponent("incoming-1234"), withIntermediateDirectories: true)
        let outside = scene.root.appendingPathComponent("Outside")
        let pointedTo = try UpdateFixture.app(in: outside, version: "1.0.0", marker: "outside")
        try FileManager.default.createSymbolicLink(at: files.staging.appendingPathComponent("1.4.0"), withDestinationURL: outside)
        try files.writeStaged(AppUpdateStagedRecord(feed: FeedChecks.feed(FeedChecks.valid(version: "1.2.0"))!, appPath: kept.path, asked: false))
        for name in ["SkyCut-1.2.0-abababababab.dmg", "SkyCut-1.1.0-abababababab.dmg", "SkyCut-1.3.0-nothex000000.dmg", "partial.tmp"] {
            try Data(name.utf8).write(to: files.downloads.appendingPathComponent(name))
        }
        AppUpdateLaunchFiles.clean(files, running: running, runningBundle: scene.runningBundle, trash: scene.trash)
        check(scene.trashed == ["replaced"], "only the app a swap replaced goes to the Trash (got \(scene.trashed))")
        check(UpdateFixture.contents(of: files.staging) == ["1.2.0"] && UpdateFixture.marker(of: kept) == "kept",
              "the staged copy the record names stays; older, unrecorded and unfinished copies are deleted (got \(UpdateFixture.contents(of: files.staging)))")
        check(files.readStaged()?.feed.version.description == "1.2.0", "its record stays")
        check(UpdateFixture.marker(of: pointedTo) == "outside", "a link in the staging folder is removed, never followed")
        check(UpdateFixture.contents(of: files.downloads) == ["SkyCut-1.2.0-abababababab.dmg"],
              "a finished download of a newer release stays; the rest goes (got \(UpdateFixture.contents(of: files.downloads)))")
        try FileManager.default.removeItem(at: kept)
        AppUpdateLaunchFiles.clean(files, running: running, runningBundle: scene.runningBundle, trash: scene.trash)
        check(files.readStaged() == nil && UpdateFixture.contents(of: files.staging).isEmpty, "a record whose copy is gone is removed")

        // staged.noindex itself a link to a folder elsewhere: removing staged copies deletes nothing there (E1).
        let linked = try LaunchScene(root, "linked-staging")
        let away = linked.root.appendingPathComponent("Away")
        let awayApp = try UpdateFixture.app(in: away.appendingPathComponent("1.2.0"), version: "1.2.0", marker: "away")
        try FileManager.default.removeItem(at: linked.files.staging)
        try FileManager.default.createSymbolicLink(at: linked.files.staging, withDestinationURL: away)
        linked.files.removeStaged(except: nil)
        linked.files.removeDownloads()
        check(UpdateFixture.marker(of: awayApp) == "away", "with staged.noindex a link elsewhere, removing staged copies deletes nothing there")
        AppUpdateLaunchFiles.clean(linked.files, running: running, runningBundle: linked.runningBundle, trash: linked.trash)
        check(UpdateFixture.marker(of: awayApp) == "away" && linked.trashed.isEmpty && !AppUpdateFiles.isLink(linked.files.staging),
              "…and the launch cleanup removes the link itself, nothing it points to")
        // remove() itself: a path through a version folder that is a link leading outside is never deleted.
        let elsewhere = linked.root.appendingPathComponent("Elsewhere")
        let elsewhereApp = try UpdateFixture.app(in: elsewhere, version: "1.4.0", marker: "elsewhere")
        try linked.files.makeFolders()
        let versionLink = linked.files.stagingFolder(for: AppUpdateVersion("1.4.0")!)
        try FileManager.default.createSymbolicLink(at: versionLink, withDestinationURL: elsewhere)
        linked.files.remove(versionLink.appendingPathComponent("SkyCut.app"))
        check(UpdateFixture.marker(of: elsewhereApp) == "elsewhere", "remove() never deletes through a link that leads outside the Updates folder")
        linked.files.remove(versionLink)
        check(!AppUpdateFiles.isLink(versionLink) && UpdateFixture.marker(of: elsewhereApp) == "elsewhere",
              "…while the link itself, inside the folder, is removed")

        // An app as old as the running one (1.0.0 put back by hand after an update), even in a newer version's folder: our
        // leftover, deleted, never sent to the Trash; only an app older than both goes there.
        let putBack = try LaunchScene(root, "put-back")
        let asOld = try putBack.app("1.0.0", inFolder: "1.1.0", marker: "as old as the running one")
        AppUpdateLaunchFiles.clean(putBack.files, running: AppUpdateVersion("1.0.0")!, runningBundle: putBack.runningBundle, trash: putBack.trash)
        check(putBack.trashed.isEmpty && !FileManager.default.fileExists(atPath: asOld.path),
              "an app as old as the running one is deleted, never sent to the Trash (only one older than both goes there)")

        let byHand = try LaunchScene(root, "installed-by-hand")
        let never = try byHand.app("1.1.0", inFolder: "1.1.0", marker: "never installed")
        try byHand.files.writeStaged(AppUpdateStagedRecord(feed: FeedChecks.feed(FeedChecks.valid(version: "1.1.0"))!, appPath: never.path, asked: false))
        AppUpdateLaunchFiles.clean(byHand.files, running: running, runningBundle: byHand.runningBundle, trash: byHand.trash)
        check(byHand.trashed.isEmpty && UpdateFixture.contents(of: byHand.files.staging).isEmpty && byHand.files.readStaged() == nil,
              "a staged copy of the version now running (installed by hand) is deleted, never sent to the Trash")
    }

    /// The bundle this process runs from is never trashed or removed, nor the folder around it (E8).
    private static func runningBundle(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let looksReplaced = try LaunchScene(root, "runs-from-staged")
        let own = try looksReplaced.app("1.1.0", inFolder: "1.2.0", marker: "running")
        AppUpdateLaunchFiles.clean(looksReplaced.files, running: AppUpdateVersion("1.2.0")!, runningBundle: own, trash: looksReplaced.trash)
        check(looksReplaced.trashed.isEmpty && UpdateFixture.marker(of: own) == "running", "the bundle this process runs from is never trashed")
        let unfinished = try LaunchScene(root, "runs-from-incoming")
        let inside = try unfinished.app("1.2.0", inFolder: "incoming-5678", marker: "running")
        AppUpdateLaunchFiles.clean(unfinished.files, running: AppUpdateVersion("1.2.0")!, runningBundle: inside, trash: unfinished.trash)
        check(UpdateFixture.marker(of: inside) == "running", "…nor the folder around it removed")
    }

    /// Restart and Update's shell (E6): it waits for the old process, then opens the path alone, and only while it holds an
    /// app. Run with a recorder in place of /usr/bin/open: no app starts.
    private static func relaunch(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let folder = root.appendingPathComponent("relaunch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try UpdateFixture.app(in: folder, version: "1.1.0", marker: "new")
        let log = folder.appendingPathComponent("opened.log")
        let recorder = folder.appendingPathComponent("recorder.sh")
        try "#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\"; done >> \"\(log.path)\"\n"
            .write(to: recorder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)
        // The old process lives 4 s. A shell that didn't wait would have opened by 2 s (starting a shell and the opener takes
        // about half a second here): at 2 s it must still be waiting, with nothing opened.
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["4"]
        try old.run()
        guard let shell = AppUpdateRelaunch.start(app, afterExitOf: old.processIdentifier, opener: recorder.path) else {
            return check(false, "the relaunch shell starts")
        }
        usleep(2_000_000)
        check(shell.isRunning && !FileManager.default.fileExists(atPath: log.path), "the relaunch shell waits while the old process runs")
        old.waitUntilExit()
        shell.waitUntilExit()
        let opened = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        check(opened == [app.path], "once it has exited, the app is opened at its path, nothing else passed (got \(opened))")
        try? FileManager.default.removeItem(at: log)
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        let moved = AppUpdateRelaunch.start(folder.appendingPathComponent("Moved.app"), afterExitOf: done.processIdentifier, opener: recorder.path)
        moved?.waitUntilExit()
        check(moved != nil && !FileManager.default.fileExists(atPath: log.path), "a path that no longer holds an app is never opened")
        check(AppUpdateRelaunch.opener == "/usr/bin/open", "the opener is /usr/bin/open")
    }
}
