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
//   staged.json                              AppUpdateStagedRecord
//   installed.json                           AppUpdateInstalledNote, written by the installer right before the swap
//   retry.json                               AppUpdateRetryRecord
// Records are written atomically (a temporary file renamed over the old one). Every removal goes through `remove`, which
// removes nothing outside this folder (links on the way resolved; a link itself is removed, never what it points to); a
// staged copy counts only where the stager puts it (`stagedCopy(of:)`). Blocking file work: callers run it on
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
    var stagedRecordURL: URL { root.appendingPathComponent("staged.json") }
    var installedNoteURL: URL { root.appendingPathComponent("installed.json") }
    var retryRecordURL: URL { root.appendingPathComponent("retry.json") }

    func dmg(for feed: AppUpdateFeed) -> URL {
        downloads.appendingPathComponent("SkyCut-\(feed.version)-\(feed.dmgSHA256.prefix(12)).dmg")
    }

    func stagingFolder(for version: AppUpdateVersion) -> URL {
        staging.appendingPathComponent(version.description, isDirectory: true)
    }

    /// The folders, this user's only (0700). A link made in place of downloads/ or staged.noindex/ is removed (the link
    /// only), so no copy or removal is led outside.
    func makeFolders() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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

    /// Keeps the retry record (nil: removes it). Without the folder (nothing ever downloaded) there is nothing to keep.
    func writeRetry(_ record: AppUpdateRetryRecord?) {
        guard let record else { return remove(retryRecordURL) }
        try? record.data().write(to: retryRecordURL, options: .atomic)
    }

    // MARK: The staged copy

    /// The record's copy, but only where the stager puts it: staged.noindex/<the record's version>/<name>.app in this folder,
    /// with no link on the way (whether it exists is the caller's question). nil for any other path: the installer refuses
    /// and drops such a record, and nothing outside this folder is ever installed or removed through one.
    func stagedCopy(of record: AppUpdateStagedRecord) -> URL? {
        let given = URL(fileURLWithPath: record.appPath).standardizedFileURL
        let name = given.lastPathComponent
        let folder = stagingFolder(for: record.feed.version)
        let expected = folder.appendingPathComponent(name, isDirectory: true)
        guard name.hasSuffix(".app"), name.count > ".app".count, given.path == expected.standardizedFileURL.path,
              ![staging, folder, expected].contains(where: Self.isLink),
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

    /// Removes `item` only when it lies inside this folder once the links on the way are resolved; a link is removed itself,
    /// never what it points to. The one place the updater deletes anything (checks/app-update-wiring.sh).
    func remove(_ item: URL) {
        guard holds(item) else { return }
        try? FileManager.default.removeItem(at: item)
    }

    /// `item` lies inside this folder (never the folder itself), the links on the way to it resolved.
    func holds(_ item: URL) -> Bool {
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

    /// The path with every link resolved as far as it exists (`/var` → `/private/var`); a missing tail is kept as written.
    static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while true {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                let base = String(cString: real)
                return tail.reversed().reduce(base) { path, component in (path == "/" ? "" : path) + "/" + component }
            }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return url.standardizedFileURL.path }
            tail.append(existing.lastPathComponent)
            existing = parent
        }
    }
}
