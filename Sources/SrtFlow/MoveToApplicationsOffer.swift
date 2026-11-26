import Foundation

// MARK: - Whether this launch offers to move SkyCut into the Applications folder
//
// What it does: the one rule for "SkyCut was opened straight from the installer disk". It asks only when the running bundle
// is on a read-only disk image (SkyCut double-clicked in the DMG window instead of dragged) or under an App Translocation
// path (a quarantined download macOS runs from a randomized read-only view). Never from /Applications or ~/Applications,
// never for a dev, check, smoke or render bundle (other bundle identifiers; dist/, .build, /tmp, temporary folders), never
// when the AI helper started it (SRTFLOW_AI_LAUNCH, set by skycut-mcp's `open`), never in a scripted run (SRTFLOW_* in the
// environment, CI). Connect AI asks the same rule without the environment (`runsFromInstallerDisk`). A pure function of
// `Facts`, so the checks feed it every case.
// What it doesn't: gather the facts (MoveToApplicationsLaunch, InstallerDisk), ask or move (MoveToApplicationsAlerts,
// AppBundleMover).
// Rules: docs/build/build-and-packaging.md "Installing from the DMG".

enum MoveToApplicationsOffer {
    /// The shipping app and the Beta. Dev, check, smoke and render bundles carry identifiers of their own.
    static let shippingBundleIdentifiers: Set<String> = ["com.srtflow.SrtFlow", "com.srtflow.SrtFlow.beta"]
    /// Set by the AI helper on a launch it makes (`open -g --env SRTFLOW_AI_LAUNCH=1`, Sources/SrtFlowMCP/AppConnection.swift):
    /// nobody may be there to answer, and the AI's call would wait behind the question.
    static let aiLaunchKey = "SRTFLOW_AI_LAUNCH"

    /// What the launch knows about itself.
    struct Facts: Equatable, Sendable {
        /// The running bundle's path as the system reports it (`Bundle.main.bundleURL`, standardized; symlinks unresolved,
        /// so `/private/var/…` and `/var/…` both occur).
        var bundlePath: String
        var bundleIdentifier: String?
        var homeDirectory: String
        /// The bundle sits on a read-only volume backed by a disk image (InstallerDisk.containing).
        var onReadOnlyDiskImage: Bool
        var environment: [String: String]
    }

    enum Decision: Equatable, Sendable {
        case offer(Location)
        case skip(Reason)

        var offers: Bool {
            if case .offer = self { return true }
            return false
        }
    }

    /// Where the launch runs from when it asks.
    enum Location: Equatable, Sendable {
        case diskImage
        case translocated
    }

    enum Reason: Equatable, Sendable {
        /// The AI helper started this launch in the background.
        case startedByAI
        /// A check, smoke, E2E or CI run.
        case scripted
        /// Not the shipping app or the Beta.
        case otherBundle
        /// A bare executable (`swift run`), not an `.app`.
        case notAppBundle
        /// Already in /Applications or ~/Applications.
        case installed
        /// A build or scratch folder: dist/, .build, /tmp, the temporary folders.
        case developmentFolder
        /// Anywhere else (a folder of the person's choosing, an external drive): theirs to decide.
        case elsewhere
    }

    static func decide(_ facts: Facts) -> Decision {
        if facts.environment[aiLaunchKey] != nil { return .skip(.startedByAI) }
        if isScripted(facts.environment) { return .skip(.scripted) }
        guard let identifier = facts.bundleIdentifier, shippingBundleIdentifiers.contains(identifier) else {
            return .skip(.otherBundle)
        }
        let path = trimmed(facts.bundlePath)
        guard path.hasSuffix(".app"), path.hasPrefix("/") else { return .skip(.notAppBundle) }
        if isInstalled(path, home: trimmed(facts.homeDirectory)) { return .skip(.installed) }
        // Before the scratch folders: macOS translocates into the temporary folder (/private/var/folders/…/T/AppTranslocation).
        if isTranslocated(path) { return .offer(.translocated) }
        if isDevelopmentFolder(path) { return .skip(.developmentFolder) }
        return facts.onReadOnlyDiskImage ? .offer(.diskImage) : .skip(.elsewhere)
    }

    /// Where the launch runs from would make it ask, whoever started it: Connect AI refuses then, since a client's config
    /// would name the helper on the installer disk, gone once the disk is ejected (AIClientSetup).
    static func runsFromInstallerDisk(_ facts: Facts) -> Bool {
        var located = facts
        located.environment = [:]
        return decide(located).offers
    }

    /// Checks, smokes and the E2E suite set SRTFLOW_* variables; CI sets CI. A Finder launch has neither.
    static func isScripted(_ environment: [String: String]) -> Bool {
        environment["CI"] != nil || environment.keys.contains { $0.hasPrefix("SRTFLOW_") }
    }

    private static func isInstalled(_ path: String, home: String) -> Bool {
        var folders = ["/Applications/", "/System/Volumes/Data/Applications/"]
        if home.hasPrefix("/"), home.count > 1 { folders.append(home + "/Applications/") }
        return folders.contains { path.hasPrefix($0) }
    }

    /// `/private/var/folders/<x>/<y>/T/AppTranslocation/<UUID>/d/SkyCut.app` (or the same under /var): a quarantined
    /// download run from where it was unpacked or mounted.
    static func isTranslocated(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(of: "AppTranslocation") else { return false }
        return (path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")) && components.count >= index + 3
    }

    /// dist/, .build, /tmp and the temporary folders (AppUpdateEligibility asks the same rule).
    static func isDevelopmentFolder(_ path: String) -> Bool {
        let components = Set(path.split(separator: "/").map(String.init))
        if !components.isDisjoint(with: [".build", "dist"]) { return true }
        return ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { path.hasPrefix($0) }
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
