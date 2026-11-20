import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio's craft cards for SkyCut: the cards part of the manifest, what may be asked, one card page (pure values)
//
// What this owns (SS5 plan 5.6; the contract is in the Sky Studio repo, docs/agents/skycut-api.md, "Editing styles and craft
// cards", 2026-11-19):
// - SkyStudioCardCatalog: the cards part of `GET /content` (the entry page, each group's catalogue, each card: versions and
//   checksums, no text). Read leniently like the styles: an entry with an unusable id / version / checksum is left out; no cards
//   part at all, or `entry: null` with empty lists, is "no cards published" (day one publishes the trailer alone);
// - SkyStudioCardRequest: what craft_cards may ask for (the entry page, one group's catalogue, one card) and the shapes that may
//   become part of an address (a card id is three digits, a group an item id);
// - SkyStudioCardPage: one version of one page as Sky Studio sends it (`GET /content/cards[?group=]`, `GET /content/cards/{id}`),
//   accepted only when it is the page and version asked for and its text matches its checksum, and written back in the same
//   shape for the copy on this Mac. A card's and the entry page's `rev` arrives as a number; it is kept as a version string.
// Not this file: asking (SkyStudioContentAPI), the copies (SkyStudioContentCache), when to ask and who may read
// (SkyStudioStyleLibrary), what the AI is told (AICraftCardsAnswer, SkyStudioCardWords).

/// The cards part of the current release's manifest.
struct SkyStudioCardCatalog: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var version: String
        var sha256: String
    }

    struct Group: Equatable, Sendable {
        var group: String
        var title: String
        var version: String
        var count: Int
        var sha256: String
    }

    struct Card: Equatable, Sendable {
        var id: String
        var group: String
        var title: String
        var version: String
        var sha256: String
    }

    var entry: Entry?
    var groups: [Group] = []
    var cards: [Card] = []

    /// Nothing published for the cards (yet, or withdrawn).
    var isEmpty: Bool { entry == nil && groups.isEmpty && cards.isEmpty }

    init(entry: Entry? = nil, groups: [Group] = [], cards: [Card] = []) {
        (self.entry, self.groups, self.cards) = (entry, groups, cards)
    }

    /// The manifest's `cards` object; nil or anything unreadable = no cards.
    init(json: JSONValue?) {
        if let entry = json?["entry"], let version = Self.version(entry["rev"]),
           let sha = entry["sha256"]?.stringValue, SkyStudioContentRules.isChecksum(sha) {
            self.entry = Entry(version: version, sha256: sha)
        }
        var seenGroups = Set<String>()
        groups = (json?["groups"]?.arrayValue ?? []).compactMap { item -> Group? in
            guard let group = item["group"]?.stringValue, SkyStudioContentRules.isItemID(group), seenGroups.insert(group).inserted,
                  let version = Self.version(item["version"]),
                  let sha = item["sha256"]?.stringValue, SkyStudioContentRules.isChecksum(sha) else { return nil }
            return Group(group: group, title: Self.title(item["title"], or: group), version: version,
                         count: max(0, item["count"]?.intValue ?? 0), sha256: sha)
        }
        var seenCards = Set<String>()
        cards = (json?["items"]?.arrayValue ?? []).compactMap { item -> Card? in
            guard let id = item["id"]?.stringValue, SkyStudioContentRules.isCardID(id), seenCards.insert(id).inserted,
                  let version = Self.version(item["rev"]),
                  let sha = item["sha256"]?.stringValue, SkyStudioContentRules.isChecksum(sha) else { return nil }
            return Card(id: id, group: item["group"]?.stringValue ?? "", title: Self.title(item["title"], or: id), version: version,
                        sha256: sha)
        }
    }

    /// The version and checksum this release names for a page; nil = the release does not hold it.
    func listed(_ request: SkyStudioCardRequest) -> (version: String, sha256: String)? {
        switch request {
        case .entry: return entry.map { ($0.version, $0.sha256) }
        case .group(let key): return groups.first { $0.group == key }.map { ($0.version, $0.sha256) }
        case .card(let id): return cards.first { $0.id == id }.map { ($0.version, $0.sha256) }
        }
    }

    /// A card's or the entry page's `rev` (a number), or a catalogue's `version` (text): either way a version string.
    static func version(_ value: JSONValue?) -> String? {
        if let number = value?.intValue, number >= 0 { return String(number) }
        if let text = value?.stringValue, SkyStudioContentRules.isVersion(text) { return text }
        return nil
    }

    private static func title(_ value: JSONValue?, or fallback: String) -> String {
        let title = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? fallback : title
    }
}

/// What craft_cards reads: the entry page, one group's catalogue, or one card.
enum SkyStudioCardRequest: Equatable, Hashable, Sendable {
    case entry
    case group(String)
    case card(String)

    /// The AI's arguments: neither = the entry page; `group` = that catalogue; `id` = that card. A card number of one or two
    /// digits is padded (7 → 007: the story cards are 001–014). Anything that may not go into an address is refused before
    /// asking; the message is for the AI.
    static func from(id: String?, group: String?) throws -> SkyStudioCardRequest {
        let id = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let group = group?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch (id.isEmpty ? nil : id, group.isEmpty ? nil : group) {
        case (nil, nil):
            return .entry
        case (.some, .some):
            throw SkyStudioContentRequestProblem(message: "Give id (one card) or group (one group's catalogue), not both.")
        case (let id?, nil):
            let digits = id.allSatisfy { $0 >= "0" && $0 <= "9" }
            let padded = digits && id.count < 3 ? String(repeating: "0", count: 3 - id.count) + id : id
            guard SkyStudioContentRules.isCardID(padded) else {
                throw SkyStudioContentRequestProblem(message: "id is a craft card's three-digit number, like 512.")
            }
            return .card(padded)
        case (nil, let group?):
            guard SkyStudioContentRules.isItemID(group) else {
                throw SkyStudioContentRequestProblem(message: "group is a craft-card group's key, like sound (the entry page lists them).")
            }
            return .group(group)
        }
    }

    /// The folder its copies are kept in on this Mac.
    var kind: String {
        switch self {
        case .entry: return "entry"
        case .group: return "group"
        case .card: return "card"
        }
    }

    /// The id its copies are kept under: `entry`, the group's key, the card's number.
    var id: String {
        switch self {
        case .entry: return "entry"
        case .group(let key): return key
        case .card(let id): return id
        }
    }

    /// For the AI's messages.
    var label: String {
        switch self {
        case .entry: return "the craft cards' entry page"
        case .group(let key): return "the \(key) group's catalogue"
        case .card(let id): return "craft card \(id)"
        }
    }
}

/// One version of one card page: Sky Studio's answer, or the copy on this Mac (written back in the same shape).
struct SkyStudioCardPage: Equatable, Sendable {
    var request: SkyStudioCardRequest
    var version: String
    /// A group's or a card's title (the entry page has none).
    var title: String?
    /// A card's group.
    var group: String?
    /// A card's related cards (three-digit ids).
    var related: [String] = []
    var sha256: String
    var minSkyCutVersion: String?
    /// The release that first published this version (never changes).
    var firstRelease: Int?
    var text: String

    init(request: SkyStudioCardRequest, version: String, title: String? = nil, group: String? = nil, related: [String] = [],
         sha256: String, minSkyCutVersion: String? = nil, firstRelease: Int? = nil, text: String) {
        (self.request, self.version, self.title, self.group, self.related) = (request, version, title, group, related)
        (self.sha256, self.minSkyCutVersion, self.firstRelease, self.text) = (sha256, minSkyCutVersion, firstRelease, text)
    }

    /// `version` nil = whichever version the answer names. Nil for another page or version than asked (the entry page carries no
    /// `id` or `group`, a catalogue no `id`), an empty text, or a text that does not match its checksum.
    init?(json: JSONValue, request: SkyStudioCardRequest, version wanted: String?) {
        let version: String?
        switch request {
        case .entry:
            guard json["id"] == nil, json["group"] == nil else { return nil }
            version = SkyStudioCardCatalog.version(json["rev"])
        case .group(let key):
            guard json["group"]?.stringValue == key, json["id"] == nil else { return nil }
            version = SkyStudioCardCatalog.version(json["version"])
        case .card(let id):
            guard json["id"]?.stringValue == id else { return nil }
            version = SkyStudioCardCatalog.version(json["rev"])
        }
        guard let version, wanted == nil || wanted == version,
              let sha = json["sha256"]?.stringValue, SkyStudioContentRules.isChecksum(sha),
              let text = json["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SkyStudioContentRules.sha256(text) == sha else { return nil }
        let title = json["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let related = (json["related"]?.arrayValue ?? []).compactMap(\.stringValue).filter(SkyStudioContentRules.isCardID)
        self.init(request: request, version: version, title: title?.isEmpty == false ? title : nil, group: json["group"]?.stringValue,
                  related: related, sha256: sha, minSkyCutVersion: json["min_skycut_version"]?.stringValue,
                  firstRelease: json["first_release"]?.intValue, text: text)
    }

    /// The same fields as Sky Studio's answer for this kind (the cache writes this and reads it back with `init(json:…)`).
    var json: JSONValue {
        var object: [String: JSONValue] = ["sha256": .string(sha256), "text": .string(text)]
        let rev: JSONValue = Int(version).map { .number(Double($0)) } ?? .string(version)
        switch request {
        case .entry:
            object["rev"] = rev
        case .group(let key):
            object["group"] = .string(key)
            object["version"] = .string(version)
        case .card(let id):
            object["id"] = .string(id)
            object["rev"] = rev
            object["related"] = .array(related.map(JSONValue.string))
            if let group { object["group"] = .string(group) }
        }
        if let title { object["title"] = .string(title) }
        if let minSkyCutVersion { object["min_skycut_version"] = .string(minSkyCutVersion) }
        if let firstRelease { object["first_release"] = .number(Double(firstRelease)) }
        return .object(object)
    }
}
