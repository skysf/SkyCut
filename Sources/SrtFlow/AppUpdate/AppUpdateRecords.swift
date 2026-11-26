import Foundation

// MARK: - The two small files the updater leaves on disk: the staged update and the installer's marker
//
// What it does: `AppUpdateStagedRecord` says which verified copy waits in Application Support/SrtFlow/Updates for the next
// quit (the feed it came from, where the copy is, whether the person asked for it with auto install off).
// `AppUpdateInstalledNote` is what the installer writes right before it swaps the new copy in: the next launch of that
// version reads it once and shows the Updated pill with that version's notes. Both are JSON, parsed as strictly as the feed
// (the staged record reuses the feed's own parser); a file that isn't exactly right reads as none. The new version reads a
// note the old version wrote, so the format is part of the contract (docs/architecture/app-updates.md "Files").
// What it doesn't: where the files live or who writes them (AppUpdateFiles, AppUpdateInstaller).

struct AppUpdateStagedRecord: Equatable, Sendable {
    var feed: AppUpdateFeed
    /// The verified copy (Updates/staged/<version>/<name>.app).
    var appPath: String
    /// Downloaded because the person clicked Download and Install (auto install off): it then installs at quit anyway.
    var asked: Bool

    func data() throws -> Data {
        var object = feed.jsonObject
        object["app"] = appPath
        object["asked"] = asked
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    init(feed: AppUpdateFeed, appPath: String, asked: Bool) {
        self.feed = feed
        self.appPath = appPath
        self.asked = asked
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = AppUpdateFeed.parse(object, allowsDMG: { _ in true }),
              let path = object["app"] as? String, path.hasPrefix("/"), path.hasSuffix(".app"),
              let asked = object["asked"] as? Bool else { return nil }
        self.init(feed: feed, appPath: path, asked: asked)
    }
}

struct AppUpdateInstalledNote: Equatable, Sendable {
    static let schema = 1
    var from: AppUpdateVersion
    var to: AppUpdateVersion
    var notes: [String: [String]]

    func data() throws -> Data {
        let object: [String: Any] = ["schema": Self.schema, "from": from.description, "to": to.description, "notes": notes]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    init(from: AppUpdateVersion, to: AppUpdateVersion, notes: [String: [String]]) {
        self.from = from
        self.to = to
        self.notes = notes
    }

    init?(data: Data) {
        guard data.count <= AppUpdateFeed.maxFeedBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schema"] as? NSNumber)?.intValue == Self.schema,
              let from = (object["from"] as? String).flatMap(AppUpdateVersion.init),
              let to = (object["to"] as? String).flatMap(AppUpdateVersion.init), from < to,
              let notes = AppUpdateFeed.parseNotes(object["notes"]) else { return nil }
        self.init(from: from, to: to, notes: notes)
    }
}

/// The projects Restart and Update reopens: written at its quit (UserDefaults), read once by the next launch.
struct AppUpdateReopenRecord: Equatable, Sendable {
    /// The main window's project file (nil: it was untitled or empty).
    var primary: String?
    /// The project files open in their own windows (background projects are the AI's and are not reopened).
    var windows: [String]
    var at: Date

    var dictionary: [String: Any] {
        var object: [String: Any] = ["windows": windows, "at": at.timeIntervalSince1970]
        if let primary { object["primary"] = primary }
        return object
    }

    init(primary: String?, windows: [String], at: Date) {
        self.primary = primary
        self.windows = windows
        self.at = at
    }

    init?(dictionary: [String: Any]?) {
        guard let dictionary, let windows = dictionary["windows"] as? [String], let at = dictionary["at"] as? Double else { return nil }
        let primary = dictionary["primary"] as? String
        guard ([primary].compactMap { $0 } + windows).allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        self.init(primary: primary, windows: windows, at: Date(timeIntervalSince1970: at))
    }

    /// Only a restart just now: a record older than `freshness` (a crash between the quit and the relaunch, a relaunch that
    /// never came) or from the future is dropped.
    func isFresh(now: Date, freshness: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(at)
        return age >= -60 && age <= freshness
    }
}

extension AppUpdateFeed {
    /// The feed's own fields, as the feed writes them (the staged record adds two of its own).
    var jsonObject: [String: Any] {
        ["schema": Self.schema, "bundle_id": Self.bundleIdentifier, "version": version.description, "build": build,
         "minimum_macos": minimumSystem.description, "dmg_url": dmgURL.absoluteString, "dmg_size": dmgSize,
         "dmg_sha256": dmgSHA256, "notes": notes]
    }

    /// The same release: version and image (a feed that swapped the DMG under the same version is another release).
    func isSameRelease(as other: AppUpdateFeed) -> Bool {
        version == other.version && dmgSHA256 == other.dmgSHA256 && dmgSize == other.dmgSize
    }
}
