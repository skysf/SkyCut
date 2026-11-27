import Foundation

// scripts/check-app-update.sh: the Updates folder's own rules (AppUpdateFiles) against scratch folders. Never through the
// folder itself when it is a link: the launch, an up-to-date check, staging and installing leave the place it points to
// alone (a link above it, Application Support on another disk, works as before). A deletion is one step for anyone
// watching: renamed aside, then deleted, so the path holds the whole item or nothing even when the deletion fails halfway;
// what is left aside is emptied at the next launch. The Data volume's spelling is the same place: a staged copy started
// that way never updates or deletes itself. A sibling folder that only starts like Updates is outside.

enum FilesChecks {
    static func run(root: URL, check: (Bool, String) -> Void) throws {
        print("==> the Updates folder: a link at its root, deletions in one step, the Data volume")
        try linkedRoot(root, check)
        try removeAside(root, check)
        try dataVolume(root, check)
        try sibling(root, check)
    }

    /// `Updates` itself a link to a home folder (review FBU2, F1): nothing there is read, deleted or trashed.
    private static func linkedRoot(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let base = root.appendingPathComponent("linked-root")
        let home = base.appendingPathComponent("Home")
        let movie = home.appendingPathComponent("Downloads/holiday.mov"), notes = home.appendingPathComponent("Documents/notes.txt")
        for file in [movie, notes] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        // As if an update had left things there: the app a swap replaced, a staged copy and its record, the marker.
        let replaced = try UpdateFixture.app(in: home.appendingPathComponent("staged.noindex/1.1.0"), version: "1.0.0", marker: "replaced there")
        let staged = try UpdateFixture.app(in: home.appendingPathComponent("staged.noindex/1.2.0"), version: "1.2.0", marker: "staged there")
        let support = base.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let files = AppUpdateFiles(root: support.appendingPathComponent("Updates"))
        try FileManager.default.createSymbolicLink(at: files.root, withDestinationURL: home)
        let record = AppUpdateStagedRecord(feed: FeedChecks.feed(FeedChecks.valid(version: "1.2.0"))!,
                                           appPath: files.stagingFolder(for: AppUpdateVersion("1.2.0")!).appendingPathComponent("SkyCut.app").path,
                                           asked: false)
        try record.data().write(to: home.appendingPathComponent("staged.json"))
        try AppUpdateInstalledNote(from: AppUpdateVersion("1.0.0")!, to: AppUpdateVersion("1.1.0")!, notes: ["en": ["New"]]).data()
            .write(to: home.appendingPathComponent("installed.json"))
        let kept = [movie, notes, home.appendingPathComponent("staged.json"), home.appendingPathComponent("installed.json")]
        let untouched = {
            kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                && UpdateFixture.marker(of: replaced) == "replaced there" && UpdateFixture.marker(of: staged) == "staged there"
        }
        check(files.rootIsLink && FileManager.default.fileExists(atPath: files.staging.appendingPathComponent("1.2.0/SkyCut.app").path),
              "the scene: Updates is a link, its staged.noindex is the home's")
        var trashed: [String] = []
        let trash = { (item: URL) throws in
            trashed.append(UpdateFixture.marker(of: item) ?? item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: base.appendingPathComponent("Trash-\(trashed.count)"))
        }
        let running = AppUpdateVersion("1.1.0")!, runningBundle = base.appendingPathComponent("Applications/SkyCut.app")
        let found = AppUpdateLaunchFiles.take(from: files, decision: .updates, running: running, runningBundle: runningBundle, trash: trash)
        check(found == AppUpdateLaunchFiles() && trashed.isEmpty && untouched(),
              "Updates itself a link: the launch reads, deletes and trashes nothing where it points")
        files.removeStaged(except: nil)
        files.removeDownloads()
        files.writeRetry(nil)
        check(untouched(), "…nor does an up-to-date check")
        AppUpdateLaunchFiles.clean(files, running: running, runningBundle: runningBundle, trash: trash)
        check(untouched() && trashed.isEmpty, "…nor the cleanup itself")
        check((try? files.makeFolders()) == nil && files.stagedCopy(of: record) == nil, "…nothing is staged into it or installed from it")
        check(!files.holds(movie) && !files.holds(files.staging.appendingPathComponent("1.2.0")), "holds() is false under a linked Updates folder")
        files.writeRetry(AppUpdateRetryRecord(dmgSHA256: FeedChecks.sha, failures: 1, lastFailure: StateChecks.t0))
        check(!FileManager.default.fileExists(atPath: home.appendingPathComponent("retry.json").path), "…and no record is written there")
        // A link above the Updates folder (Application Support moved to another disk): as before.
        let moved = base.appendingPathComponent("OtherDisk/Support")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let linkedSupport = base.appendingPathComponent("LinkedSupport")
        try FileManager.default.createSymbolicLink(at: linkedSupport, withDestinationURL: moved)
        let above = AppUpdateFiles(root: linkedSupport.appendingPathComponent("Updates"))
        try above.makeFolders()
        let dmg = above.downloads.appendingPathComponent("SkyCut-1.0.5-abababababab.dmg")
        try Data("old".utf8).write(to: dmg)
        above.removeDownloads()
        check(above.holds(dmg) && !FileManager.default.fileExists(atPath: dmg.path), "a link above the Updates folder works as before")
    }

    /// A deletion is one step for anyone watching (review FBU2, F8): renamed aside, then deleted there.
    private static func removeAside(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try LaunchScene(root, "remove-aside")
        let bundle = try scene.app("1.1.0", inFolder: "1.1.0", marker: "staged")
        // A folder inside it that can't be emptied: the deletion fails halfway.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bundle.appendingPathComponent("Contents/Resources").path)
        scene.files.remove(bundle)
        check(!FileManager.default.fileExists(atPath: bundle.path),
              "a deletion that fails halfway leaves nothing at the path: renamed aside in one step, never half a bundle")
        let aside = UpdateFixture.contents(of: scene.files.removing)
        check(aside.count == 1, "…what couldn't be deleted waits aside (\(aside))")
        for name in aside {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: scene.files.removing.appendingPathComponent("\(name)/Contents/Resources").path)
        }
        AppUpdateLaunchFiles.clean(scene.files, running: AppUpdateVersion("1.0.0")!, runningBundle: scene.runningBundle, trash: scene.trash)
        check(UpdateFixture.contents(of: scene.files.removing).isEmpty && scene.trashed.isEmpty,
              "the launch cleanup empties what a crash or a failed deletion left aside")
        let whole = try scene.app("1.2.0", inFolder: "1.2.0", marker: "whole")
        scene.files.remove(whole)
        check(!FileManager.default.fileExists(atPath: whole.path) && UpdateFixture.contents(of: scene.files.removing).isEmpty,
              "a deletion that succeeds leaves nothing, aside or in place")
    }

    /// E8 through the Data volume (review FBU2, F6): `/System/Volumes/Data/…` is the same place as the plain path.
    private static func dataVolume(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try LaunchScene(root, "data-volume")
        let own = try scene.app("1.2.0", inFolder: "1.2.0", marker: "running")
        let spelled = URL(fileURLWithPath: "/System/Volumes/Data" + own.path)
        guard FileManager.default.fileExists(atPath: spelled.path) else {
            return check(false, "the scratch folder is reachable through /System/Volumes/Data (\(spelled.path))")
        }
        check(scene.files.holds(spelled), "a staged copy started through /System/Volumes/Data is inside the Updates folder (it never updates)")
        AppUpdateLaunchFiles.clean(scene.files, running: AppUpdateVersion("1.3.0")!, runningBundle: spelled, trash: scene.trash)
        check(UpdateFixture.marker(of: own) == "running" && scene.trashed.isEmpty, "…and its launch cleanup never deletes the bundle it runs from")
        check(AppUpdateFiles.withoutDataVolume("/System/Volumes/Data/System/Library") == "/System/Volumes/Data/System/Library",
              "only a top folder that is the same file loses the Data volume's prefix")
    }

    /// A sibling that only starts like the Updates folder is outside it.
    private static func sibling(_ root: URL, _ check: (Bool, String) -> Void) throws {
        let scene = try LaunchScene(root, "sibling")
        let sibling = scene.files.root.deletingLastPathComponent().appendingPathComponent(scene.files.root.lastPathComponent + "X")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let item = sibling.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: item)
        scene.files.remove(item)
        check(!scene.files.holds(item) && FileManager.default.fileExists(atPath: item.path),
              "a sibling folder that only starts like Updates (UpdatesX) is outside: nothing in it is removed")
    }
}
