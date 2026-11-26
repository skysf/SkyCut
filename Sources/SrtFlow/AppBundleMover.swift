import Foundation

// MARK: - Moving the running app bundle into the Applications folder
//
// What it does: copies the running bundle (the disk image's, or the translocated view of a download) into a new folder on
// the destination's volume, clears the download quarantine on the copy (macOS could otherwise translocate the moved copy,
// and it would ask again), checks the copy's signature against the original, moves an app of the same name that
// is there and not running to the Trash, and renames the copy into place. Each step that fails stops the move and leaves
// the destination as it was: an app already moved to the Trash is put back. An app of that name that is running is never
// touched: asked before the copy and again right before the Trash (an AI client may start it meanwhile). A folder this
// user can't write is reported, never elevated (no administrator rights are asked for).
// What it doesn't: ask (MoveToApplicationsAlerts), reopen or eject (MoveToApplicationsLaunch, InstallerDisk). Every outside
// effect is injected, so the checks run it against scratch folders; SkyCut's own is MoveToApplicationsLaunch.mover.
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

struct AppBundleMover {
    /// Where the app goes: /Applications for SkyCut, a scratch folder in the checks.
    var destinationFolder: URL
    /// Is the app itself open from the bundle at this path? Asked twice, the second time right before the Trash, off the main
    /// thread (SkyCut: RunningBundleProbe, live; a helper running from the bundle doesn't count, and trashing under it is
    /// harmless: see that file).
    var isRunning: (URL) -> Bool
    /// Moves an item to the Trash and says where it went (SkyCut: the person's Trash; the checks: a scratch folder).
    var trash: (URL) throws -> URL
    /// A new, empty folder on the destination's volume to make the copy in, removed afterwards.
    var makeStagingFolder: () throws -> URL
    /// Throws unless the copy is the original (AppBundleSignature.verify).
    var verify: (_ copy: URL, _ original: URL) throws -> Void = AppBundleSignature.verify(_:matches:)
    var copy: (_ original: URL, _ copy: URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    /// Puts the checked copy at the destination: a rename, the staging folder being on the same volume.
    var install: (_ copy: URL, _ destination: URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    /// Puts an app moved to the Trash back where it was, after a failed install.
    var restore: (_ trashed: URL, _ destination: URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    enum Step: String, Equatable, Sendable {
        case copy, quarantine, signature, trash, install
    }

    enum Outcome: Equatable, Sendable {
        /// The checked copy is in place at this URL.
        case moved(URL)
        /// An app of that name is there and running: nothing was touched.
        case runningAtDestination(URL)
        /// This user can't write the folder: nothing was touched.
        case destinationNotWritable(URL)
        /// A step failed and the destination is as it was: an app moved to the Trash was put back. Only when that failed
        /// too is `oldAppInTrash` where it is now.
        case failed(Step, detail: String?, oldAppInTrash: URL?)
    }

    /// `/Applications/<the bundle's own name>`: SkyCut Beta keeps its name.
    func destination(for original: URL) -> URL {
        destinationFolder.appendingPathComponent(original.lastPathComponent, isDirectory: true)
    }

    /// Something of that name is at the destination (an app to replace), a dangling link included.
    func hasItem(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func move(_ original: URL) -> Outcome {
        let destination = destination(for: original)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationFolder.path, isDirectory: &isFolder), isFolder.boolValue,
              FileManager.default.isWritableFile(atPath: destinationFolder.path) else {
            return .destinationNotWritable(destinationFolder)
        }
        let replacing = hasItem(at: destination)
        if replacing, isRunning(destination) { return .runningAtDestination(destination) }
        guard Self.path(original) != Self.path(destination) else { return .failed(.copy, detail: nil, oldAppInTrash: nil) }

        let staging: URL
        do { staging = try makeStagingFolder() } catch { return .failed(.copy, detail: Self.describe(error), oldAppInTrash: nil) }
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(original.lastPathComponent, isDirectory: true)
        if let failure = prepare(original, at: staged) { return failure }

        var trashed: URL?
        if replacing {
            // Again, right before the Trash: the copy took time, and an AI client may have started the app there meanwhile.
            if isRunning(destination) { return .runningAtDestination(destination) }
            do { trashed = try trash(destination) } catch {
                return .failed(.trash, detail: Self.describe(error), oldAppInTrash: nil)
            }
        }
        do {
            try install(staged, destination)
        } catch {
            let detail = Self.describe(error)
            guard let trashed else { return .failed(.install, detail: detail, oldAppInTrash: nil) }
            do {
                try restore(trashed, destination)
                return .failed(.install, detail: detail, oldAppInTrash: nil)
            } catch {
                return .failed(.install, detail: detail, oldAppInTrash: trashed)
            }
        }
        return .moved(destination)
    }

    /// Copy, clear the quarantine, check the signature: nil when the staged copy is ready to go in.
    private func prepare(_ original: URL, at staged: URL) -> Outcome? {
        do { try copy(original, staged) } catch {
            return .failed(.copy, detail: Self.describe(error), oldAppInTrash: nil)
        }
        // A copy of a quarantined disk image's app carries `com.apple.quarantine` (measured: 0281 on every item). Left
        // on, macOS could translocate the moved copy, and it would then ask again on every launch.
        Quarantine.removeFlagRecursively(at: staged)
        if Quarantine.isFlagged(atPath: staged.path) { return .failed(.quarantine, detail: nil, oldAppInTrash: nil) }
        do { try verify(staged, original) } catch {
            return .failed(.signature, detail: Self.describe(error), oldAppInTrash: nil)
        }
        return nil
    }

    private static func path(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func describe(_ error: Error) -> String {
        error.localizedDescription
    }
}
