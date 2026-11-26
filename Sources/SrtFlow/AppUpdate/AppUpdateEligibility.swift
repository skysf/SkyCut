import Foundation

// MARK: - Who updates itself, and who is only told about a new version
//
// What it does: the one rule, a pure function of `Facts` (like MoveToApplicationsOffer.decide), so the checks feed it every
// case. Only the release app updates: bundle id com.srtflow.SrtFlow, signed by the pinned Developer ID team, a plain x.y.z
// version, running from a folder it can replace itself in. A release app that can't (on the installer disk, translocated,
// anywhere inside Desktop, Documents, Downloads, iCloud Drive or third-party cloud storage (privacy-protected: the swap
// would ask for access from inside the quit), a folder or bundle this user can't write, a volume without atomic swaps, the
// staging folder on another volume) is only told, with the download page. Never: SkyCut Beta, ad-hoc and source builds,
// anything in dist/, .build, /tmp or a scratch folder, a copy running from inside the Updates folder (a staged copy, an
// image mounted there; through the Data volume's spelling too), and a scripted run (CI or SRTFLOW_* in the environment:
// checks, smokes, E2E) unless it points the test hook at a loopback feed. A launch the AI helper made (SRTFLOW_AI_LAUNCH)
// is a normal launch here.
// What it doesn't: gather the facts (AppUpdateLaunch), check, download or install.
// Rules: docs/architecture/app-updates.md "Who updates".

enum AppUpdateEligibility {
    static let releaseBundleIdentifier = AppUpdateFeed.bundleIdentifier
    /// The Developer ID team that signs releases (scripts/signing/common.sh, SIGNING_TEAM_ID; checks/app-update-wiring.sh
    /// keeps the two the same).
    static let releaseTeam = "26TVX3S9FR"
    /// Privacy-protected folders under the home folder (Files and Folders): a copy anywhere inside only tells. iCloud Drive
    /// is Library/Mobile Documents; third-party cloud storage (File Provider: Dropbox, OneDrive, …) is Library/CloudStorage.
    static let protectedFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]

    struct Facts: Equatable, Sendable {
        /// `Bundle.main.bundleURL`, standardized.
        var bundlePath: String
        var bundleIdentifier: String?
        /// The running code's signing team (nil for ad-hoc and unsigned code).
        var teamIdentifier: String?
        /// CFBundleShortVersionString.
        var version: String?
        var environment: [String: String]
        /// This user's home folder (for the privacy-protected folders).
        var homeDirectory: String
        /// The feed comes from the test hook on this Mac (AppUpdateFeed.Source.isLoopback).
        var testHookIsLoopback: Bool
        /// The bundle runs from inside the Updates folder (AppUpdateFiles.holds): a staged copy, an image mounted there.
        var insideUpdatesFolder: Bool
        /// The bundle sits on a read-only disk image (InstallerDisk.containing).
        var onReadOnlyDiskImage: Bool
        /// This user can write the folder that holds the bundle (to swap a new copy in).
        var folderWritable: Bool
        /// This user can write the bundle itself (moving a folder to another folder rewrites its "..").
        var bundleWritable: Bool
        /// The bundle's volume can swap two names atomically (renamex_np RENAME_SWAP).
        var volumeSupportsSwap: Bool
        /// The staging folder (Application Support/SrtFlow/Updates) is on the bundle's volume: the swap is a rename.
        var stagingOnSameVolume: Bool
    }

    enum Decision: Equatable, Sendable {
        /// Checks, downloads, verifies and installs at quit.
        case updates
        /// Checks and tells (the New Version pill with the download page); never downloads or installs.
        case notifyOnly(CannotUpdate)
        /// Never checks: no menu item, no Settings section.
        case never(Never)

        var checks: Bool {
            if case .never = self { return false }
            return true
        }
    }

    /// Why a release app can't replace itself.
    enum CannotUpdate: Equatable, Sendable {
        case installerDisk, translocated, protectedFolder, folderNotWritable, bundleNotWritable, volumeCannotSwap,
             stagingOnOtherVolume
    }

    enum Never: Equatable, Sendable {
        /// A check, smoke, E2E or CI run (without a loopback test feed).
        case scripted
        /// SkyCut Beta, a dev, check, smoke or render bundle.
        case otherBundle
        /// A bare executable (`swift run`).
        case notAppBundle
        /// Ad-hoc, unsigned or signed by anyone else (a build from source).
        case notReleaseSignature
        /// Not a plain x.y.z version (a local or development build).
        case developmentVersion
        /// dist/, .build, /tmp, the temporary folders.
        case developmentFolder
        /// A copy running from inside the Updates folder: never checks, downloads, installs or cleans up.
        case updatesFolder
    }

    static func decide(_ facts: Facts) -> Decision {
        if isScripted(facts.environment), !facts.testHookIsLoopback { return .never(.scripted) }
        guard facts.bundleIdentifier == releaseBundleIdentifier else { return .never(.otherBundle) }
        let path = trimmed(facts.bundlePath)
        guard path.hasPrefix("/"), path.hasSuffix(".app") else { return .never(.notAppBundle) }
        if facts.insideUpdatesFolder { return .never(.updatesFolder) }
        guard facts.teamIdentifier == releaseTeam else { return .never(.notReleaseSignature) }
        guard let version = facts.version, AppUpdateVersion(version) != nil else { return .never(.developmentVersion) }
        // Before the scratch folders: macOS translocates into the temporary folder (as MoveToApplicationsOffer does).
        if MoveToApplicationsOffer.isTranslocated(path) { return .notifyOnly(.translocated) }
        if MoveToApplicationsOffer.isDevelopmentFolder(path) { return .never(.developmentFolder) }
        if facts.onReadOnlyDiskImage { return .notifyOnly(.installerDisk) }
        if isPrivacyProtected(path, home: facts.homeDirectory) { return .notifyOnly(.protectedFolder) }
        guard facts.folderWritable else { return .notifyOnly(.folderNotWritable) }
        guard facts.bundleWritable else { return .notifyOnly(.bundleNotWritable) }
        guard facts.volumeSupportsSwap else { return .notifyOnly(.volumeCannotSwap) }
        guard facts.stagingOnSameVolume else { return .notifyOnly(.stagingOnOtherVolume) }
        return .updates
    }

    /// MoveToApplicationsOffer's rule (CI, SRTFLOW_*), except the AI helper's launch marker: Claude or Codex opening SkyCut
    /// is the person's own SkyCut.
    static func isScripted(_ environment: [String: String]) -> Bool {
        var environment = environment
        environment[MoveToApplicationsOffer.aiLaunchKey] = nil
        return MoveToApplicationsOffer.isScripted(environment)
    }

    /// Anywhere inside Desktop, Documents, Downloads, iCloud Drive or CloudStorage of `home` (as reached through the Data
    /// volume too), letter case ignored.
    static func isPrivacyProtected(_ path: String, home: String) -> Bool {
        let home = trimmed(home)
        guard home.hasPrefix("/"), home.count > 1 else { return false }
        let path = path.lowercased()
        return [home, "/System/Volumes/Data" + home].contains { root in
            protectedFolders.contains { path.hasPrefix((root + "/" + $0 + "/").lowercased()) }
        }
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
