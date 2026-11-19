import Foundation
import SrtFlowMCPKit

// MARK: - recipes / save_recipe with Sky Studio's editing styles: the async steps (SS5 plan 5.1, 5.2)
//
// What this owns: the App's one style library (`SkyStudioStyles.shared`: the licence from SkyStudioAccount, the copies in
// Application Support) and the async steps around the pure answers in AIRecipeTools. recipes asks for the list first (a manifest
// 10 minutes old is asked again); when the name is a Sky Studio style it checks the licence (SkyStudioAccount.styleRefusal: not
// done, why, what the user can do; the presets and the user's own still work) and reads it. save_recipe asks for the list so a
// Sky Studio name is refused even when the account cannot read the style.
// Not this file: the answers (AIRecipeTools, pure, RecipeChecks), the list and the copies (SkyStudioStyleLibrary, StyleChecks).

@MainActor
enum SkyStudioStyles {
    static let shared = SkyStudioStyleLibrary(licence: { SkyStudioAccount.shared.license })
}

@MainActor
enum AIRecipeSkyStudio {
    static func recipes(_ args: AIToolArguments) async throws -> AIToolResult {
        let library = SkyStudioStyles.shared
        var sky = part(await library.refreshedListing(), entitled: SkyStudioAccount.shared.license.recipes)
        let builtIn = AIBuiltInRecipes.load()
        let catalog = AIRecipeCatalog(builtIn: builtIn, user: AIRecipeStore.shared.userRecipes(), skyStudio: sky.styles.map(\.recipe))
        if let name = try args.string("id"), let style = catalog.find(name), style.source == .skyStudio {
            if let refusal = SkyStudioAccount.shared.styleRefusal { throw AIToolError(refusal) }
            do {
                sky.read = read(try await library.read(style.id, version: try args.string("version")))
            } catch let problem as SkyStudioStyleLibrary.ReadProblem {
                throw AIToolError(problem.message)
            }
        }
        return try AIRecipeTools.recipes(args, builtIn: builtIn, skyStudio: sky)
    }

    static func save(_ args: AIToolArguments) async throws -> AIToolResult {
        let listing = await SkyStudioStyles.shared.refreshedListing()
        return try AIRecipeTools.save(args, skyStudio: part(listing, entitled: false).styles.map(\.recipe))
    }

    private static func part(_ listing: SkyStudioStyleLibrary.Listing, entitled: Bool) -> AIRecipeSkyStudioPart {
        let origin: AIRecipeSkyStudioPart.Origin
        switch listing.origin {
        case .live: origin = .live(release: listing.release)
        case .thisMac(let fetchedAt): origin = .thisMac(release: listing.release, fetchedAt: fetchedAt)
        case .unreachable: origin = .unreachable
        case .unavailable: origin = .unavailable
        case .none: origin = .none
        }
        let styles = listing.styles.map {
            AIRecipeSkyStudioPart.Style(id: $0.id, title: $0.title, useFor: $0.useFor, version: $0.version,
                                        onThisMac: listing.stored.contains($0.sha256))
        }
        return AIRecipeSkyStudioPart(styles: styles, origin: origin, entitled: entitled)
    }

    private static func read(_ read: SkyStudioStyleLibrary.Read) -> AIRecipeSkyStudioPart.Read {
        let style = read.style
        let newer = style.minSkyCutVersion.flatMap { SkyStudioContentRules.isOlder(SkyStudioAPI.appVersion, than: $0) ? $0 : nil }
        return AIRecipeSkyStudioPart.Read(id: style.id, title: style.title, useFor: style.useFor, version: style.version,
                                          sha256: style.sha256, text: style.text, cachedAt: read.cachedAt, checkedAgainstNewer: newer)
    }
}
