import Foundation

// MARK: - Is this downloaded copy a newer SkyCut, from us, notarized by Apple?
//
// What it does: the checks a copy passes before it may ever install, each one a refusal on its own:
// - its Info.plist: the running app's bundle id, the feed's version (newer than the running one) and build;
// - its code signature, strictly, against the *running* app's designated requirement (for the Developer ID: the same
//   identifier and team), with `notarized` in the same requirement (AppBundleSignature.verify(_:matchesNotarized:));
// - Gatekeeper's own verdict (`spctl --assess --type execute`): accepted, as «Notarized Developer ID». On a Mac where
//   Gatekeeper's assessments are turned off it can only say "accepted" (overridden); the notarized requirement above
//   still has to pass.
// When staging: all three, the network allowed (macOS may ask Apple whether the ticket still stands). At quit
// (AppUpdateInstaller): the first two, offline, so a copy damaged or changed since it was staged never goes in.
// What it doesn't: copy, open images or swap (AppUpdateStager, AppUpdateInstaller). Blocking: AppUpdateWork.queue, or
// the main thread at quit.
// Rules: docs/architecture/app-updates.md "Verifying".

enum AppUpdateVerifier {
    /// Every check, for a copy of `feed`'s release, against the running app (`runningApp`, version `running`).
    static func verify(_ app: URL, feed: AppUpdateFeed, runningApp: URL, running: AppUpdateVersion, atQuit: Bool) throws {
        guard let identifier = Bundle(url: runningApp)?.bundleIdentifier else {
            throw AppUpdateError("the running app has no bundle identifier")
        }
        try checkInfo(of: app, feed: feed, bundleIdentifier: identifier, running: running)
        do {
            try AppBundleSignature.verify(app, matchesNotarized: runningApp, network: !atQuit)
        } catch {
            throw AppUpdateError("code signature or notarization: \(error.localizedDescription)")
        }
        if !atQuit { try gatekeeper(app) }
    }

    /// The copy's Info.plist names the running app and exactly the feed's release, newer than the running version.
    static func checkInfo(of app: URL, feed: AppUpdateFeed, bundleIdentifier: String, running: AppUpdateVersion) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppUpdateError("no readable Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw AppUpdateError("bundle id \(info["CFBundleIdentifier"] ?? "none"), not \(bundleIdentifier)")
        }
        guard let short = info["CFBundleShortVersionString"] as? String, AppUpdateVersion(short) == feed.version else {
            throw AppUpdateError("version \(info["CFBundleShortVersionString"] ?? "none"), the feed says \(feed.version)")
        }
        guard feed.version > running else { throw AppUpdateError("version \(feed.version) is not newer than \(running)") }
        guard info["CFBundleVersion"] as? String == feed.build else {
            throw AppUpdateError("build \(info["CFBundleVersion"] ?? "none"), the feed says \(feed.build)")
        }
    }

    /// Gatekeeper's assessment of the copy, as `spctl` reports it (read-only; changes nothing).
    static func gatekeeper(_ app: URL) throws {
        let result = AppUpdateTool.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path], timeout: 120)
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
