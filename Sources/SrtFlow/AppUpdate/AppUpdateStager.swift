import Darwin
import Foundation

// MARK: - From a verified download to a verified copy waiting for the next quit
//
// What it does: opens the downloaded image read-only where Finder doesn't show it (hdiutil attach -nobrowse at a private
// mount point under Updates/), finds the app at its top (the running app's bundle id), copies it into
// staged.noindex/<version>/ (Application Support, on the app's own volume: AppUpdateEligibility makes sure; `.noindex` so
// Spotlight never lists it), clears any download quarantine, has the copy verified (SkyCut: AppUpdateVerifier against the
// running app), closes the image and keeps only this staged copy and its record. Any failure removes what it made (through
// AppUpdateFiles.remove, inside the Updates folder only) and leaves the record of an earlier copy alone.
// Blocking (hdiutil, copying, hashing): AppUpdateWork.queue only. The checks inject the verification and run the rest
// against scratch folders and real images.
// What it doesn't: download (AppUpdateHTTP), install (AppUpdateInstaller).
// Rules: docs/architecture/app-updates.md "Downloading".

struct AppUpdateStager {
    var files: AppUpdateFiles
    /// The running app's bundle id: the image's app must carry it.
    var bundleIdentifier: String
    /// Throws unless the staged copy may install (SkyCut: AppUpdateVerifier.verify, staging checks).
    var verify: (_ copy: URL, _ feed: AppUpdateFeed) throws -> Void
    var hdiutil = "/usr/bin/hdiutil"

    /// The staged record of `feed`'s release, copied out of `dmg` under `appName` and verified.
    func stage(_ dmg: URL, feed: AppUpdateFeed, appName: String, asked: Bool) throws -> AppUpdateStagedRecord {
        try files.makeFolders()
        let mount = files.root.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let attach = AppUpdateTool.run(hdiutil, ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-noautofsck",
                                                 "-mountpoint", mount.path, dmg.path], timeout: 120)
        guard attach.status == 0 else {
            Self.removeMountPoint(mount, files: files)
            throw AppUpdateError("hdiutil attach: \(attach.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        defer { detach(mount) }
        let app = try findApp(in: mount)
        // Copied and checked in a folder of its own: a failure touches no staged copy, and only a verified one takes the
        // version's place (a folder name that isn't a version is removed at the next launch: AppUpdateLaunchFiles.clean).
        let incoming = files.staging.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        let folder = files.stagingFolder(for: feed.version)
        do {
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            let copy = incoming.appendingPathComponent(appName, isDirectory: true)
            try FileManager.default.copyItem(at: app, to: copy)
            Quarantine.removeFlagRecursively(at: copy)
            if Quarantine.isFlagged(atPath: copy.path) { throw AppUpdateError("the copy keeps the download quarantine") }
            try verify(copy, feed)
            files.remove(folder)
            try FileManager.default.moveItem(at: incoming, to: folder)
            let record = AppUpdateStagedRecord(feed: feed, appPath: folder.appendingPathComponent(appName).path, asked: asked)
            try files.writeStaged(record)
            files.removeStaged(except: feed.version)
            return record
        } catch {
            files.remove(incoming)
            throw error
        }
    }

    /// The one app at the image's top that carries the running app's bundle id.
    private func findApp(in mount: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        let apps = items.filter { item in
            guard item.pathExtension == "app",
                  (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
            return Bundle(url: item)?.bundleIdentifier == bundleIdentifier
        }
        guard apps.count == 1, let app = apps.first else {
            throw AppUpdateError("the image holds \(apps.count) apps with \(bundleIdentifier) at its top")
        }
        return app
    }

    /// Detaches the image (forced only if a normal detach fails: nothing of the person's is on it), then removes the empty
    /// mount point.
    private func detach(_ mount: URL) {
        if AppUpdateTool.run(hdiutil, ["detach", mount.path, "-quiet"], timeout: 60).status != 0 {
            _ = AppUpdateTool.run(hdiutil, ["detach", mount.path, "-quiet", "-force"], timeout: 60)
        }
        Self.removeMountPoint(mount, files: files)
    }

    /// Images a killed run left attached under Updates/ (its mount points): detached, their folders removed. A `mount-…` that
    /// is a link is never followed, and what it points to never detached: the link itself goes. At launch, for a copy that
    /// installs only (AppUpdateLaunchFiles).
    static func detachLeftovers(in files: AppUpdateFiles, hdiutil: String = "/usr/bin/hdiutil") {
        for item in files.contents(of: files.root) where item.lastPathComponent.hasPrefix("mount-") {
            if AppUpdateFiles.isLink(item) {
                files.remove(item)
                continue
            }
            if isMountPoint(item) { _ = AppUpdateTool.run(hdiutil, ["detach", item.path, "-quiet", "-force"], timeout: 60) }
            removeMountPoint(item, files: files)
        }
    }

    /// Removes the folder only when nothing is mounted on it and it is empty (never a mounted volume's contents).
    private static func removeMountPoint(_ folder: URL, files: AppUpdateFiles) {
        guard !isMountPoint(folder) else { return }
        files.removeEmptyFolder(folder)
    }

    /// A real folder (never a link: lstat) on another device than the folder holding it.
    static func isMountPoint(_ folder: URL) -> Bool {
        var here = stat(), parent = stat()
        guard lstat(folder.path, &here) == 0, (here.st_mode & S_IFMT) == S_IFDIR,
              stat(folder.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return here.st_dev != parent.st_dev
    }
}

/// Runs a system tool (hdiutil, spctl) to its end and returns its exit status and output. Blocking, so only on
/// AppUpdateWork.queue; a tool still running after `timeout` seconds is terminated (status -1).
enum AppUpdateTool {
    struct Result: Equatable {
        let status: Int32
        let output: String
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return Result(status: -1, output: "\(error)") }
        // Read while it runs: a full pipe would otherwise stop the tool.
        let output = AppUpdateToolOutput()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            read.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
        }
        _ = read.wait(timeout: .now() + 5)
        let text = String(decoding: output.data, as: UTF8.self)
        return Result(status: timedOut || process.isRunning ? -1 : process.terminationStatus, output: text)
    }
}

private final class AppUpdateToolOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var data: Data { lock.withLock { stored } }
    func set(_ data: Data) { lock.withLock { stored = data } }
}
