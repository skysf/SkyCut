import Foundation

// MARK: - The guide's craft_cards topic (hand-written, 2026-11-20)
//
// What this owns: everything about craft_cards beyond its card: what the three pages are, when to read cards and how much, the
// order of authority (the user's words, then the editing style, then a card), and availability (Pro or the trial, this Mac's
// copy, nothing published yet, refusals). Registered in MCPGuideWrittenTopics like every migrated tool (GuidePilotChecks); a new
// tool, so there is no pre-migration card (previousCard nil, listed in GuidePilotChecks). fields are computed from the schema
// and come last (MCPGuideTopics). Card text itself never goes into the guide: the guide answers without a licence
// (docs/architecture/mcp-guide.md section 3 item 2).
// Sources: impl-briefs SS5 plan 5.6 / D10 (decisions), Sky Studio repo docs/agents/skycut-api.md "Editing styles and craft cards"
// (pages, licence, caching, errors), docs/architecture/ai-control-mcp.md section 4 item 32 (Sky Studio's content in SkyCut).
// Not this file: the card (MCPCraftCardsTool), reading (the App's AICraftCardsTool), how the guide answers (MCPGuide).

enum MCPGuideCraftCardsTopic {
    static let craftCards = MCPGuideWrittenTopics.Written(
        previousCard: nil,
        sections: [
            MCPGuideSection(name: MCPGuideSection.overview, text: """
            craft_cards reads Sky Studio's craft cards: short cards on film craft (how a shot, a cut, a sound, music or a look \
            does its job), each ending with an In SkyCut part that names the SkyCut calls to make. It is read-only and free and \
            never changes the project. Reading needs SkyCut Pro or the SkyCut trial, like Sky Studio's editing styles.

            Three pages. No arguments: the entry page, which maps what the user wants (a feeling, a task) to card numbers, and \
            the groups it lists. group=<key>: that group's catalogue, one line per card on when to read it. id=<number>: one \
            card (three digits), with related cards worth reading next.
            """),
            MCPGuideSection(name: "using", about: "when to read cards, how many, and what comes first", text: """
            Using them. Read cards when a step needs craft you are unsure of: how long to hold a shot, where to cut, how a sound \
            or music should land, how to check before export. Read only what the step needs: the entry page or one catalogue, \
            then one or two cards, not every card. Do what a card's In SkyCut part names with those tools. The user's words win, \
            then the editing style (recipes), then a card. Cards are Sky Studio's: never save a card, or a copy of one, with \
            save_recipe.
            """),
            MCPGuideSection(name: "availability", about: "Pro or the trial, this Mac's copy, nothing published yet, refusals", text: """
            Availability. SkyCut keeps a copy of each page it reads on this Mac; a page from that copy says cached and fetched_at, \
            and when Sky Studio cannot be reached a page read before still answers. Without SkyCut Pro or the trial, or on a \
            Mac Sky Studio has not registered (the user clicks Check Again in SkyCut Settings, Sky Studio), reading is refused \
            with what the user can do. Until Sky Studio publishes cards it says none are published yet: edit without them.
            """)
        ],
        examples: [
            ["group": "sound"],
            ["id": "512"]
        ],
        related: ["recipes", "workflows"]
    )
}
