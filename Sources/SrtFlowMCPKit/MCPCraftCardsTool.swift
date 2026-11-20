import Foundation

// MARK: - The craft_cards tool's card and parameters (SS5 plan 5.6, decision D10; 2026-11-20)
//
// What this owns: the card (≤ 450) and the two parameters (each ≤ 120). Sky Studio's craft cards are read-only text from the same
// store as its editing styles, so the tool is read-only like recipes and sits beside it; it is a tool of its own because a card is
// not a style (no id / title shared with recipes, no save_recipe), and folding it into recipes would make recipes' answers and
// parameters longer for every edit. How to use it, availability and refusals are in the guide's craft_cards topic
// (MCPGuideCraftCardsTopic); the catalog keeps only what a call needs (catalog headroom, docs/architecture/mcp-guide.md item 17).
// Not this file: reading the cards (the App's AICraftCardsTool, SkyStudioStyleLibrary.readCard), the guide topic.

enum MCPCraftCardsTool {
    static var definition: MCPToolDefinition {
        MCPToolDefinition(
            .craftCards, title: "Read craft cards",
            description: """
            Read-only. Sky Studio's film-craft cards (SkyCut Pro or trial): no arguments = the entry page (which cards fit what \
            the user wants); group = one group's catalogue; id = one card, whose In SkyCut part names the calls to make. The \
            user's words and the editing style win.
            """,
            input: MCPSchema.object([
                "id": MCPSchema.string("A card's three-digit number, e.g. 512 (from the entry page or a catalogue)."),
                "group": MCPSchema.string("A group's key, e.g. sound: that group's catalogue. Give id or group, not both.")
            ]),
            readOnly: true
        )
    }
}
