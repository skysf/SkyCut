import Foundation

// MARK: - What the AI is told when a craft-card page cannot be read (English, pure; SS5 plan 5.6)
//
// What this owns: the sentences for each reason a card page is not read: nothing published yet (day one publishes only the
// trailer style: `GET /content` lists no cards, and a text route answers 404, or 503 `content_unavailable` while nothing at all
// is published), no such group or card in the list, the list or the page unreachable with no copy here, Sky Studio refusing
// this Mac (`403 not_entitled` in plain words by `plan_reason`, the same rule as the styles: SkyStudioStyleLibrary.notEntitledWords),
// and a page Sky Studio no longer holds. Each says what still works: editing never needs the cards.
// Not this file: the licence refusal before anything is asked (SkyCutGates.cardRefusal), reading (SkyStudioStyleLibrary.readCard),
// the answer when a page is read (AICraftCardsAnswer).

enum SkyStudioCardWords {
    /// What keeps working without the cards (appended to every refusal).
    static let still = " Editing works without them."

    static let needsPlan = "Sky Studio's craft cards need SkyCut Pro or the SkyCut trial." + still

    static let nonePublished = "Sky Studio has not published any craft cards yet." + still

    static let listUnreachable = "Sky Studio cannot be reached and this Mac has no copy of its craft cards' list; try again when SkyCut "
        + "is online." + still

    /// The list holds cards, but not this page.
    static func notListed(_ page: SkyStudioCardRequest, in cards: SkyStudioCardCatalog) -> String {
        let groups = cards.groups.map(\.group).joined(separator: ", ")
        switch page {
        case .entry:
            return "Sky Studio publishes no entry page for its craft cards now. "
                + (groups.isEmpty ? "Ask for a card by its number: craft_cards id=<number>." : "Read a group's catalogue: craft_cards group=<one of \(groups)>.")
        case .group(let key):
            return "Sky Studio has no craft-card group called \(key). "
                + (groups.isEmpty ? "It lists no groups now." : "Groups: \(groups).")
        case .card(let id):
            return "Sky Studio lists no craft card \(id) now. Find card numbers on the entry page (craft_cards with no arguments) or in a "
                + "group's catalogue."
        }
    }

    /// Sky Studio did not send a listed page (asked by the version the list names) and no copy here could stand in.
    static func problem(_ failure: SkyStudioFailure, page: SkyStudioCardRequest, version: String) -> String {
        switch failure {
        case .network, .uploadInterrupted:
            return "Sky Studio cannot be reached and this Mac has no copy of \(page.label) (version \(version)); try again when SkyCut "
                + "is online." + still
        case .server(let error) where error.code == "not_found":
            return "Sky Studio no longer has \(page.label) at version \(version); call craft_cards again to read what it lists now."
        case .server(let error) where error.code == "not_entitled":
            return SkyStudioStyleLibrary.notEntitledWords(error, what: "craft cards", still: still)
        case .server(let error) where error.code == "content_unavailable":
            return "Sky Studio cannot send its craft cards right now; try again later." + still
        case .server(let error):
            return "Sky Studio did not send \(page.label): \(error.message)"
        case .badAnswer:
            return "Sky Studio sent an answer SkyCut does not understand for \(page.label); try again later."
        }
    }
}
