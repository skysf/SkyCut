import Foundation

// MARK: - Which link partners come along when the AI pushes or pulls V1
//
// What: `AITimelineEdits.shiftMain` (add_clips insert, delete_items / edit_clip ripple, cut_to_beat) moves the V1 clips from a
// time on; with linkage on, their link groups come along. This decides which groups: only a group none of whose V1 pictures stays
// behind. A group with two pictures on V1 (a split made with linkage off, a freeze tail saved before 2026-11-17) used to drag its
// earlier picture along, onto the clip before it on V1, and its sound with it (docs/bugfixes/2026-11-17-freeze-tail-ripple-drags-its-clip.md).
// Such a group's sound cannot follow both pictures; it stays with the one that stays, as linkage rule 13 pairs it with the earliest.
// Not: which V1 clips move (the caller), what happens to everything else (`TimelineLinkage.follow` when `perform` ends).
// Pure value: scripts/check-mcp.sh compiles it (checks/MCP/FreezeRippleChecks.swift).

enum RippleLinkPartners {
    /// The clips that move along with `movers` (V1 clips the ripple moves): each mover's whole link group, unless one of that
    /// group's V1 pictures stays (on V1, not moving, not in `excluding` — the clips the caller deletes or edits itself).
    static func following(_ movers: [UUID], excluding: Set<UUID>, in state: TimelineState) -> Set<UUID> {
        let staying = Set(state.mainClips.map(\.id)).subtracting(movers).subtracting(excluding)
        var ids: Set<UUID> = []
        for id in movers {
            let group = state.linkedClipIDs(of: id)
            if group.isDisjoint(with: staying) { ids.formUnion(group) }
        }
        return ids
    }
}
