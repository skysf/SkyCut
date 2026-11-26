import Foundation

// MARK: - Where the updater keeps its files, and the cleanup after an update
//
// What it does: one folder, Application Support/SrtFlow/Updates (the identity-class name stays SrtFlow:
// docs/architecture/product-name.md; only the release app updates, so nothing else writes here):
//   downloads/SkyCut-<version>-<sha12>.dmg   a download; removed once staged, and at every launch
//   staged/<version>/<name>.app               the verified copy waiting for the next quit; after the swap, the old app
//   staged.json                               AppUpdateStagedRecord
//   installed.json                            AppUpdateInstalledNote, written by the installer right before the swap
// Records are written atomically (a temporary file renamed over the old one). Blocking file work: callers run it on
// AppUpdateWork.queue, or at quit on the main thread (AppUpdateInstaller).
// What it doesn't: decide what to keep (AppUpdater), download (AppUpdateHTTP), stage (AppUpdateStager), swap.
// Rules: docs/architecture/app-updates.md "Files".

struct AppUpdateFiles: Sendable {
    let root: URL

    static func standard() -> AppUpdateFiles {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppUpdateFiles(root: support.appendingPathComponent("SrtFlow/Updates", isDirectory: true))
    }

    var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("staged", isDirectory: true) }
    var stagedRecordURL: URL { root.appendingPathComponent("staged.json") }
    var installedNoteURL: URL { root.appendingPathComponent("installed.json") }

    func dmg(for feed: AppUpdateFeed) -> URL {
        downloads.appendingPathComponent("SkyCut-\(feed.version)-\(feed.dmgSHA256.prefix(12)).dmg")
    }

    func stagingFolder(for version: AppUpdateVersion) -> URL {
        staging.appendingPathComponent(version.description, isDirectory: true)
    }

    /// The folders, this user's only (0700).
    func makeFolders() throws {
        for folder in [root, downloads, staging] {
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
        try? FileManager.default.removeItem(at: stagedRecordURL)
    }

    func readInstalledNote() -> AppUpdateInstalledNote? {
        (try? Data(contentsOf: installedNoteURL)).flatMap(AppUpdateInstalledNote.init(data:))
    }

    func writeInstalledNote(_ note: AppUpdateInstalledNote) throws {
        try note.data().write(to: installedNoteURL, options: .atomic)
    }

    func removeInstalledNote() {
        try? FileManager.default.removeItem(at: installedNoteURL)
    }

    // MARK: Cleanup

    /// Every staged copy, download and record except the staged copy of `version` (nil: all of them).
    func removeStaged(except version: AppUpdateVersion?) {
        for folder in contents(of: staging) where folder.lastPathComponent != version?.description {
            try? FileManager.default.removeItem(at: folder)
        }
        if let record = readStaged(), record.feed.version == version { return }
        removeStagedRecord()
    }

    func removeDownloads(except kept: URL? = nil) {
        for file in contents(of: downloads) where file.standardizedFileURL.path != kept?.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// At launch, once the running version is known. The app the last swap replaced (left in staged/<running version>/ if the
    /// installer couldn't trash it) goes to the Trash; staged copies not newer than the running version, a staged copy no
    /// record names, a record whose copy is gone, and every download (a launch never resumes one) are removed. The newest
    /// staged copy the record names stays for the next quit.
    func cleanAtLaunch(running: AppUpdateVersion, trash: (URL) throws -> Void) {
        let record = readStaged().flatMap { record -> AppUpdateStagedRecord? in
            record.feed.version > running && FileManager.default.fileExists(atPath: record.appPath) ? record : nil
        }
        if record == nil { removeStagedRecord() }
        for folder in contents(of: staging) {
            let version = AppUpdateVersion(folder.lastPathComponent)
            if version == running {
                for item in contents(of: folder) { try? trash(item) }
                try? FileManager.default.removeItem(at: folder)
            } else if version == nil || version != record?.feed.version {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        removeDownloads()
    }

    func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }
}
