import CryptoKit
import Foundation
import SrtFlowMCPKit

// MARK: - Content published on Sky Studio for SkyCut: the manifest and one editing style (pure values)
//
// What this owns: how `GET /content` (the current release's manifest: titles, versions, checksums, no text) and
// `GET /content/styles/{id}` (one style's text) read; which ids and versions may ever go into an address; the SHA-256 every
// text is checked against; comparing SkyCut versions for `min_skycut_version`. Read leniently like /me: unknown fields are
// ignored, a style entry with an unusable id / version / checksum is left out of the list rather than spoiling it.
// The contract is in the Sky Studio repo, docs/agents/skycut-api.md ("Editing styles and craft cards", 2026-11-19).
// Not this file: asking (SkyStudioContentAPI), keeping copies on this Mac (SkyStudioContentCache), when to ask and who may
// read (SkyStudioStyleLibrary), the recipes tool (AIRecipeSkyStudio).

enum SkyStudioContentRules {
    /// A published item's id: `film-trailer`, `512`. The only shape that may become part of an address.
    static func isItemID(_ text: String) -> Bool {
        text.range(of: #"\A[a-z0-9][a-z0-9-]{0,59}\z"#, options: .regularExpression) != nil
    }

    /// A version (`1.0`, `2`, `1.0.1`): digits with up to two dots, so a version never brings `&`, `/` or `..` into a query.
    static func isVersion(_ text: String) -> Bool {
        text.range(of: #"\A[0-9]{1,6}(\.[0-9]{1,6}){0,2}\z"#, options: .regularExpression) != nil
    }

    static func isChecksum(_ text: String) -> Bool {
        text.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }

    /// SHA-256 of the UTF-8 text the AI receives, lowercase hex (the same on Sky Studio's side and in the publish script).
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Is `version` (SkyCut's own, `0.18.70`; build suffixes ignored) older than `minimum`? Unreadable versions are never
    /// called older: the note it drives is a hint, not a gate.
    static func isOlder(_ version: String, than minimum: String) -> Bool {
        func numbers(_ text: String) -> [Int]? {
            let core = text.prefix { $0 != "-" && $0 != "+" }
            let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }
        }
        guard let mine = numbers(version), let wanted = numbers(minimum) else { return false }
        for index in 0..<max(mine.count, wanted.count) {
            let a = index < mine.count ? mine[index] : 0, b = index < wanted.count ? wanted[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// `GET /content`: the current release. `raw` keeps the whole answer (the cards part included) so the cache can write it
/// back unchanged for the card tool that reads the same manifest later.
struct SkyStudioContentManifest: Equatable, Sendable {
    struct Style: Equatable, Sendable {
        var id: String
        var title: String
        var useFor: String
        var version: String
        var sha256: String
        var minSkyCutVersion: String?
    }

    var release: Int
    var publishedAt: Date?
    var styles: [Style]
    var raw: JSONValue

    init?(json: JSONValue) {
        guard let release = json["release"]?.intValue, release >= 1, let list = json["styles"]?.arrayValue else { return nil }
        self.release = release
        publishedAt = json["published_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate)
        var seen = Set<String>()
        styles = list.compactMap { entry -> Style? in
            guard let id = entry["id"]?.stringValue, SkyStudioContentRules.isItemID(id), seen.insert(id).inserted,
                  let version = entry["version"]?.stringValue, SkyStudioContentRules.isVersion(version),
                  let sha = entry["sha256"]?.stringValue, SkyStudioContentRules.isChecksum(sha) else { return nil }
            let title = entry["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Style(id: id, title: title.isEmpty ? id : title, useFor: entry["use_for"]?.stringValue ?? "",
                         version: version, sha256: sha, minSkyCutVersion: entry["min_skycut_version"]?.stringValue)
        }
        raw = json
    }
}

/// `GET /content/styles/{id}`: one version of one style. Only accepted when it is the style and version asked for and its
/// text matches its checksum; anything else is a bad answer (never shown to the AI).
struct SkyStudioStyleText: Equatable, Sendable {
    var id: String
    var title: String
    var useFor: String
    var version: String
    var sha256: String
    var minSkyCutVersion: String?
    /// The release that first published this version (never changes).
    var firstRelease: Int?
    var text: String

    init(id: String, title: String, useFor: String, version: String, sha256: String, minSkyCutVersion: String? = nil,
         firstRelease: Int? = nil, text: String) {
        (self.id, self.title, self.useFor, self.version, self.sha256) = (id, title, useFor, version, sha256)
        (self.minSkyCutVersion, self.firstRelease, self.text) = (minSkyCutVersion, firstRelease, text)
    }

    /// `version` nil = whichever version the answer names (the current one).
    init?(json: JSONValue, id wantedID: String, version wantedVersion: String?) {
        guard let id = json["id"]?.stringValue, id == wantedID,
              let version = json["version"]?.stringValue, SkyStudioContentRules.isVersion(version),
              wantedVersion == nil || wantedVersion == version,
              let sha = json["sha256"]?.stringValue, SkyStudioContentRules.isChecksum(sha),
              let text = json["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SkyStudioContentRules.sha256(text) == sha else { return nil }
        let title = json["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: id, title: title.isEmpty ? id : title, useFor: json["use_for"]?.stringValue ?? "", version: version,
                  sha256: sha, minSkyCutVersion: json["min_skycut_version"]?.stringValue, firstRelease: json["first_release"]?.intValue,
                  text: text)
    }

    /// The same fields as the server's answer (the cache writes this and reads it back with `init(json:id:version:)`).
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "title": .string(title), "use_for": .string(useFor), "version": .string(version),
            "sha256": .string(sha256), "text": .string(text)
        ]
        if let minSkyCutVersion { object["min_skycut_version"] = .string(minSkyCutVersion) }
        if let firstRelease { object["first_release"] = .number(Double(firstRelease)) }
        return .object(object)
    }
}
