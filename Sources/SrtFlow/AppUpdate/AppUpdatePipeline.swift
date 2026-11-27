import Foundation
import os

// MARK: - One release, from the feed to a verified copy waiting for the next quit
//
// What it does: the background work behind a `.download` effect, every blocking step on AppUpdateWork's queue:
// 1. a copy of this release an earlier run staged (the record names it where the stager puts it) is taken as it is;
// 2. downloads of other DMGs go; a finished download of this one kept from an earlier run (a quit during staging, say) is
//    used if its size and SHA-256 still match the feed, else removed;
// 3. otherwise the DMG is downloaded (AppUpdateHTTP: never more bytes than the feed says, then its size and SHA-256);
// 4. it is staged (AppUpdateStager: read-only image, copy, verification). The DMG stays until the update is installed or
//    the feed names another DMG or nothing newer (AppUpdateFiles, AppUpdateLaunchFiles); a DMG that fails its check or its
//    staging is removed.
// The outcome tells a download that didn't complete (offline, a server error, stopped: not counted) from one that completed
// and then failed (counted in the retry record, AppUpdateRetryRecord). Cancelling the task stops a download; staging, once
// begun, runs to its end, and a quit during it leaves the DMG for the next launch.
// What it doesn't: decide when (AppUpdateState, AppUpdater), verify (the stager's `verify`: AppUpdateVerifier in SkyCut).
// Rules: docs/architecture/app-updates.md "Downloading and verifying".

/// What one run of the pipeline came to.
enum AppUpdateFetchOutcome: Equatable, Sendable {
    /// Verified and staged (or taken from an earlier run's staged copy).
    case staged
    /// The download didn't complete (offline, a server error, stopped): nothing is known about the DMG.
    case notDownloaded
    /// The download completed, then failed its check (size, SHA-256) or its staging: the DMG is removed.
    case rejected

    /// The event the state machine takes for this outcome of `feed`, finished at `now`.
    func event(for feed: AppUpdateFeed, at now: Date) -> AppUpdateEvent {
        switch self {
        case .staged: return .staged(feed)
        case .notDownloaded: return .downloadFailed
        case .rejected: return .downloadRejected(feed, at: now)
        }
    }
}

enum AppUpdatePipeline {
    private static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "update")

    /// Downloads (or takes what an earlier run left), checks and stages `feed`'s release with `stager`, the copy named
    /// `appName`. `asked`: Download and Install was clicked (the copy then installs at quit with auto install off).
    static func run(_ feed: AppUpdateFeed, files: AppUpdateFiles, stager: AppUpdateStager, appName: String, asked: Bool,
                    progress: @escaping @Sendable (Double) -> Void) async -> AppUpdateFetchOutcome {
        let adopted = await AppUpdateWork.run { () -> Bool in
            guard var record = files.readStaged(), record.feed.isSameRelease(as: feed), let copy = files.stagedCopy(of: record),
                  FileManager.default.fileExists(atPath: copy.path) else { return false }
            if asked, !record.asked {
                record.asked = true
                try? files.writeStaged(record)
            }
            return true
        }
        if adopted { return .staged }
        let dmg = files.dmg(for: feed)
        let kept = await AppUpdateWork.run { () -> Result<Bool, Error> in
            Result {
                try files.makeFolders()
                files.removeDownloads(except: dmg)
                return files.keptDownloadMatches(dmg, feed: feed)
            }
        }
        guard case .success(let downloaded) = kept else {
            log.notice("no downloads folder: \(String(describing: kept), privacy: .public)")
            return .notDownloaded
        }
        if !downloaded {
            do {
                try await AppUpdateHTTP.download(feed, into: files, progress: progress)
            } catch let mismatch as AppUpdateDMGMismatch {
                log.notice("download rejected: \(mismatch.description, privacy: .public)")
                return .rejected
            } catch {
                log.notice("download failed: \(error.localizedDescription, privacy: .public)")
                return .notDownloaded
            }
        }
        if Task.isCancelled { return .notDownloaded }
        let staged = await AppUpdateWork.run { () -> Result<AppUpdateStagedRecord, Error> in
            Result { try stager.stage(dmg, feed: feed, appName: appName, asked: asked) }
        }
        guard case .failure(let error) = staged else { return .staged }
        log.notice("staging failed: \(error.localizedDescription, privacy: .public)")
        await AppUpdateWork.run { files.remove(dmg) }
        return .rejected
    }
}
