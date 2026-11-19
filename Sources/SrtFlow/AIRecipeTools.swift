import Foundation
import SrtFlowMCPKit

// MARK: - 工具：剪辑风格（recipes 只读、save_recipe 写）
//
// 管什么：`recipes` 列出全部剪辑风格（每套一句「什么时候用」）、按名字回全文（后面接上所有剪辑风格共用的规矩）；
// `save_recipe` 存用户自己的一套（用户开口才存；同名改那一套、旧的进废纸篓；和内置同名 = 用户改过的那一版）。
// 剪辑风格由 AI 自己挑（方案第 39 条），总说明里写着「剪整片之前先挑一套、一句话告诉用户」。
// `recipes id=shared-rules` (MCPRecipeTools.sharedRulesID) returns only the shared rules, for edits in no style (2026-11-16).
// Sky Studio's styles (2026-11-19, SS5 plan 5.1, 5.2) are listed with their version and, when one cannot be read now, why;
// reading one returns its version, checksum and whether it came from this Mac's copy, followed by the shared rules when both
// fit one answer (`answerLimit`), else alone with a pointer to recipes id=shared-rules. save_recipe refuses their names. A film
// keeps the version it was cut with: reading an older one says `newer_version` (SS5 plan 5.5).
// These answers are pure: the Sky Studio side is gathered first (AIRecipeSkyStudioPart, by AIRecipeSkyStudio).
// 不管什么：卡的格式和合并（AIRecipe）、读写文件（AIRecipeStore）、设置里的列表（AIRecipeSettingsList，存完由路由叫它刷新）、
// asking Sky Studio and the licence (AIRecipeSkyStudio, SkyStudioStyleLibrary).

enum AIRecipeTools {
    /// One recipes answer, as the App encodes it, stays within this many UTF-16 units: about 10,000 tokens, where Claude Code
    /// starts warning (docs/architecture/ai-control-mcp.md section 4, item 32). Built-in answers are checked against it; a Sky
    /// Studio style that does not fit with the shared rules comes alone.
    static let answerLimit = 36_000

    // MARK: recipes

    static func recipes(_ args: AIToolArguments, store: AIRecipeStore = .shared,
                        builtIn: [AIRecipe] = AIBuiltInRecipes.load(), sharedRules: String = AIBuiltInRecipes.sharedRules(),
                        skyStudio: AIRecipeSkyStudioPart = AIRecipeSkyStudioPart()) throws -> AIToolResult {
        let catalog = AIRecipeCatalog(builtIn: builtIn, user: store.userRecipes(), skyStudio: skyStudio.styles.map(\.recipe))
        let version = try args.string("version").flatMap { $0.lowercased() == "latest" ? nil : $0 }
        guard let name = try args.string("id"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            if version != nil { throw AIToolError("version goes with id: the Sky Studio style to read.") }
            return list(catalog, skyStudio: skyStudio, folder: store.directory)
        }
        guard let recipe = catalog.find(name) else {
            // Only the shared rules, for edits in no style (2026-11-16). A style with this id or title wins above.
            if AIRecipe.slug(name) == MCPRecipeTools.sharedRulesID, version == nil { return sharedRulesOnly(sharedRules) }
            let ids = catalog.recipes.map(\.id).joined(separator: ", ")
            let unreachable = skyStudio.origin == .unreachable ? " Sky Studio could not be reached, so its styles are not listed now." : ""
            throw AIToolError("There is no editing style called \(name). Styles: \(ids); \(MCPRecipeTools.sharedRulesID) "
                + "has only the rules every style follows." + unreachable)
        }
        if recipe.source == .skyStudio {
            guard let read = skyStudio.read, read.id == recipe.id else {
                throw AIToolError("\(recipe.title) is a Sky Studio style SkyCut could not read just now; call recipes again.")
            }
            return skyStudioAnswer(read, sharedRules: sharedRules)
        }
        if version != nil {
            throw AIToolError("version is only for Sky Studio styles (source sky_studio); \(recipe.id) has no versions.")
        }
        var text = recipe.body
        if !sharedRules.isEmpty { text += "\n\n" + sharedRules }
        return .ok([
            "id": .string(recipe.id),
            "title": .string(recipe.title),
            "use_for": .string(recipe.useFor),
            "source": .string(recipe.source.rawValue),
            "text": .string(text)
        ])
    }

    private static func list(_ catalog: AIRecipeCatalog, skyStudio: AIRecipeSkyStudioPart, folder: URL) -> AIToolResult {
        var locked = false
        let entries = catalog.recipes.map { recipe -> JSONValue in
            var fields: [String: JSONValue] = [
                "id": .string(recipe.id),
                "title": .string(recipe.title),
                "use_for": .string(recipe.useFor),
                "source": .string(recipe.source.rawValue)
            ]
            if recipe.source == .skyStudio, let style = skyStudio.styles.first(where: { $0.id == recipe.id }) {
                fields["version"] = .string(style.version)
                if let why = skyStudio.unavailable(style) {
                    fields["available"] = false
                    fields["why"] = .string(why)
                    locked = true
                }
            }
            return .object(fields)
        }
        var object: [String: JSONValue] = [
            "recipes": .array(entries),
            "folder": .string((folder.path as NSString).abbreviatingWithTildeInPath),
            "next_step": .string("""
            Pick the editing style that fits what the user wants, tell the user in one sentence which one you follow \
            (call them editing styles; 剪辑风格 in Chinese), then read it with recipes {id}. The user's own words always \
            win over the style. For an edit in no style, read only the rules every style follows with recipes \
            {id: \(MCPRecipeTools.sharedRulesID)}.
            """ + (locked ? " A style with available false cannot be read now (why says why): pick another." : ""))
        ]
        if let line = skyStudio.originLine { object["sky_studio"] = .string(line) }
        return .ok(.object(object))
    }

    /// One Sky Studio style: its text and version, followed by the shared rules when both fit one answer.
    private static func skyStudioAnswer(_ read: AIRecipeSkyStudioPart.Read, sharedRules: String) -> AIToolResult {
        var object: [String: JSONValue] = [
            "id": .string(read.id),
            "title": .string(read.title),
            "use_for": .string(read.useFor),
            "source": .string(AIRecipe.Source.skyStudio.rawValue),
            "version": .string(read.version),
            "sha256": .string(read.sha256)
        ]
        if let cachedAt = read.cachedAt {
            object["cached"] = true
            object["fetched_at"] = .string(AIRecipeSkyStudioPart.day(cachedAt))
        }
        if let newer = read.checkedAgainstNewer {
            object["note"] = .string("This style was checked against SkyCut \(newer) and this SkyCut is older: a call it suggests may "
                + "fail. If one does, tell the user to update SkyCut.")
        }
        var follow = "This style is from Sky Studio (\(read.title) \(read.version)): follow it for this video, and the user's own "
            + "words win. It is not the user's: never save it, or a copy of it, with save_recipe."
        if let newer = read.newerVersion {
            object["newer_version"] = .string(newer)
            follow += " This film keeps \(read.version); Sky Studio has \(newer). Move to it only if the user asks: recipes id=\(read.id) "
                + "version=latest."
        }
        object["text"] = .string(sharedRules.isEmpty ? read.text : read.text + "\n\n" + sharedRules)
        object["next_step"] = .string(follow)
        if !sharedRules.isEmpty, JSONValue.object(object).encodedString().utf16.count > answerLimit {
            object["text"] = .string(read.text)
            object["next_step"] = .string(follow + " The rules every style follows did not fit in this answer: read them with "
                + "recipes id=\(MCPRecipeTools.sharedRulesID) before cutting.")
        }
        return .ok(.object(object))
    }

    /// `recipes id=shared-rules`: the rules every style follows, without a style in front of them.
    private static func sharedRulesOnly(_ sharedRules: String) -> AIToolResult {
        .ok([
            "id": .string(MCPRecipeTools.sharedRulesID),
            "title": "Rules every style follows",
            "use_for": "Every edit, with or without an editing style.",
            "text": .string(sharedRules)
        ])
    }

    // MARK: save_recipe

    /// `skyStudio`: the styles Sky Studio lists now; their ids and titles are refused (AIRecipeStore.save).
    static func save(_ args: AIToolArguments, store: AIRecipeStore = .shared,
                     builtIn: [AIRecipe] = AIBuiltInRecipes.load(), skyStudio: [AIRecipe] = []) throws -> AIToolResult {
        let name = try args.requiredString("name")
        let useFor = try args.requiredString("use_for")
        let text = try args.requiredString("text")
        let catalog = AIRecipeCatalog(builtIn: builtIn, user: store.userRecipes(), skyStudio: skyStudio)
        let saved = try store.save(name: name, useFor: useFor, body: text, catalog: catalog)
        var result: [String: JSONValue] = [
            "saved": .string(saved.recipe.id),
            "title": .string(saved.recipe.title),
            "file": .string((saved.file.path as NSString).abbreviatingWithTildeInPath)
        ]
        if saved.recipe.source == .customized { result["replaces_built_in"] = .string(saved.recipe.id) }
        if let previous = saved.previousVersion {
            result["previous_version"] = .string("moved to the Trash: \((previous.path as NSString).abbreviatingWithTildeInPath)")
        }
        return .ok(.object(result))
    }
}
