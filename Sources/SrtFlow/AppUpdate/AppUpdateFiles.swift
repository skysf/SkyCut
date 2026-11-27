import Darwin
import Foundation

// MARK: - Where the updater keeps its files, and what may be removed there
//
// What it does: one folder, Application Support/SrtFlow/Updates (the identity-class name stays SrtFlow:
// docs/architecture/product-name.md; only the release app updates, so nothing else writes here):
//   downloads/SkyCut-<version>-<sha12>.dmg   a finished download: kept until the update is installed, the feed names another
//                                            DMG or nothing newer, or it fails its check (AppUpdatePipeline)
//   staged.noindex/<version>/<name>.app      the verified copy waiting for the next quit (`.noindex`: Spotlight never lists
//                                            it); after the swap, the old app until it is trashed
//   removing.noindex/<uuid>                  what is being deleted: renamed here in one step first, then deleted
//   staged.json                              AppUpdateStagedRecord
//   installed.json                           AppUpdateInstalledNote, written by the installer right before the swap
//   retry.json                               AppUpdateRetryRecord
// Records are written atomically (a temporary file renamed over the old one). Every deletion goes through `remove`: nothing
// outside this folder (links on the way resolved; a link itself is removed, never what it points to), and never through
// the folder itself when it is a link (`rootIsLink`: a link above it, Application Support moved to another disk, is fine).
// A deletion renames the item aside first, in one step, so no other process ever sees half a bundle where it was. A staged
// copy counts only where the stager puts it (`stagedCopy(of:)`). Blocking file work: callers run it on
// AppUpdateWork.queue, or at quit on the main thread (AppUpdateInstaller).
// What it doesn't: decide what to keep (AppUpdateState, AppUpdateLaunchFiles), download (AppUpdateHTTP), stage, swap.
// Rules: docs/architecture/app-updates.md "Files".

struct AppUpdateFiles: Sendable {
    let root: URL

    static func standard() -> AppUpdateFiles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppUpdateFiles(root: support.appendingPathComponent("SrtFlow/Updates", isDirectory: true))
    }

    var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    /// Ends in `.noindex`: Spotlight never indexes the staged copy, so it is never listed or offered for a project.
    var staging: URL { root.appendingPathComponent("staged.noindex", isDirectory: true) }
    /// Where a deletion goes first, in one rename (`remove`); emptied by the launch cleanup (`emptyRemovalFolder`).
    var removing: URL { root.appendingPathComponent("removing.noindex", isDirectory: true) }
    var stagedRecordURL: URL { root.appendingPathComponent("staged.json") }
    var installedNoteURL: URL { root.appendingPathComponent("installed.json") }
    var retryRecordURL: URL { root.appendingPathComponent("retry.json") }

    /// The Updates folder itself is a link (made by hand): never followed. Nothing is removed, staged or installed through
    /// it, and a launch reads nothing there (AppUpdateLaunchFiles).
    var rootIsLink: Bool { Self.isLink(root) }

    func dmg(for feed: AppUpdateFeed) -> URL {
        downloads.appendingPathComponent("SkyCut-\(feed.version)-\(feed.dmgSHA256.prefix(12)).dmg")
    }

    func stagingFolder(for version: AppUpdateVersion) -> URL {
        staging.appendingPathComponent(version.description, isDirectory: true)
    }

    /// The folders, this user's only (0700). Refused while the Updates folder is a link. A link made in place of downloads/,
    /// staged.noindex/ or removing.noindex/ is removed (the link only), so no copy or removal is led outside.
    func makeFolders() throws {
        guard !rootIsLink else { throw AppUpdateError("the Updates folder is a link: nothing goes through it") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard prepareRemovalFolder() else { throw AppUpdateError("no folder to remove things through") }
        for folder in [downloads, staging] {
            if Self.isLink(folder) { remove(folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    // MARK: Records

    func readStaged() -> AppUpdateStagedRecord? {
        (try? Data(contentsOf: stagedRecordURL)).flatMap(AppUpdateStagedRecord.init(data:))
    }

    func writeStaged(_ record: AppUpdateStagedRecord) throws {
        try record.data().write(to: stagedRecordURL, options: .atomic)
    }

    func removeStagedRecord() {
        remove(stagedRecordURL)
    }

    func readInstalledNote() -> AppUpdateInstalledNote? {
        (try? Data(contentsOf: installedNoteURL)).flatMap(AppUpdateInstalledNote.init(data:))
    }

    func writeInstalledNote(_ note: AppUpdateInstalledNote) throws {
        try note.data().write(to: installedNoteURL, options: .atomic)
    }

    func removeInstalledNote() {
        remove(installedNoteURL)
    }

    func readRetry() -> AppUpdateRetryRecord? {
        (try? Data(contentsOf: retryRecordURL)).flatMap(AppUpdateRetryRecord.init(data:))
    }

    /// Keeps the retry record (nil: removes it). Never through a linked Updates folder.
    func writeRetry(_ record: AppUpdateRetryRecord?) {
        guard let record else { return remove(retryRecordURL) }
        guard !rootIsLink else { return }
        try? record.data().write(to: retryRecordURL, options: .atomic)
    }

    // MARK: The staged copy

    /// The record's copy, but only where the stager puts it: staged.noindex/<the record's version>/<name>.app in this folder,
    /// with no link on the way, the Updates folder itself included (whether it exists is the caller's question). nil for
    /// any other path: the installer refuses and drops such a record, and nothing outside this folder is ever installed or
    /// removed through one.
    func stagedCopy(of record: AppUpdateStagedRecord) -> URL? {
        let given = URL(fileURLWithPath: record.appPath).standardizedFileURL
        let name = given.lastPathComponent
        let folder = stagingFolder(for: record.feed.version)
        let expected = folder.appendingPathComponent(name, isDirectory: true)
        guard name.hasSuffix(".app"), name.count > ".app".count, given.path == expected.standardizedFileURL.path,
              ![root, staging, folder, expected].contains(where: Self.isLink),
              Self.resolvedPath(expected) == [Self.resolvedPath(root), staging.lastPathComponent, folder.lastPathComponent, name]
                  .joined(separator: "/") else { return nil }
        return expected
    }

    // MARK: Removing (inside this folder only)

    /// Every staged copy and the record, except the staged copy of `version` (nil: all of them).
    func removeStaged(except version: AppUpdateVersion?) {
        for folder in contents(of: staging) where folder.lastPathComponent != version?.description {
            remove(folder)
        }
        if let record = readStaged(), record.feed.version == version { return }
        removeStagedRecord()
    }

    func removeDownloads(except kept: URL? = nil) {
        for file in contents(of: downloads) where file.standardizedFileURL.path != kept?.standardizedFileURL.path {
            remove(file)
        }
    }

    /// A download kept from an earlier run is the feed's DMG: its size and SHA-256 still match. One that doesn't is removed.
    /// Blocking (hashing): AppUpdateWork.queue.
    func keptDownloadMatches(_ dmg: URL, feed: AppUpdateFeed) -> Bool {
        guard FileManager.default.fileExists(atPath: dmg.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? NSNumber)?.int64Value
        if !Self.isLink(dmg), size == feed.dmgSize, AppUpdateDigest.sha256(of: dmg) == feed.dmgSHA256 { return true }
        remove(dmg)
        return false
    }

    /// Removes `item` only when it lies inside this folder once the links on the way are resolved (a link is removed itself,
    /// never what it points to), and never while the folder itself is a link. One step for anyone watching: the item is
    /// first renamed into removing.noindex in one call, then deleted there, so another SkyCut never finds half a bundle where
    /// the item was (its swap of a staged path that is gone fails, leaving its app). Something that can't be renamed stays.
    func remove(_ item: URL) {
        var info = stat()
        guard lstat(item.path, &info) == 0, holds(item), prepareRemovalFolder() else { return }
        let aside = removing.appendingPathComponent(UUID().uuidString)
        guard rename(item.path, aside.path) == 0 else { return }
        deleteAside(aside)
    }

    /// An empty folder (an image's mount point once detached): removed only while empty, never anything in it.
    func removeEmptyFolder(_ folder: URL) {
        guard holds(folder) else { return }
        rmdir(folder.path)
    }

    /// What a crash, or a deletion that failed halfway, left aside (the launch cleanup).
    func emptyRemovalFolder() {
        guard holds(removing), !Self.isLink(removing) else { return }
        for item in contents(of: removing) { deleteAside(item) }
    }

    /// removing.noindex as a real folder of this user's (a link there is unlinked, never followed).
    private func prepareRemovalFolder() -> Bool {
        guard holds(removing) else { return false }
        if Self.isLink(removing) { unlink(removing.path) }
        try? FileManager.default.createDirectory(at: removing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return !Self.isLink(removing) && FileManager.default.fileExists(atPath: removing.path)
    }

    /// The one place the updater deletes a file or a folder: only ever something already renamed into removing.noindex.
    private func deleteAside(_ item: URL) {
        try? FileManager.default.removeItem(at: item)
    }

    /// `item` lies inside this folder (never the folder itself), the links on the way to it resolved, the Data volume's
    /// spelling the same as the plain one; always false while the folder itself is a link.
    func holds(_ item: URL) -> Bool {
        guard !rootIsLink else { return false }
        let name = item.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        let parent = Self.resolvedPath(item.deletingLastPathComponent())
        let root = Self.resolvedPath(self.root)
        return parent == root || parent.hasPrefix(root + "/")
    }

    func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// The path with every link resolved as far as it exists (`/var` → `/private/var`; a missing tail is kept as written),
    /// spelled without the Data volume's prefix (`withoutDataVolume`).
    static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while true {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                let base = String(cString: real)
                return withoutDataVolume(tail.reversed().reduce(base) { path, component in (path == "/" ? "" : path) + "/" + component })
            }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return withoutDataVolume(url.standardizedFileURL.path) }
            tail.append(existing.lastPathComponent)
            existing = parent
        }
    }

    /// `/System/Volumes/Data/Users/…` is `/Users/…` (realpath keeps the first spelling): the prefix is dropped when the top
    /// folder after it is the same file as the plain one (the system's firmlinks: /Users, /Applications, /private, …).
    static func withoutDataVolume(_ path: String) -> String {
        let volume = "/System/Volumes/Data"
        guard path.hasPrefix(volume + "/") else { return path }
        let plain = String(path.dropFirst(volume.count))
        guard let first = plain.split(separator: "/").first else { return path }
        var spelled = stat(), top = stat()
        guard stat(volume + "/" + first, &spelled) == 0, stat("/" + first, &top) == 0,
              spelled.st_dev == top.st_dev, spelled.st_ino == top.st_ino else { return path }
        return plain
    }
}
