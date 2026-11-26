import Darwin
import Foundation

// scripts/check-app-update.sh: the install at quit against scratch folders (AppUpdateInstaller with the production verifier,
// its system steps replaced by the fixtures'): the new copy swapped in, the replaced one in the scratch Trash only after the
// new one is in place, the marker for the next launch, the record and the downloaded DMG gone; nothing staged, a copy that
// fails its check, another instance running, a swap that fails, the running app moved away or unreadable, a staged copy on
// another volume leave the old app where it was, working; a record naming an app outside the staging folder, or reached
// through a link, is refused and touches nothing there; a destination already at the staged version or newer is never
// downgraded. Then the guarantee itself: a loop of swaps is killed (SIGKILL) at random instants, and after every kill both
// paths hold a whole, valid app: never missing, never half.

enum InstallChecks {
    struct Scene {
        let root: URL
        let applications: URL
        let files: AppUpdateFiles
        let trash: URL
        var destination: URL { applications.appendingPathComponent("SkyCut.app") }

        init(_ parent: URL, _ name: String) throws {
            root = parent.appendingPathComponent(name)
            applications = root.appendingPathComponent("Applications")
            files = AppUpdateFiles(root: root.appendingPathComponent("Updates"))
            trash = root.appendingPathComponent("Trash")
            for folder in [applications, trash] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            try files.makeFolders()
        }

        /// The running app (1.0.0, "old") in Applications and a staged 1.1.0 ("new") with its record.
        func prepare(stagedVersion: String = "1.1.0") throws -> AppUpdateStagedRecord {
            try UpdateFixture.app(in: applications, version: "1.0.0", marker: "old")
            let folder = files.stagingFolder(for: AppUpdateVersion(stagedVersion)!)
            let staged = try UpdateFixture.app(in: folder, version: stagedVersion, build: "2", marker: "new")
            let record = AppUpdateStagedRecord(feed: InstallChecks.feed, appPath: staged.path, asked: false)
            try files.writeStaged(record)
            return record
        }

        /// The production verifier at quit against the running app (the destination), with the fixtures' requirement.
        func installer(othersRunning: Bool = false, requirementFails: Bool = false, swap: ((URL, URL) throws -> Void)? = nil,
                       trashCheck: @escaping (URL) -> Void = { _ in }) -> AppUpdateInstaller {
            let trash = self.trash
            let destination = self.destination
            var steps = AppUpdateVerifier.Steps()
            steps.requirement = { _ in
                if requirementFails { throw AppUpdateError("the running app's signature can't be read") }
                return UpdateFixture.identifierRequirement()
            }
            var installer = AppUpdateInstaller(
                destination: destination, files: files,
                verify: { staged, feed in
                    try AppUpdateVerifier.verify(staged, feed: feed, runningApp: destination, running: AppUpdateVersion("1.0.0")!,
                                                 atQuit: true, steps: steps)
                },
                othersRunning: { _ in othersRunning },
                trash: { item in
                    trashCheck(item)
                    try FileManager.default.moveItem(at: item, to: trash.appendingPathComponent(item.lastPathComponent))
                })
            if let swap { installer.swap = swap }
            return installer
        }
    }

    static let feed = FeedChecks.feed(UpdateFixture.feedJSON(version: "1.1.0", build: "2", url: FeedChecks.url, size: 1, sha: FeedChecks.sha))!

    static func run(root: URL, binary: String, check: (Bool, String) -> Void) throws {
        print("==> the install at quit against scratch folders")
        let running = AppUpdateVersion("1.0.0")!
        try installs(root, running, check)
        try refusals(root, running, check)
        try ownCopyOnly(root, running, check)
        try noDowngrade(root, running, check)
        try stagedGone(root, check)
        try crossVolume(root, running, check)
        print("==> a loop of swaps killed at random instants")
        try kills(root, binary: binary, check)
    }

    private static func installs(_ root: URL, _ running: AppUpdateVersion, _ check: (Bool, String) -> Void) throws {
        let scene = try Scene(root, "install")
        let record = try scene.prepare()
        try Data("dmg".utf8).write(to: scene.files.dmg(for: feed))
        var newInPlaceWhenTrashed = false
        let outcome = scene.installer(trashCheck: { _ in
            newInPlaceWhenTrashed = UpdateFixture.marker(of: scene.destination) == "new"
        }).install(record, running: running)
        guard case .installed(let note) = outcome else { return check(false, "the staged copy installs (got \(outcome))") }
        check(UpdateFixture.marker(of: scene.destination) == "new" && UpdateFixture.codesignVerifies(scene.destination),
              "the new app is in place, intact (codesign --verify --deep --strict)")
        check(newInPlaceWhenTrashed, "the replaced app went to the Trash only after the new one was in place")
        check(UpdateFixture.marker(of: scene.trash.appendingPathComponent("SkyCut.app")) == "old", "the replaced app is in the Trash, whole")
        check(scene.files.readInstalledNote() == note && note.from == running && note.to.description == "1.1.0",
              "the marker for the next launch names 1.0.0 → 1.1.0")
        check(scene.files.readStaged() == nil && UpdateFixture.contents(of: scene.files.staging).isEmpty, "the staged record and folder are gone")
        check(UpdateFixture.contents(of: scene.files.downloads).isEmpty, "the downloaded DMG is removed once installed")
    }

    private static func untouched(_ scene: Scene, _ label: String, staged: Bool, _ check: (Bool, String) -> Void) {
        check(UpdateFixture.marker(of: scene.destination) == "old" && UpdateFixture.codesignVerifies(scene.destination),
              "\(label): the old app is where it was, intact")
        check(scene.files.readInstalledNote() == nil, "\(label): no marker")
        check((scene.files.readStaged() != nil) == staged, "\(label): the update \(staged ? "stays staged" : "is removed")")
        check(UpdateFixture.contents(of: scene.trash).isEmpty, "\(label): nothing went to the Trash")
    }

    private static func refusals(_ root: URL, _ running: AppUpdateVersion, _ check: (Bool, String) -> Void) throws {
        let nothing = try Scene(root, "nothing")
        try UpdateFixture.app(in: nothing.applications, version: "1.0.0", marker: "old")
        check(nothing.installer().install(nil, running: running) == .nothingStaged, "nothing staged: nothing happens")
        untouched(nothing, "nothing staged", staged: false, check)

        let stale = try Scene(root, "stale")
        let staleRecord = try stale.prepare()
        check(stale.installer().install(staleRecord, running: AppUpdateVersion("1.1.0")!) == .nothingStaged,
              "a staged copy not newer than the running version never installs")

        let broken = try Scene(root, "broken")
        let brokenRecord = try broken.prepare(stagedVersion: "1.1.0")
        try Data("changed".utf8).write(to: URL(fileURLWithPath: brokenRecord.appPath).appendingPathComponent("Contents/Resources/marker.txt"))
        if case .copyRejected = broken.installer().install(brokenRecord, running: running) {
            untouched(broken, "a staged copy changed since it was verified", staged: false, check)
        } else {
            check(false, "a staged copy changed since it was verified is rejected")
        }

        let busy = try Scene(root, "busy")
        let busyRecord = try busy.prepare()
        check(busy.installer(othersRunning: true).install(busyRecord, running: running) == .otherInstanceRunning,
              "another SkyCut running from the bundle: no install")
        untouched(busy, "another instance running", staged: true, check)

        let failing = try Scene(root, "swap-fails")
        let failingRecord = try failing.prepare()
        if case .swapFailed = failing.installer(swap: { _, _ in throw AppUpdateError("no") }).install(failingRecord, running: running) {
            untouched(failing, "a swap that fails", staged: true, check)
        } else {
            check(false, "a swap that fails is reported")
        }

        // The running app moved or renamed away (Finder), or its signature unreadable: the copy isn't to blame and stays.
        let missing = try Scene(root, "missing")
        let missingRecord = try missing.prepare()
        try FileManager.default.removeItem(at: missing.destination)
        let gone = missing.installer().install(missingRecord, running: running)
        if case .runningAppUnavailable = gone {
            check(!FileManager.default.fileExists(atPath: missing.destination.path) && missing.files.readStaged() != nil
                  && UpdateFixture.marker(of: URL(fileURLWithPath: missingRecord.appPath)) == "new",
                  "the running app moved away: nothing is created there, the staged copy stays for the next quit")
        } else {
            check(false, "the running app moved away: the staged copy stays for the next quit (got \(gone))")
        }
        let unreadable = try Scene(root, "unreadable-signature")
        let unreadableRecord = try unreadable.prepare()
        let unreadableOutcome = unreadable.installer(requirementFails: true).install(unreadableRecord, running: running)
        if case .runningAppUnavailable = unreadableOutcome {
            untouched(unreadable, "the running app's signature unreadable", staged: true, check)
        } else {
            check(false, "the running app's signature unreadable: the staged copy stays (got \(unreadableOutcome))")
        }
    }

    /// Only the stager's own copy (E1): a record naming an app elsewhere, or reached through a link, is refused and dropped;
    /// the app it named and the folder around it stay.
    private static func ownCopyOnly(_ root: URL, _ running: AppUpdateVersion, _ check: (Bool, String) -> Void) throws {
        let outside = try Scene(root, "outside-record")
        _ = try outside.prepare()
        let folder = outside.root.appendingPathComponent("SomeFolder")
        let elsewhere = try UpdateFixture.app(in: folder, version: "1.1.0", build: "2", marker: "elsewhere")
        try Data("keep me".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let bogus = AppUpdateStagedRecord(feed: feed, appPath: elsewhere.path, asked: false)
        try outside.files.writeStaged(bogus)
        check(outside.installer().install(bogus, running: running) == .recordRefused, "a record naming an app outside the staging folder is refused")
        untouched(outside, "a record naming an app elsewhere", staged: false, check)
        check(UpdateFixture.marker(of: elsewhere) == "elsewhere" && FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path),
              "the app it named and the folder around it are untouched")

        let linked = try Scene(root, "linked-record")
        try UpdateFixture.app(in: linked.applications, version: "1.0.0", marker: "old")
        let target = linked.root.appendingPathComponent("Elsewhere")
        let reached = try UpdateFixture.app(in: target, version: "1.1.0", build: "2", marker: "through-link")
        let version = linked.files.stagingFolder(for: AppUpdateVersion("1.1.0")!)
        try FileManager.default.createSymbolicLink(at: version, withDestinationURL: target)
        let through = AppUpdateStagedRecord(feed: feed, appPath: version.appendingPathComponent("SkyCut.app").path, asked: false)
        try linked.files.writeStaged(through)
        check(linked.installer().install(through, running: running) == .recordRefused, "a staged copy reached through a link is refused")
        untouched(linked, "a staged copy reached through a link", staged: false, check)
        check(UpdateFixture.marker(of: reached) == "through-link", "what the link points to stays where it is, whole")
    }

    /// A staged copy another SkyCut removed meanwhile (renamed aside in one step, AppUpdateFiles.remove): the swap fails and
    /// the old app stays whole, never half a bundle in its place.
    private static func stagedGone(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try Scene(root, "staged-gone")
        let record = try scene.prepare()
        let staged = URL(fileURLWithPath: record.appPath)
        scene.files.remove(staged)
        do {
            try AppUpdateInstaller.exchange(staged, scene.destination)
            check(false, "a swap whose staged copy is gone fails")
        } catch {
            check(UpdateFixture.marker(of: scene.destination) == "old" && UpdateFixture.codesignVerifies(scene.destination),
                  "a swap whose staged copy was removed meanwhile fails, the old app whole (\(error.localizedDescription))")
        }
    }

    /// No downgrade at quit (E2): what is at the destination now is read again; the same version or a newer one stays.
    private static func noDowngrade(_ root: URL, _ running: AppUpdateVersion, _ check: (Bool, String) -> Void) throws {
        for (name, there) in [("newer-there", "1.2.0"), ("same-there", "1.1.0")] {
            let scene = try Scene(root, name)
            let record = try scene.prepare()
            try FileManager.default.removeItem(at: scene.destination)
            try UpdateFixture.app(in: scene.applications, version: there, marker: "there")
            let outcome = scene.installer().install(record, running: running)
            check(outcome == .notNewer(AppUpdateVersion(there)!), "\(there) put at the destination while 1.0.0 runs: no install (got \(outcome))")
            check(UpdateFixture.marker(of: scene.destination) == "there" && UpdateFixture.contents(of: scene.trash).isEmpty,
                  "\(there) stays where it is, nothing goes to the Trash")
            check(scene.files.readStaged() == nil && UpdateFixture.contents(of: scene.files.staging).isEmpty, "\(there): the staged copy is dropped")
        }
    }

    /// The staged copy on another volume (a writable scratch image): renamex_np refuses, both stay whole.
    private static func crossVolume(_ root: URL, _ running: AppUpdateVersion, _ check: (Bool, String) -> Void) throws {
        let scene = try Scene(root, "cross-volume")
        try UpdateFixture.app(in: scene.applications, version: "1.0.0", marker: "old")
        let image = root.appendingPathComponent("other-volume.dmg")
        let mount = root.appendingPathComponent("other-volume")
        Tools.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "16m", "-fs", "HFS+", "-volname", "SkyCutUpdateOther", "-ov", image.path])
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Tools.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path]).status == 0 else {
            return check(false, "a scratch volume attaches")
        }
        defer { Tools.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let staged = try UpdateFixture.app(in: mount.appendingPathComponent("1.1.0"), version: "1.1.0", build: "2", marker: "new")
        do {
            try AppUpdateInstaller.exchange(staged, scene.destination)
            check(false, "a swap across volumes is refused")
        } catch {
            check(UpdateFixture.marker(of: scene.destination) == "old" && UpdateFixture.marker(of: staged) == "new",
                  "a swap across volumes is refused, both apps where they were (\(error.localizedDescription))")
        }
    }

    /// The child: swaps `a` and `b` `count` times as fast as it can, saying "swapping" after the first (the parent kills it).
    static func swapLoop(_ a: URL, _ b: URL, count: Int) -> Int32 {
        for index in 0..<count {
            do { try AppUpdateInstaller.exchange(a, b) } catch { return 3 }
            if index == 0 {
                FileHandle.standardOutput.write(Data("swapping\n".utf8))
            }
        }
        return 0
    }

    private static func kills(_ root: URL, binary: String, _ check: (Bool, String) -> Void) throws {
        let scene = try Scene(root, "kills")
        try UpdateFixture.app(in: scene.applications, version: "1.0.0", marker: "old")
        let staged = try UpdateFixture.app(in: scene.files.stagingFolder(for: AppUpdateVersion("1.1.0")!), version: "1.1.0", marker: "new")
        var killed = 0, whole = 0
        for round in 0..<24 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: binary)
            child.arguments = ["--swap-loop", staged.path, scene.destination.path, "200000"]
            let pipe = Pipe()
            child.standardOutput = pipe
            try child.run()
            // Killed only once it swaps: then, 1 to 40 ms later, at a different instant each round.
            _ = pipe.fileHandleForReading.availableData
            usleep(useconds_t(1_000 + (round * 7_919) % 39_000))
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            if child.terminationReason == .uncaughtSignal { killed += 1 }
            let markers = [UpdateFixture.marker(of: scene.destination), UpdateFixture.marker(of: staged)]
            if Set(markers.compactMap { $0 }) == ["old", "new"],
               UpdateFixture.codesignVerifies(scene.destination), UpdateFixture.codesignVerifies(staged) {
                whole += 1
            } else {
                check(false, "after kill \(round): both paths hold a whole app (markers \(markers))")
            }
        }
        check(killed >= 20, "the swap loop was killed mid-run (\(killed) of 24)")
        check(whole == 24, "after every kill the app is never missing or half-written (\(whole) of 24)")
    }
}
