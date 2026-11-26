import Darwin
import Foundation

// MARK: - Putting the staged copy in place of the running app, at quit: one atomic swap
//
// What it does: at every quit while an update is staged (applicationWillTerminate: the quit flow has already saved and asked
// about every project), and so also on Restart and Update:
// 1. the staged copy is checked once more, offline (AppUpdateVerifier at quit): a copy damaged or changed since it was
//    staged is removed and never goes in;
// 2. nothing else may run the app from the destination bundle (never two SkyCut instances);
// 3. the installed marker is written (so even a kill right after the swap shows Updated next time);
// 4. the two names are swapped in one call, renamex_np(staged, destination, RENAME_SWAP) on the same volume: the
//    destination is the whole old app until that instant and the whole new app from it on, never missing or half-written;
// 5. only then the replaced copy (now at the staged path) goes to the Trash; if it can't, the next launch tries again.
// Any failure before the swap leaves the old app where it was, working, and (but for a broken copy) the update staged for
// the next quit. A quit during logout or shutdown can at worst skip it. No administrator rights, ever: a folder this user
// can't write never gets here (AppUpdateEligibility). An AI client's skycut-mcp running from the old bundle keeps working
// (a rename under it; it opens the app at the same path next, RunningBundleProbe).
// What it doesn't: decide when (AppUpdater), relaunch (AppUpdateRestart). Every outside effect is injected: the checks run
// it against scratch folders, and kill a loop of swaps at random instants.
// Rules: docs/architecture/app-updates.md "Installing".

struct AppUpdateInstaller {
    /// The running app's bundle (/Applications/SkyCut.app): what the new copy replaces.
    var destination: URL
    var files: AppUpdateFiles
    /// Throws unless the staged copy may go in (SkyCut: AppUpdateVerifier.verify at quit).
    var verify: (_ staged: URL, _ feed: AppUpdateFeed) throws -> Void
    /// Another process runs the app itself from this bundle (SkyCut: RunningBundleProbe, this process excepted).
    var othersRunning: (_ bundle: URL) -> Bool
    /// The replaced copy to the Trash (SkyCut: the person's Trash).
    var trash: (_ item: URL) throws -> Void
    var swap: (_ staged: URL, _ destination: URL) throws -> Void = AppUpdateInstaller.exchange

    enum Outcome: Equatable {
        case installed(AppUpdateInstalledNote)
        /// No staged copy, or none newer than the running version (leftovers removed).
        case nothingStaged
        /// Another SkyCut runs from the bundle: left staged for the next quit.
        case otherInstanceRunning
        /// The staged copy failed its check: removed, the old app untouched.
        case copyRejected(String)
        /// The swap failed: the old app untouched, the update still staged.
        case swapFailed(String)
    }

    func install(_ record: AppUpdateStagedRecord?, running: AppUpdateVersion) -> Outcome {
        guard let record, record.feed.version > running, FileManager.default.fileExists(atPath: record.appPath) else {
            files.removeStaged(except: nil)
            return .nothingStaged
        }
        let staged = URL(fileURLWithPath: record.appPath, isDirectory: true)
        do {
            try verify(staged, record.feed)
        } catch {
            files.removeStaged(except: nil)
            return .copyRejected("\(error.localizedDescription)")
        }
        if othersRunning(destination) { return .otherInstanceRunning }
        let note = AppUpdateInstalledNote(from: running, to: record.feed.version, notes: record.feed.notes)
        try? files.writeInstalledNote(note)
        do {
            try swap(staged, destination)
        } catch {
            files.removeInstalledNote()
            return .swapFailed("\(error.localizedDescription)")
        }
        files.removeStagedRecord()
        // `staged` now names the old app: to the Trash only now that the new one is in place.
        if (try? trash(staged)) != nil { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        return .installed(note)
    }

    /// Swaps two names on one volume in one step (renamex_np RENAME_SWAP): each path names a whole bundle before and after,
    /// at every instant. Fails, changing nothing, across volumes or where the volume can't swap.
    static func exchange(_ staged: URL, _ destination: URL) throws {
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw AppUpdateError("renamex_np: \(String(cString: strerror(errno)))")
        }
    }
}
