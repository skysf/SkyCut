import Darwin
import Foundation

// scripts/check-app-update.sh: the install at quit against scratch folders (AppUpdateInstaller): the new copy swapped in, the
// replaced one in the scratch Trash only after the new one is in place, the marker for the next launch, the record gone;
// nothing staged, a copy that fails its check, another instance running, a swap that fails, the destination missing and
// a staged copy on another volume leave the old app where it was, working. Then the guarantee itself: a loop of swaps is
// killed (SIGKILL) at random instants, and after every kill both paths hold a whole, valid app: never missing, never half.

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
            let feed = FeedChecks.feed(UpdateFixture.feedJSON(version: "1.1.0", build: "2", url: FeedChecks.url, size: 1, sha: FeedChecks.sha))!
            let record = AppUpdateStagedRecord(feed: feed, appPath: staged.path, asked: false)
            try files.writeStaged(record)
            return record
        }

        func installer(othersRunning: Bool = false, swap: ((URL, URL) throws -> Void)? = nil,
                       trashCheck: @escaping (URL) -> Void = { _ in }) -> AppUpdateInstaller {
            let trash = self.trash
            var installer = AppUpdateInstaller(
                destination: destination, files: files,
                verify: { staged, feed in
                    try AppUpdateVerifier.checkInfo(of: staged, feed: feed, bundleIdentifier: UpdateFixture.identifier,
                                                    running: AppUpdateVersion("1.0.0")!)
                    try AppBundleSignature.verify(staged, satisfies: UpdateFixture.identifierRequirement(), network: false)
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

    static func run(root: URL, binary: String, check: (Bool, String) -> Void) throws {
        print("==> the install at quit against scratch folders")
        let running = AppUpdateVersion("1.0.0")!
        try installs(root, running, check)
        try refusals(root, running, check)
        try crossVolume(root, running, check)
        print("==> a loop of swaps killed at random instants")
        try kills(root, binary: binary, check)
    }

    private static func installs(_ root: URL, _ running: AppUpdateVersion, _ check: (Bool, String) -> Void) throws {
        let scene = try Scene(root, "install")
        let record = try scene.prepare()
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
    }

    private static func refusals(_ root: URL, _ running: AppUpdateVersion, _ check: (Bool, String) -> Void) throws {
        func untouched(_ scene: Scene, _ label: String, staged: Bool) {
            check(UpdateFixture.marker(of: scene.destination) == "old" && UpdateFixture.codesignVerifies(scene.destination),
                  "\(label): the old app is where it was, intact")
            check(scene.files.readInstalledNote() == nil, "\(label): no marker")
            check((scene.files.readStaged() != nil) == staged, "\(label): the update \(staged ? "stays staged" : "is removed")")
            check(UpdateFixture.contents(of: scene.trash).isEmpty, "\(label): nothing went to the Trash")
        }
        let nothing = try Scene(root, "nothing")
        try UpdateFixture.app(in: nothing.applications, version: "1.0.0", marker: "old")
        check(nothing.installer().install(nil, running: running) == .nothingStaged, "nothing staged: nothing happens")
        untouched(nothing, "nothing staged", staged: false)

        let stale = try Scene(root, "stale")
        let staleRecord = try stale.prepare()
        check(stale.installer().install(staleRecord, running: AppUpdateVersion("1.1.0")!) == .nothingStaged,
              "a staged copy not newer than the running version never installs")

        let broken = try Scene(root, "broken")
        let brokenRecord = try broken.prepare(stagedVersion: "1.1.0")
        try Data("changed".utf8).write(to: URL(fileURLWithPath: brokenRecord.appPath).appendingPathComponent("Contents/Resources/marker.txt"))
        if case .copyRejected = broken.installer().install(brokenRecord, running: running) {
            untouched(broken, "a staged copy changed since it was verified", staged: false)
        } else {
            check(false, "a staged copy changed since it was verified is rejected")
        }

        let busy = try Scene(root, "busy")
        let busyRecord = try busy.prepare()
        check(busy.installer(othersRunning: true).install(busyRecord, running: running) == .otherInstanceRunning,
              "another SkyCut running from the bundle: no install")
        untouched(busy, "another instance running", staged: true)

        let failing = try Scene(root, "swap-fails")
        let failingRecord = try failing.prepare()
        if case .swapFailed = failing.installer(swap: { _, _ in throw AppUpdateError("no") }).install(failingRecord, running: running) {
            untouched(failing, "a swap that fails", staged: true)
        } else {
            check(false, "a swap that fails is reported")
        }

        let missing = try Scene(root, "missing")
        let missingRecord = try missing.prepare()
        try FileManager.default.removeItem(at: missing.destination)
        if case .swapFailed = missing.installer().install(missingRecord, running: running) {
            check(!FileManager.default.fileExists(atPath: missing.destination.path) && missing.files.readStaged() != nil,
                  "the destination gone: the real exchange refuses, nothing is created there, the update stays staged")
        } else {
            check(false, "the destination gone: the real exchange refuses")
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
