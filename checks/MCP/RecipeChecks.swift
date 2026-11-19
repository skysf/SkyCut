import Foundation
import SrtFlowMCPKit

// 剪辑风格（方案第 39–41 条）：配方卡的格式（开头几行 key: value，缺了照收）、名字 → id、内置和用户的合并（同 id 盖住内置、
// 内置在前按固定顺序）、按 id / 标题找；存一套（同名改那一套、旧的挪走；内置的名字 = 用户改过的那一版）、删一套；
// recipes / save_recipe 的结果；以及 App 资源里的五张内置卡：id 齐全、每张都有「什么时候用」，**卡里提到的工具名、参数名、
// 选项值都真的存在**（工具改了名、卡没跟着改，AI 照着卡调就会报错），每张卡都是「导演手册」（标杆 / 品味 / 别这样三节，
// 共用规矩里有先出分镜表、品味、AI 剪片的通病、交片前再看一遍、从参考片学风格，docs/plans/2026-10-05-editing-aesthetics.md）。
// 卡里讲生成素材、花积分的话（条件句、报价、确认码、每日硬上限、档位）和现行合同对不对得上在 RecipeContractChecks.swift。
// Since 2026-11-19 (MCP-41): the shared rules keep pointing at the tools built for each job (toolRouteChecks), and no recipes
// answer outgrows Claude Code's 10,000-token warning (answerSizeChecks).
// 编法见 scripts/check-mcp.sh。

func runRecipeChecks() {
    runRecipeSizeChecks()
    runRecipeContractChecks()
    formatChecks()
    catalogChecks()
    storeChecks()
    builtInChecks()
    runRecipeSkyStudioChecks()
}

private func formatChecks() {
    let text = "---\nid: course-promo\ntitle: 课程推广\nuse_for: Selling my course.\n---\n# Course promo\n\nHook first.\n"
    let recipe = AIRecipe.parse(text, fileName: "whatever.md", source: .user)
    checkEqual(recipe?.id, "course-promo", "the id comes from the header")
    checkEqual(recipe?.title, "课程推广", "the title comes from the header")
    checkEqual(recipe?.useFor, "Selling my course.", "use_for is read")
    checkEqual(recipe?.body, "# Course promo\n\nHook first.", "the body is what follows the header")
    if let recipe {
        checkEqual(AIRecipe.parse(recipe.fileText, fileName: "x.md", source: .user), recipe, "fileText reads back the same")
    }
    let bare = AIRecipe.parse("# My Style\nCut fast.", fileName: "my style.md", source: .user)
    checkEqual(bare?.id, "my-style", "without a header the id comes from the file name")
    checkEqual(bare?.title, "My Style", "without a header the title is the first heading")
    check(AIRecipe.parse("---\nid: x\n---\n  \n", fileName: "x.md", source: .user) == nil, "a recipe with no text is not a recipe")
    var multiLine = AIRecipe(id: "a", title: "A\nB", useFor: "one\ntwo", body: "x", source: .user)
    multiLine = AIRecipe.parse(multiLine.fileText, fileName: "a.md", source: .user) ?? multiLine
    checkEqual(multiLine.useFor, "one two", "use_for is written on one line")
    checkEqual(AIRecipe.slug("Course Promo!"), "course-promo", "slug: lower case, spaces to dashes, symbols dropped")
    checkEqual(AIRecipe.slug("课程推广"), "课程推广", "slug keeps Chinese")
    checkEqual(AIRecipe.slug("a/b:c"), "abc", "slug drops characters a file name cannot have")
    check(AIRecipe.slug("  !! ") == nil, "a name with nothing usable has no slug")
}

private func recipe(_ id: String, _ title: String, _ source: AIRecipe.Source) -> AIRecipe {
    AIRecipe(id: id, title: title, useFor: "when \(id)", body: "body of \(id)", source: source)
}

private func catalogChecks() {
    let builtIn = [recipe("documentary", "Documentary", .builtIn), recipe("product-promo", "Product or course promo", .builtIn)]
    let user = [recipe("zoo", "Zoo style", .user), recipe("documentary", "My documentary", .user), recipe("apple", "Apple style", .user)]
    let catalog = AIRecipeCatalog(builtIn: builtIn, user: user)
    checkEqual(catalog.recipes.map(\.id), ["product-promo", "documentary", "apple", "zoo"],
               "built-in recipes first in the fixed order, then the user's by title")
    checkEqual(catalog.recipes[1].source, .customized, "a user recipe with a built-in id replaces it")
    checkEqual(catalog.recipes[1].title, "My documentary", "the user's version is the one listed")
    checkEqual(catalog.find("PRODUCT OR COURSE PROMO")?.id, "product-promo", "find by title ignores case")
    checkEqual(catalog.find("Zoo Style")?.id, "zoo", "find by title")
    checkEqual(catalog.find("product-promo")?.id, "product-promo", "find by id")
    check(catalog.find("nope") == nil, "unknown names are not found")
}

private func storeChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-recipes-\(UUID().uuidString)")
    let trash = root.appendingPathComponent("trash", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    var store = AIRecipeStore(directory: root.appendingPathComponent("Recipes", isDirectory: true))
    store.retire = { url in
        let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    let builtIn = [recipe("product-promo", "Product or course promo", .builtIn)]
    func catalog() -> AIRecipeCatalog { AIRecipeCatalog(builtIn: builtIn, user: store.userRecipes()) }

    let first = try? store.save(name: "Course promo", useFor: "My course.", body: "v1", catalog: catalog())
    checkEqual(first?.recipe.id, "course-promo", "a new recipe gets an id from its name")
    checkEqual(first?.file.lastPathComponent, "course-promo.md", "one .md per recipe, named after the id")
    check(first?.previousVersion == nil, "nothing is moved away for a new recipe")
    let second = try? store.save(name: "course promo", useFor: "My course, v2.", body: "v2", catalog: catalog())
    check(second?.previousVersion != nil, "saving under the same name moves the old version away first")
    checkEqual(store.userRecipes().map(\.body), ["v2"], "the same name replaces the recipe")
    let custom = try? store.save(name: "Product or course promo", useFor: "Mine.", body: "my promo", catalog: catalog())
    checkEqual(custom?.recipe.id, "product-promo", "a built-in's name makes the user's version of it")
    checkEqual(catalog().find("product-promo")?.source, .customized, "and it replaces the built-in in the list")
    checkThrows("an empty text is refused") { _ = try store.save(name: "x", useFor: "y", body: "  ", catalog: catalog()) }
    checkThrows("a name without letters is refused") { _ = try store.save(name: "!!", useFor: "y", body: "z", catalog: catalog()) }
    if let mine = catalog().find("product-promo") {
        try? store.remove(mine)
        checkEqual(catalog().find("product-promo")?.source, .builtIn, "deleting the user's version brings the built-in back")
    }

    // 工具：列表带 id、标题、什么时候用、来源；全文后面接上共用的规矩；找不到时说出有哪些。
    let list = try? AIRecipeTools.recipes(args([:]), store: store, builtIn: builtIn, sharedRules: "SHARED")
    checkEqual(list?.payload["recipes"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["product-promo", "course-promo"],
               "recipes lists every recipe")
    checkEqual(list?.payload["recipes"]?.arrayValue?.last?["source"]?.stringValue, "yours", "the source is shown")
    let full = try? AIRecipeTools.recipes(args(["id": "Course promo"]), store: store, builtIn: builtIn, sharedRules: "SHARED")
    checkEqual(full?.payload["text"]?.stringValue, "v2\n\nSHARED", "the full recipe ends with the shared rules")
    checkThrows("an unknown recipe is refused") {
        _ = try AIRecipeTools.recipes(args(["id": "nope"]), store: store, builtIn: builtIn, sharedRules: "")
    }
    checkThrows("save_recipe needs use_for") {
        _ = try AIRecipeTools.save(args(["name": "a", "text": "b"]), store: store, builtIn: builtIn)
    }
    sharedRulesOnlyChecks(store: store, builtIn: builtIn, catalog: catalog)
}

/// Edits in no style read only the shared rules (2026-11-16, docs/architecture/ai-control-mcp.md section 4, item 32):
/// recipes answers the reserved id in any spelling, a style with that name still wins (and still ends with the rules),
/// and the parameter description and the workflows guide topic point there.
private func sharedRulesOnlyChecks(store: AIRecipeStore, builtIn: [AIRecipe], catalog: () -> AIRecipeCatalog) {
    let id = MCPRecipeTools.sharedRulesID
    for spelling in [id, "Shared rules", "shared_rules"] {
        let rules = try? AIRecipeTools.recipes(args(["id": .string(spelling)]), store: store, builtIn: builtIn, sharedRules: "SHARED")
        checkEqual(rules?.payload["text"]?.stringValue, "SHARED", "recipes id=\(spelling) returns only the shared rules")
        checkEqual(rules?.payload["id"]?.stringValue, id, "recipes id=\(spelling) says it answered \(id)")
    }
    let parameter = MCPToolName.recipes.definition.json["inputSchema"]?["properties"]?["id"]?["description"]?.stringValue ?? ""
    check(parameter.contains(id), "the recipes id parameter tells the AI about \(id): \(parameter)")
    let workflows = MCPGuideTopics.topic(named: "workflows")?.sections.map(\.text).joined(separator: "\n") ?? ""
    check(workflows.contains("recipes id=\(id)"), "the workflows guide topic sends edits in no style to recipes id=\(id)")
    _ = try? store.save(name: "Shared rules", useFor: "Mine.", body: "my rules", catalog: catalog())
    let mine = try? AIRecipeTools.recipes(args(["id": .string(id)]), store: store, builtIn: builtIn, sharedRules: "SHARED")
    checkEqual(mine?.payload["text"]?.stringValue, "my rules\n\nSHARED", "a style of the user's called \(id) wins, and still ends with the shared rules")
}

/// App 资源里的内置卡（自检从仓库根目录跑，直接读 Sources/SrtFlow/Resources）。
private func builtInChecks() {
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    let builtIn = AIBuiltInRecipes.load(from: [resources])
    checkEqual(builtIn.map(\.id).sorted(), AIRecipeCatalog.builtInOrder.sorted(), "the five built-in recipes are in the app")
    for recipe in builtIn {
        check(!recipe.useFor.isEmpty && !recipe.title.isEmpty, "\(recipe.id) says when to use it and has a title")
    }
    let shared = AIBuiltInRecipes.sharedRules(from: [resources])
    check(shared.contains("Rules for every recipe"), "the shared rules are in the app")
    let known = catalogKnownNames()
    for (name, text) in builtIn.map({ ($0.id, $0.body) }) + [("shared rules", shared)] {
        let unknown = catalogIdentifiers(in: text).filter { !known.contains($0) }
        check(unknown.isEmpty, "\(name) mentions names SrtFlow's tools do not have: \(unknown.sorted())")
    }
    // 品味写在卡里才管用（2026-10-05）：改卡时把这几节丢了，AI 就回到默认的剪法（镜头一样长、全是叠化、每个镜头都慢推）。
    for recipe in builtIn {
        for section in ["## The bar", "## Taste", "## Avoid"] {
            check(recipe.body.contains(section), "\(recipe.id) has its \(section) section")
        }
        check(recipe.body.contains("Look again before export"), "\(recipe.id)'s checklist ends with the shared look-again review")
    }
    for section in ["## Plan before you cut", "## Taste for every style", "## AI tells to avoid", "## Look again before export",
                    "## Learning a style from a reference video"] {
        check(shared.contains(section), "the shared rules have \(section)")
    }
    // The shared editing rules for every SkyCut user (2026-11-16): four sections every style keeps, above the style cards.
    // Dropping one when editing the file would quietly bring the old habits back (a silent car, music ducked 15 dB, a card
    // that flashes by), so each is pinned like the five above.
    for section in ["## Sound belongs to the picture", "## Cuts", "## Voice and music", "## Title cards"] {
        check(shared.contains("\n" + section + "\n"), "the shared rules have \(section)")
    }
    toolRouteChecks(shared: shared)
    answerSizeChecks(builtIn: builtIn, shared: shared)
}

/// The shared rules send the AI to the tools built for each job (2026-11-19, MCP-41): the AI uses what the rules point at,
/// so a rewrite that drops a pointer quietly brings back the old guesswork (whole-band levels for a covered line, music
/// slid by ear, no report before delivery). Each phrase is pinned in the section whose rule needs it.
private func toolRouteChecks(shared: String) {
    let routes: [(section: String, phrases: [String])] = [
        ("Sound belongs to the picture", ["describe=true", "voice_band_db"]),
        ("Cuts", ["set_transition after_clip_id", "source_cuts"]),
        ("Voice and music", ["listen voice=", "voice_band_db", "stops", "hit_at"]),
        ("Title cards", ["motion_preset", "hit_at"]),
        ("Taste for every style", ["strongest_accents", "ends_at", "hit_at"]),
        ("Look again before export", ["listen mix=true", "inspect_video", "preset=quick_review", "intentional="])
    ]
    for route in routes {
        let text = shared.components(separatedBy: "\n## \(route.section)\n").dropFirst().first?
            .components(separatedBy: "\n## ").first ?? ""
        for phrase in route.phrases {
            check(text.contains(phrase), "the shared rules' \(route.section) section still sends the AI to \(phrase)")
        }
    }
}

/// One recipes answer is a card plus the whole shared rules, as one JSON text (docs/architecture/ai-control-mcp.md section 4,
/// item 32): Claude Code warns above 10,000 tokens, about 36,000 characters at this repo's 3.6 characters a token. New rules
/// make room first; the line is not raised.
let recipeAnswerLimit = 36_000

private func answerSizeChecks(builtIn: [AIRecipe], shared: String) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-recipe-size-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    var largest = (id: "", size: 0)
    for id in builtIn.map(\.id) + [MCPRecipeTools.sharedRulesID] {
        let reply = try? AIRecipeTools.recipes(args(["id": .string(id)]), store: AIRecipeStore(directory: folder),
                                               builtIn: builtIn, sharedRules: shared)
        let size = reply?.payload.encodedString().utf16.count ?? 0
        check(size > 0 && size <= recipeAnswerLimit,
              "recipes id=\(id) answers in at most \(recipeAnswerLimit) characters (got \(size)): make room before adding rules")
        if size > largest.size { largest = (id, size) }
    }
    print("MCP recipes: largest answer \(largest.size)/\(recipeAnswerLimit) UTF-16 units (\(largest.id)).")
}
