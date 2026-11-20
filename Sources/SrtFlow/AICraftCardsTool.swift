import Foundation
import SrtFlowMCPKit

// MARK: - craft_cards: the async steps (SS5 plan 5.6, decision D10; 2026-11-20)
//
// What this owns: the order of one call. The router has already checked the argument names and the MCP licence
// (SkyStudioAccount.aiRefusal); then: the craft cards need `features.recipes` too (SkyStudioAccount.cardRefusal: not done, why,
// what the user can do; nothing asked), the request's shape (no network for a malformed id or group), the list asked first (the
// shared manifest, 10 minutes old = asked again with its ETag), the page read through the App's one content library
// (SkyStudioStyles.shared.readCard: this Mac's copy, ETag, licence, plain words), and the answer (AICraftCardsAnswer).
// Read-only like recipes: no queue, no window, no round (AIToolRouter's Policy row), no project, nothing written to a film.
// Not this file: the answer (AICraftCardsAnswer), reading and its words (SkyStudioStyleLibrary, SkyStudioCardWords), the card
// and parameters (MCPCraftCardsTool), the guide topic (MCPGuideCraftCardsTopic).

@MainActor
enum AICraftCardsTool {
    static func read(_ args: AIToolArguments) async throws -> AIToolResult {
        if let refusal = SkyStudioAccount.shared.cardRefusal { throw AIToolError(refusal) }
        let page: SkyStudioCardRequest
        do {
            page = try SkyStudioCardRequest.from(id: try args.string("id"), group: try args.string("group"))
        } catch let wrongShape as SkyStudioContentRequestProblem {
            throw AIToolError(wrongShape.message)
        }
        let library = SkyStudioStyles.shared
        _ = await library.refreshedListing()
        do {
            let read = try await library.readCard(page)
            return .ok(AICraftCardsAnswer.answer(read.page, cachedAt: read.cachedAt, cards: library.listing.cards,
                                                 appVersion: SkyStudioAPI.appVersion))
        } catch let problem as SkyStudioStyleLibrary.ReadProblem {
            throw AIToolError(problem.message)
        }
    }
}
