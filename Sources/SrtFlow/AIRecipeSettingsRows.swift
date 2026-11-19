import Foundation

// MARK: - The rows of Settings → Editing & Voices → Editing styles (pure value, SS5 plan 5.3, MCP-63)
//
// What this owns: one list of every style AI can follow, each with where it comes from: the presets, Sky Studio's (with their
// version, or locked when the licence leaves them out), the user's own (Show in Finder / Delete, as before), and the user's
// files a Sky Studio style of the same id or title hides (listed with a rename hint, so the user knows why AI ignores them).
// The order is the recipes tool's order (AIRecipeCatalog), hidden files last.
// Not this file: drawing them and the buttons (AIRecipeSettingsList), the catalog rules (AIRecipe), Sky Studio (SkyStudioStyleLibrary).

struct AIRecipeSettingsRow: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case preset
        /// `locked`: the licence leaves Sky Studio's styles out now ("needs SkyCut Pro").
        case skyStudio(version: String, locked: Bool)
        case yours(replacesPreset: Bool)
        /// The user's file a Sky Studio style hides.
        case hiddenBySkyStudio
    }

    var recipe: AIRecipe
    var kind: Kind

    /// Unique in the list: a hidden file can share its id with the Sky Studio style that hides it.
    var id: String {
        switch kind {
        case .preset: return "preset:" + recipe.id
        case .skyStudio: return "sky-studio:" + recipe.id
        case .yours: return "yours:" + recipe.id
        case .hiddenBySkyStudio: return "hidden:" + recipe.id
        }
    }

    /// Only the user's own have a file to show or delete.
    var hasFile: Bool {
        switch kind {
        case .yours, .hiddenBySkyStudio: return true
        case .preset, .skyStudio: return false
        }
    }

    static func rows(_ catalog: AIRecipeCatalog, skyStudioEntitled: Bool) -> [AIRecipeSettingsRow] {
        let listed = catalog.recipes.map { recipe -> AIRecipeSettingsRow in
            switch recipe.source {
            case .builtIn: return AIRecipeSettingsRow(recipe: recipe, kind: .preset)
            case .skyStudio: return AIRecipeSettingsRow(recipe: recipe, kind: .skyStudio(version: recipe.version ?? "", locked: !skyStudioEntitled))
            case .user: return AIRecipeSettingsRow(recipe: recipe, kind: .yours(replacesPreset: false))
            case .customized: return AIRecipeSettingsRow(recipe: recipe, kind: .yours(replacesPreset: true))
            }
        }
        return listed + catalog.hiddenBySkyStudio.map { AIRecipeSettingsRow(recipe: $0, kind: .hiddenBySkyStudio) }
    }
}
