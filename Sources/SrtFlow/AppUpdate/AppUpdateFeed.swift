import Foundation

// MARK: - The update feed: one JSON file naming SkyCut's newest release
//
// What it does: where the feed is (the one production address, and the `defaults` test hook), its strict parser, and
// what a feed may offer. A feed that isn't exactly right is no feed: nil, and the updater says nothing. Unknown fields are
// ignored, so a later feed can add some. A version not newer than the running one, or needing a newer macOS, is never
// offered: no downgrades, no reinstall of the same version. Pure: the checks feed it every case.
// What it doesn't: fetch (AppUpdateHTTP), decide who updates (AppUpdateEligibility), download or install.
// Rules: docs/architecture/app-updates.md "The feed" (the contract the release tooling writes: scripts/write-update-feed.sh).

struct AppUpdateFeed: Equatable, Sendable {
    /// The one place SkyCut's update addresses are written (checks/app-update-wiring.sh).
    static let productionURL = URL(string: "https://skylu.ai/updates/skycut.json")!
    /// The stable download entry (it redirects to the newest DMG): for a copy that can't update itself.
    static let downloadPageURL = URL(string: "https://skylu.ai/download/skycut")!
    /// A production feed's DMG is only ever an immutable object on this host, over https (never the redirect).
    static let downloadHost = "downloads.skylu.ai"
    static let schema = 1
    /// Only the release app reads the feed; a feed for anything else is refused.
    static let bundleIdentifier = "com.srtflow.SrtFlow"
    static let maxFeedBytes = 64 * 1024
    static let maxDMGBytes: Int64 = 1 << 30
    /// "What's new": a few short lines per language; English is required (every other language falls back to it).
    static let maxNotes = 8
    static let maxNoteCharacters = 300

    let version: AppUpdateVersion
    /// CFBundleVersion of the app in the DMG.
    let build: String
    let minimumSystem: AppUpdateSystemVersion
    let dmgURL: URL
    let dmgSize: Int64
    /// Lowercase hex.
    let dmgSHA256: String
    /// Language code ("zh-Hans", "en", "es") → its lines.
    let notes: [String: [String]]

    /// Whether this feed offers anything to `running` on `system`: strictly newer, and runs on this macOS.
    func isOffered(to running: AppUpdateVersion, on system: OperatingSystemVersion) -> Bool {
        version > running && minimumSystem.isSatisfied(by: system)
    }

    /// The lines for the in-app language: its own, else one of the same language ("zh" for "zh-Hans"), else English.
    func notes(forLanguage code: String) -> [String] {
        Self.notes(notes, forLanguage: code)
    }

    static func notes(_ notes: [String: [String]], forLanguage code: String) -> [String] {
        let wanted = code.lowercased()
        if let exact = notes.first(where: { $0.key.lowercased() == wanted }) { return exact.value }
        let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
        if let same = notes.first(where: { $0.key.lowercased().split(separator: "-").first.map(String.init) == language }) {
            return same.value
        }
        return notes["en"] ?? []
    }
}

// MARK: - Where the feed comes from

extension AppUpdateFeed {
    /// The feed's address and where its DMG may come from.
    struct Source: Equatable, Sendable {
        let feedURL: URL
        /// Set through the test hook (`defaults write com.srtflow.SrtFlow SrtFlow.update.feedURL <url>`): https anywhere, or
        /// http on this Mac only. The DMG may then also come from the hook's own origin; signature and notarization checks
        /// stay the same.
        let isTestHook: Bool

        static let production = Source(feedURL: AppUpdateFeed.productionURL, isTestHook: false)
        /// The UserDefaults key of the test hook (identity-class name: docs/architecture/product-name.md).
        static let overrideKey = "SrtFlow.update.feedURL"

        /// The test hook's address when it is one SkyCut accepts; production otherwise (a bad override is ignored).
        static func resolve(override: String?) -> Source {
            guard let text = override?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let url = URL(string: text), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return .production }
            switch url.scheme?.lowercased() {
            case "https": return Source(feedURL: url, isTestHook: true)
            case "http" where isLoopback(host): return Source(feedURL: url, isTestHook: true)
            default: return .production
            }
        }

        /// The test hook points at this Mac (the checks' and a local two-build test's feed).
        var isLoopback: Bool { isTestHook && feedURL.host.map(Self.isLoopback) == true }

        /// A DMG address this source may name: https on downloads.skylu.ai; with the test hook also its own origin.
        func allowsDMG(_ url: URL) -> Bool {
            guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host?.lowercased(),
                  url.path.lowercased().hasSuffix(".dmg") else { return false }
            if url.scheme?.lowercased() == "https", host == AppUpdateFeed.downloadHost { return true }
            guard isTestHook else { return false }
            return url.scheme?.lowercased() == feedURL.scheme?.lowercased() && host == feedURL.host?.lowercased()
                && url.port == feedURL.port
        }

        /// The same loopback names SkyStudioAPI.isLoopback accepts for its own test server.
        static func isLoopback(_ host: String) -> Bool {
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
        }
    }
}

// MARK: - Parsing

extension AppUpdateFeed {
    /// The feed, or nil for anything not exactly right (too big, not JSON, a missing or malformed field, another app, a DMG
    /// from a place this source may not name). Unknown fields are ignored.
    static func parse(_ data: Data, from source: Source) -> AppUpdateFeed? {
        guard data.count <= maxFeedBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object, allowsDMG: source.allowsDMG)
    }

    /// The fields of a feed already read as JSON (the staged record keeps them: AppUpdateStagedRecord).
    static func parse(_ object: [String: Any], allowsDMG: (URL) -> Bool) -> AppUpdateFeed? {
        guard integer(object["schema"]) == Int64(schema),
              object["bundle_id"] as? String == bundleIdentifier,
              let version = (object["version"] as? String).flatMap(AppUpdateVersion.init),
              let build = object["build"] as? String, isBuildNumber(build),
              let minimum = (object["minimum_macos"] as? String).flatMap(AppUpdateSystemVersion.init),
              let link = object["dmg_url"] as? String, let url = URL(string: link), allowsDMG(url),
              let size = integer(object["dmg_size"]), size > 0, size <= maxDMGBytes,
              let digest = object["dmg_sha256"] as? String, isSHA256(digest),
              let notes = parseNotes(object["notes"]) else { return nil }
        return AppUpdateFeed(version: version, build: build, minimumSystem: minimum, dmgURL: url, dmgSize: size,
                             dmgSHA256: digest, notes: notes)
    }

    /// A JSON integer (never a boolean, never a fraction).
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9e15 else { return nil }
        return number.int64Value
    }

    /// CFBundleVersion as SkyCut writes it: "1", or dotted whole numbers ("12.3").
    static func isBuildNumber(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && text.count <= 32
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Every language a list of 1…maxNotes lines, each one line of at most maxNoteCharacters; English required.
    static func parseNotes(_ value: Any?) -> [String: [String]]? {
        guard let table = value as? [String: Any], !table.isEmpty, table.count <= 16 else { return nil }
        var notes: [String: [String]] = [:]
        for (language, lines) in table {
            guard isLanguageCode(language), let lines = lines as? [String], (1...maxNotes).contains(lines.count) else { return nil }
            let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            guard trimmed.allSatisfy(isNoteLine) else { return nil }
            notes[language] = trimmed
        }
        return notes["en"] == nil ? nil : notes
    }

    private static func isLanguageCode(_ text: String) -> Bool {
        (2...16).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") }
    }

    private static func isNoteLine(_ line: String) -> Bool {
        !line.isEmpty && line.count <= maxNoteCharacters
            && !line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
}
