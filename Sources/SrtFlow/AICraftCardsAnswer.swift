import Foundation
import SrtFlowMCPKit

// MARK: - craft_cards: the answer when a page was read (pure; SS5 plan 5.6, 2026-11-20)
//
// What this owns: what the AI reads for one craft-card page: the page and its text (the entry page with the groups the list
// holds, so the AI knows the keys for group=; a group's catalogue; one card with its related cards), whether it came from this
// Mac's copy (`cached` + `fetched_at`, the same words as a Sky Studio style in recipes), a `note` when the page was checked against
// a newer SkyCut than this one, and a `next_step` (read only what the step needs; the user's words and the editing style first;
// never save card text). Built from values gathered first, so CardLibraryChecks build it by hand.
// Not this file: reading (SkyStudioStyleLibrary.readCard), every reason a page is not read (SkyCutGates.cardRefusal,
// SkyStudioCardWords), the async glue (AICraftCardsTool).

enum AICraftCardsAnswer {
    /// One page read for the AI. `cards`: the list the page was read against; `appVersion`: this SkyCut's version.
    static func answer(_ page: SkyStudioCardPage, cachedAt: Date?, cards: SkyStudioCardCatalog, appVersion: String) -> JSONValue {
        var object: [String: JSONValue] = ["sha256": .string(page.sha256), "text": .string(page.text)]
        let rev: JSONValue = Int(page.version).map { .number(Double($0)) } ?? .string(page.version)
        var next: String
        switch page.request {
        case .entry:
            object["page"] = "entry"
            object["rev"] = rev
            object["groups"] = .array(cards.groups.map { group -> JSONValue in
                ["group": .string(group.group), "title": .string(group.title), "count": .number(Double(group.count))]
            })
            next = "Read only what the step needs: craft_cards group=<group> for one group's catalogue, craft_cards id=<number> for one card."
        case .group(let key):
            object["page"] = "group"
            object["group"] = .string(key)
            object["version"] = .string(page.version)
            next = "Read the one or two cards the step needs with craft_cards id=<number>."
        case .card(let id):
            object["page"] = "card"
            object["id"] = .string(id)
            object["rev"] = rev
            object["related"] = .array(page.related.map(JSONValue.string))
            if let group = page.group { object["group"] = .string(group) }
            next = "Do what its In SkyCut part names with those tools."
                + (page.related.isEmpty ? "" : " Related: " + page.related.map { "craft_cards id=\($0)" }.joined(separator: ", ") + ".")
        }
        if let title = page.title { object["title"] = .string(title) }
        if let cachedAt {
            object["cached"] = true
            object["fetched_at"] = .string(AIRecipeSkyStudioPart.day(cachedAt))
        }
        if let checked = page.minSkyCutVersion, SkyStudioContentRules.isOlder(appVersion, than: checked) {
            object["note"] = .string("This page was checked against SkyCut \(checked) and this SkyCut is older: a call it names may "
                + "fail. If one does, tell the user to update SkyCut.")
        }
        object["next_step"] = .string(next + " The user's words win, then the editing style; cards are Sky Studio's: never save "
            + "them with save_recipe.")
        return .object(object)
    }
}
