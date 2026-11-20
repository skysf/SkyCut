import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - recipes / save_recipe with Sky Studio's editing styles: the async steps (SS5 plan 5.1, 5.2, 5.5)
//
// What this owns: the App's one style library (`SkyStudioStyles.shared`: the licence from SkyStudioAccount, the copies in
// Application Support) and the async steps around the pure answers in AIRecipeTools. recipes asks for the list first (a manifest
// 10 minutes old is asked again); when the name is a Sky Studio style it checks the licence (SkyStudioAccount.styleRefusal: not
// done, why, what the user can do; the presets and the user's own still work) and reads it — at the version the film records
// (TimelineState.editingStyle) unless `version` says otherwise (`latest` = the newest), with `newer_version` when Sky Studio lists a
// newer one. Every style read with an id is noted for the film (AIEditingStyleStamp), so the session's next change to it records
// the style. save_recipe asks for the list so a Sky Studio name is refused even when the account cannot read the style.
// Not this file: the answers (AIRecipeTools, pure, RecipeChecks), the list and the copies (SkyStudioStyleLibrary, StyleChecks),
// stamping the record (AIEditingStyleStamp, inside VideoEditProject.perform).

@MainActor
enum SkyStudioStyles {
    static let shared = SkyStudioStyleLibrary(licence: { SkyStudioAccount.shared.license })
}

@MainActor
enum AIRecipeSkyStudio {
    static func recipes(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let library = SkyStudioStyles.shared
        let listing = await library.refreshedListing()
        var sky = part(listing, entitled: SkyStudioAccount.shared.license.recipes)
        let builtIn = AIBuiltInRecipes.load()
        let catalog = AIRecipeCatalog(builtIn: builtIn, user: AIRecipeStore.shared.userRecipes(), skyStudio: sky.styles.map(\.recipe))
        let name = try args.string("id")
        var found = name.flatMap(catalog.find)
        // A film pinned to a style Sky Studio no longer lists still reads its version (withdrawn versions stay readable).
        let record = project.state.editingStyle
        if found == nil, let name, let record, record.isPinned, AIRecipe.slug(name) == record.id {
            found = AIRecipe(id: record.id, title: record.id, useFor: "", body: "", source: .skyStudio, version: record.version)
        }
        if let style = found, style.source == .skyStudio {
            if let refusal = SkyStudioAccount.shared.styleRefusal { throw AIToolError(refusal) }
            let asked = try args.string("version")
            // The film keeps the version it was cut with (D8, FL-15): no version asked = the one it records, matched on id + version
            // + the checksum it records (Codex review CXS1 #5), so the film gets exactly that version and the answer says which.
            let pin = record.flatMap { $0.isPinned && $0.id == style.id ? $0 : nil }
            let version = asked ?? pin?.version
            do {
                let read = try await library.read(style.id, version: version, sha256: version == pin?.version ? pin?.sha256 : nil)
                let newest = listing.styles.first { $0.id == style.id }?.version
                sky.read = Self.read(read, newer: newest == read.style.version ? nil : newest)
                if newest == nil {
                    sky.styles.append(AIRecipeSkyStudioPart.Style(id: style.id, title: read.style.title, useFor: read.style.useFor,
                                                                  version: read.style.version, onThisMac: true))
                }
            } catch let problem as SkyStudioStyleLibrary.ReadProblem {
                throw AIToolError(problem.message)
            }
        }
        let answer = try AIRecipeTools.recipes(args, builtIn: builtIn, skyStudio: sky)
        if let style = found { noteRead(style, read: sky.read, project: project) }
        return answer
    }

    static func save(_ args: AIToolArguments) async throws -> AIToolResult {
        let listing = await SkyStudioStyles.shared.refreshedListing()
        return try AIRecipeTools.save(args, skyStudio: part(listing, entitled: false).styles.map(\.recipe))
    }

    /// The style just read becomes the film's record at the session's next change to it (AIEditingStyleStamp): a Sky Studio
    /// style with its version and checksum (pinned); a preset or the user's own with SkyCut's version and its text's checksum.
    private static func noteRead(_ style: AIRecipe, read: AIRecipeSkyStudioPart.Read?, project: VideoEditProject) {
        let record: EditingStyleRecord
        if style.source == .skyStudio {
            guard let read, read.id == style.id else { return }
            record = EditingStyleRecord(id: read.id, source: style.source.rawValue, version: read.version, sha256: read.sha256)
        } else {
            record = EditingStyleRecord(id: style.id, source: style.source.rawValue, sha256: SkyStudioContentRules.sha256(style.body),
                                        skycutVersion: SkyStudioAPI.appVersion)
        }
        AIEditingStyleStamp.noteRead(record, session: AICallContext.current?.session, project: project.shortID)
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
                                        onThisMac: SkyStudioContentCache.key(id: $0.id, version: $0.version).map(listing.stored.contains) ?? false)
        }
        return AIRecipeSkyStudioPart(styles: styles, origin: origin, entitled: entitled, cardsListed: entitled && !listing.cards.isEmpty)
    }

    private static func read(_ read: SkyStudioStyleLibrary.Read, newer: String?) -> AIRecipeSkyStudioPart.Read {
        let style = read.style
        let checked = style.minSkyCutVersion.flatMap { SkyStudioContentRules.isOlder(SkyStudioAPI.appVersion, than: $0) ? $0 : nil }
        return AIRecipeSkyStudioPart.Read(id: style.id, title: style.title, useFor: style.useFor, version: style.version,
                                          sha256: style.sha256, text: style.text, cachedAt: read.cachedAt, checkedAgainstNewer: checked,
                                          newerVersion: newer)
    }
}
