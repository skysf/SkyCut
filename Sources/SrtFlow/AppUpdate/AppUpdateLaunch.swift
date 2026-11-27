import Foundation
import Security

// MARK: - What the updater learns once per launch, off the main thread
//
// What it does: gathers AppUpdateEligibility's facts about the running copy (its bundle, signing team, version, volume,
// which folders this user can write, whether it runs from inside the Updates folder, the home folder, the environment, the
// test hook) and hands the Updates folder to AppUpdateLaunchFiles, which reads and cleans it only for a copy that installs.
// Blocking file and code-signature work: run it with AppUpdateWork.run, never on the launch path itself (AppUpdater.start).
// What it doesn't: decide (AppUpdateEligibility), clean (AppUpdateLaunchFiles), keep state (AppUpdater).
// Rules: docs/architecture/app-updates.md "Who updates" and "Files".

enum AppUpdateLaunch {
    struct Reading: Sendable {
        let decision: AppUpdateEligibility.Decision
        let running: AppUpdateVersion?
        let files: AppUpdateLaunchFiles
    }

    static func read(files: AppUpdateFiles, source: AppUpdateFeed.Source) -> Reading {
        let facts = facts(files: files, source: source)
        let decision = AppUpdateEligibility.decide(facts)
        let running = facts.version.flatMap(AppUpdateVersion.init)
        let found = AppUpdateLaunchFiles.take(from: files, decision: decision, running: running, runningBundle: Bundle.main.bundleURL,
                                              trash: { item in try FileManager.default.trashItem(at: item, resultingItemURL: nil) })
        return Reading(decision: decision, running: running, files: found)
    }

    static func facts(files: AppUpdateFiles, source: AppUpdateFeed.Source) -> AppUpdateEligibility.Facts {
        let bundle = Bundle.main.bundleURL
        let folder = bundle.deletingLastPathComponent()
        let manager = FileManager.default
        // Nothing is created here (a Beta or a scripted run never touches the folder): the staging folder's volume is that
        // of its nearest existing ancestor.
        var staging = files.root
        while !manager.fileExists(atPath: staging.path), staging.pathComponents.count > 1 { staging.deleteLastPathComponent() }
        return AppUpdateEligibility.Facts(
            bundlePath: bundle.standardizedFileURL.path,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: signingTeam(),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: manager.homeDirectoryForCurrentUser.path,
            testHookIsLoopback: source.isLoopback,
            insideUpdatesFolder: files.holds(bundle),
            onReadOnlyDiskImage: InstallerDisk.containing(bundle) != nil,
            folderWritable: manager.isWritableFile(atPath: folder.path),
            bundleWritable: manager.isWritableFile(atPath: bundle.path),
            volumeSupportsSwap: (try? folder.resourceValues(forKeys: [.volumeSupportsSwapRenamingKey]))?.volumeSupportsSwapRenaming == true,
            stagingOnSameVolume: sameVolume(folder, staging))
    }

    /// The running code's signing team (nil for ad-hoc or unsigned code); the system validated the running code at launch.
    static func signingTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func sameVolume(_ first: URL, _ second: URL) -> Bool {
        func volume(_ url: URL) -> AnyObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as AnyObject?
        }
        guard let a = volume(first), let b = volume(second) else { return false }
        return a.isEqual(b)
    }
}
