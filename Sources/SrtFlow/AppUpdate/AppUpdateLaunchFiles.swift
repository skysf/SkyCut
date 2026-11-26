import Foundation

// MARK: - What a launch takes from the Updates folder, and the cleanup after an update
//
// What it does: once per launch, and only for a copy that installs (`decision == .updates`: a copy that only tells, never
// updates, or runs from inside the Updates folder touches nothing there; nor does any copy while the Updates folder itself
// is a link): reads the installer's marker once (then removes it), detaches images a killed run left attached (never
// through a link), cleans what the last update left, and reads the staged and retry records. The cleanup first empties
// removing.noindex/ (what a crash left mid-deletion), then, in staged.noindex/: an app older than the running one, in the
// folder of a newer version (where a swap leaves the copy it replaced, when the installer couldn't trash it), is the
// person's old app and goes to the Trash;
// the staged copy the record names, newer than the running app, stays for the next quit; anything else is our own download
// (a copy not newer than the running app, one no record names, an unfinished incoming folder, a link) and is deleted, never
// sent to the Trash; the folder holding the bundle this process runs from is never touched. In downloads/: a DMG of a
// release newer than the running one stays (a finished download, used instead of downloading again: AppUpdatePipeline);
// everything else goes.
// What it doesn't: gather the launch's facts (AppUpdateLaunch), decide (AppUpdateEligibility, AppUpdateState).
// Rules: docs/architecture/app-updates.md "Files".

struct AppUpdateLaunchFiles: Equatable, Sendable {
    var staged: AppUpdateStagedRecord?
    var installed: AppUpdateInstalledNote?
    var retry: AppUpdateRetryRecord?

    /// The launch's reading of the Updates folder, after its cleanup; nothing at all unless this copy installs.
    static func take(from files: AppUpdateFiles, decision: AppUpdateEligibility.Decision, running: AppUpdateVersion?,
                     runningBundle: URL, hdiutil: String = "/usr/bin/hdiutil",
                     trash: (URL) throws -> Void) -> AppUpdateLaunchFiles {
        guard decision == .updates, let running else { return AppUpdateLaunchFiles() }
        // The Updates folder itself a link (made by hand): never followed, nothing read, detached or cleaned there.
        guard !files.rootIsLink else { return AppUpdateLaunchFiles() }
        let installed = files.readInstalledNote()
        files.removeInstalledNote()
        AppUpdateStager.detachLeftovers(in: files, hdiutil: hdiutil)
        clean(files, running: running, runningBundle: runningBundle, trash: trash)
        return AppUpdateLaunchFiles(staged: files.readStaged(), installed: installed, retry: files.readRetry())
    }

    /// The cleanup after an update (see above). `trash` gets only an app older than the running one.
    static func clean(_ files: AppUpdateFiles, running: AppUpdateVersion, runningBundle: URL, trash: (URL) throws -> Void) {
        files.emptyRemovalFolder()
        for folder in [files.staging, files.downloads] where AppUpdateFiles.isLink(folder) { files.remove(folder) }
        let own = AppUpdateFiles.resolvedPath(runningBundle)
        let record = files.readStaged().flatMap { record -> AppUpdateStagedRecord? in
            guard record.feed.version > running, let copy = files.stagedCopy(of: record),
                  FileManager.default.fileExists(atPath: copy.path) else { return nil }
            return record
        }
        if record == nil { files.removeStagedRecord() }
        let kept = record.flatMap(files.stagedCopy(of:)).map(AppUpdateFiles.resolvedPath)
        for folder in files.contents(of: files.staging) {
            // The folder holding the bundle this process runs from (a staged copy started by its path): left as it is.
            if contains(AppUpdateFiles.resolvedPath(folder), own) { continue }
            guard let folderVersion = AppUpdateVersion(folder.lastPathComponent), !AppUpdateFiles.isLink(folder) else {
                files.remove(folder)
                continue
            }
            var emptied = true
            for item in files.contents(of: folder) {
                if AppUpdateFiles.resolvedPath(item) == kept {
                    emptied = false
                } else if isReplacedApp(item, in: folderVersion, files: files, running: running) {
                    // The person's old app: to the Trash; if that fails, the next launch tries again.
                    if (try? trash(item)) == nil { emptied = false }
                } else {
                    files.remove(item)
                }
            }
            if emptied { files.remove(folder) }
        }
        for file in files.contents(of: files.downloads) where !keepsAtLaunch(file, running: running) {
            files.remove(file)
        }
    }

    /// The copy a swap replaced: a real app bundle (no link) inside the Updates folder, older than the running version and
    /// than the version its folder is named for (a staged copy of its own version is our download, never the person's app).
    static func isReplacedApp(_ item: URL, in folderVersion: AppUpdateVersion, files: AppUpdateFiles, running: AppUpdateVersion) -> Bool {
        guard item.pathExtension == "app", !AppUpdateFiles.isLink(item), files.holds(item),
              let version = AppUpdateBundleInfo(app: item)?.version else { return false }
        return version < running && version < folderVersion
    }

    /// A finished download kept for the next check: a plain file named SkyCut-<version>-<12 hex>.dmg (AppUpdateFiles.dmg),
    /// of a release newer than the running one.
    static func keepsAtLaunch(_ file: URL, running: AppUpdateVersion) -> Bool {
        let name = file.lastPathComponent
        guard name.hasPrefix("SkyCut-"), name.hasSuffix(".dmg"), !AppUpdateFiles.isLink(file),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
        let middle = name.dropFirst("SkyCut-".count).dropLast(".dmg".count)
        guard let dash = middle.lastIndex(of: "-") else { return false }
        let hash = middle[middle.index(after: dash)...]
        guard hash.count == 12, hash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }),
              let version = AppUpdateVersion(String(middle[..<dash])) else { return false }
        return version > running
    }

    /// `path` is `folder` or lies inside it.
    private static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }
}
