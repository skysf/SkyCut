import Foundation
import Security

// MARK: - Is this downloaded copy a newer SkyCut, from us, notarized by Apple?
//
// What it does: the checks a copy passes before it may ever install, each one a refusal on its own:
// - its Info.plist: the running app's bundle id, the feed's version (newer than the running one) and build;
// - its code signature, strictly, against the *running* app's designated requirement (for the Developer ID: the same
//   identifier and team), with `notarized` in the same requirement (AppBundleSignature.notarizedRequirement);
// - Gatekeeper's own verdict (`spctl --assess --type execute`): accepted, as «Notarized Developer ID». On a Mac where
//   Gatekeeper's assessments are turned off it can only say "accepted" (overridden); the notarized requirement above
//   still has to pass.
// When staging: all three, the network allowed (macOS may ask Apple whether the ticket still stands). At quit
// (AppUpdateInstaller): the first two, offline, so a copy damaged or changed since it was staged never goes in.
// A problem with the running app itself (moved, renamed, its bundle or signature unreadable) is not the copy's fault: it
// throws AppUpdateRunningAppError, and at quit the copy stays for the next one.
// What it doesn't: copy, open images or swap (AppUpdateStager, AppUpdateInstaller). Blocking: AppUpdateWork.queue, or
// the main thread at quit.
// Rules: docs/architecture/app-updates.md "Verifying".

/// The running app itself can't be read (moved, renamed, its bundle or signature unreadable): not the staged copy's fault.
struct AppUpdateRunningAppError: LocalizedError, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

/// What the updater reads from an app bundle's Info.plist (nil: no readable Info.plist).
struct AppUpdateBundleInfo: Equatable, Sendable {
    let identifier: String?
    /// CFBundleShortVersionString as a release version (nil: not a plain x.y.z).
    let version: AppUpdateVersion?
    let shortVersion: String?
    let build: String?

    init?(app: URL) {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        identifier = info["CFBundleIdentifier"] as? String
        shortVersion = info["CFBundleShortVersionString"] as? String
        version = shortVersion.flatMap(AppUpdateVersion.init)
        build = info["CFBundleVersion"] as? String
    }
}

enum AppUpdateVerifier {
    /// The steps that ask the system: the running app's requirement for a copy (its designated requirement with `notarized`)
    /// and Gatekeeper's verdict. SkyCut uses these; the checks replace them to fail one step on its own.
    struct Steps {
        var requirement: (_ runningApp: URL) throws -> SecRequirement = { try AppBundleSignature.notarizedRequirement(of: $0) }
        var gatekeeper: (_ app: URL) -> AppUpdateTool.Result = { app in
            AppUpdateTool.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path], timeout: 120)
        }
    }

    /// Every check, for a copy of `feed`'s release, against the running app (`runningApp`, version `running`).
    static func verify(_ app: URL, feed: AppUpdateFeed, runningApp: URL, running: AppUpdateVersion, atQuit: Bool,
                       steps: Steps = Steps()) throws {
        guard let identifier = AppUpdateBundleInfo(app: runningApp)?.identifier else {
            throw AppUpdateRunningAppError("the running app has no readable bundle identifier at \(runningApp.path)")
        }
        let requirement: SecRequirement
        do {
            requirement = try steps.requirement(runningApp)
        } catch {
            throw AppUpdateRunningAppError("the running app's designated requirement: \(error.localizedDescription)")
        }
        try checkInfo(of: app, feed: feed, bundleIdentifier: identifier, running: running)
        do {
            try AppBundleSignature.verify(app, satisfies: requirement, network: !atQuit)
        } catch {
            throw AppUpdateError("code signature or notarization: \(error.localizedDescription)")
        }
        if !atQuit { try gatekeeper(app, steps: steps) }
    }

    /// The copy's Info.plist names the running app and exactly the feed's release, newer than the running version.
    static func checkInfo(of app: URL, feed: AppUpdateFeed, bundleIdentifier: String, running: AppUpdateVersion) throws {
        guard let info = AppUpdateBundleInfo(app: app) else { throw AppUpdateError("no readable Info.plist") }
        guard info.identifier == bundleIdentifier else {
            throw AppUpdateError("bundle id \(info.identifier ?? "none"), not \(bundleIdentifier)")
        }
        guard info.version == feed.version else {
            throw AppUpdateError("version \(info.shortVersion ?? "none"), the feed says \(feed.version)")
        }
        guard feed.version > running else { throw AppUpdateError("version \(feed.version) is not newer than \(running)") }
        guard info.build == feed.build else {
            throw AppUpdateError("build \(info.build ?? "none"), the feed says \(feed.build)")
        }
    }

    /// Gatekeeper's assessment of the copy, as `spctl` reports it (read-only; changes nothing).
    static func gatekeeper(_ app: URL, steps: Steps = Steps()) throws {
        let result = steps.gatekeeper(app)
        guard gatekeeperAccepts(status: result.status, output: result.output) else {
            throw AppUpdateError("Gatekeeper: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Accepted (exit 0) as notarized Developer ID code, or accepted because assessments are off on this Mac.
    static func gatekeeperAccepts(status: Int32, output: String) -> Bool {
        guard status == 0 else { return false }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("source=Notarized Developer ID") { return true }
        return lines.contains { $0.hasPrefix("override=") && $0.contains("disabled") }
    }
}
