import Foundation
import SrtFlowMCPKit

// MARK: - The names Sky Studio's published styles and cards use (skycut-published-names/1)
//
// What it owns: reading checks/MCP/published-content-names.json and the rules for its shape. The file holds names only,
// never the content (the repo is public): which Sky Studio content release it is, and for each published item its kind,
// id and version and the names its text uses, each one code span (`tool name name=value …`) or one bare name, exactly as
// the content gate found them. `release` is null until the first publish, with no items. After every publish the names-only
// snapshot replaces this file in a SkyCut PR; PublishedNamesChecks then checks each name against the live tools.
// What it does not own: checking a name (PublishedNameEntry). Rules: docs/architecture/ai-control-mcp.md section 4 item 32.

struct PublishedNamesSnapshot {
    static let format = "skycut-published-names/1"
    static let path = "checks/MCP/published-content-names.json"
    /// The kinds Sky Studio stores (its content table's check constraint).
    static let kinds: Set<String> = ["style", "card", "card_entry", "card_catalog"]
    /// Longer than any real code span; a sentence gets caught here or by the name check.
    static let entryLimit = 200

    struct Item: Equatable {
        let kind: String
        let id: String
        let version: String
        let names: [String]
    }

    let release: Int?
    let items: [Item]

    /// The snapshot (items with a bad shape left out) and what is wrong with its shape; no problems = it may be checked.
    static func read(_ file: JSONValue) -> (snapshot: PublishedNamesSnapshot, problems: [String]) {
        var problems: [String] = []
        guard let top = file.objectValue else { return (PublishedNamesSnapshot(release: nil, items: []), ["it is not a JSON object"]) }
        let extra = Set(top.keys).subtracting(["format", "release", "published_at", "items"])
        if !extra.isEmpty { problems.append("keys a names-only snapshot doesn't have: \(extra.sorted().joined(separator: ", "))") }
        if top["format"]?.stringValue != format { problems.append("format is not \(format)") }
        var release: Int?
        switch top["release"] {
        case .null?: release = nil
        case .number(let number)? where number.rounded() == number && number >= 1: release = Int(number)
        default: problems.append("release is null (nothing published yet) or a release number from 1")
        }
        if let stamp = top["published_at"], stamp.stringValue == nil { problems.append("published_at is a string") }
        guard let list = top["items"]?.arrayValue else {
            return (PublishedNamesSnapshot(release: release, items: []), problems + ["items is a list"])
        }
        if release == nil && top["release"]?.isNull == true && !list.isEmpty {
            problems.append("release is null but items are listed: only published content belongs here")
        }
        var items: [Item] = []
        var seen = Set<String>()
        for (index, entry) in list.enumerated() {
            let (item, itemProblems) = readItem(entry)
            problems += itemProblems.map { "item \(index + 1): \($0)" }
            guard let item, itemProblems.isEmpty else { continue }
            if !seen.insert(item.kind + " " + item.id).inserted { problems.append("item \(index + 1): \(item.kind) \(item.id) is listed twice") }
            items.append(item)
        }
        return (PublishedNamesSnapshot(release: release, items: items), problems)
    }

    private static func readItem(_ entry: JSONValue) -> (Item?, [String]) {
        guard let object = entry.objectValue else { return (nil, ["not an object"]) }
        var problems: [String] = []
        let keys = Set(object.keys)
        if keys != ["kind", "id", "version", "names"] {
            problems.append("has \(keys.sorted().joined(separator: ", ")) instead of exactly kind, id, version, names")
        }
        let kind = object["kind"]?.stringValue ?? "", id = object["id"]?.stringValue ?? "", version = object["version"]?.stringValue ?? ""
        if !kinds.contains(kind) { problems.append("kind \(kind) is not one of \(kinds.sorted().joined(separator: ", "))") }
        if id.range(of: #"^[a-z0-9][a-z0-9-]{0,59}$"#, options: .regularExpression) == nil { problems.append("id \(id) is not a content id") }
        if version.range(of: #"^[0-9A-Za-z][0-9A-Za-z.-]{0,31}$"#, options: .regularExpression) == nil {
            problems.append("version \(version) is not a version")
        }
        guard let list = object["names"]?.arrayValue else { return (nil, problems + ["names is a list"]) }
        var names: [String] = []
        for value in list {
            guard let name = value.stringValue else {
                problems.append("a name that is not a string")
                continue
            }
            let blank = name.trimmingCharacters(in: .whitespaces).isEmpty
            if blank || name.utf16.count > entryLimit || name.contains(where: { $0.isNewline || $0 == "\t" || $0 == "`" }) {
                problems.append("\(name.prefix(60)) is not one code span or name (one line, no backticks, at most \(entryLimit) characters)")
                continue
            }
            names.append(name)
        }
        return (Item(kind: kind, id: id, version: version, names: names), problems)
    }
}
