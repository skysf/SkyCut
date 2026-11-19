import Foundation
import SrtFlowMCPKit

// Sky Studio's editing styles in recipes / save_recipe and in Settings (2026-11-19, SS5 plan 5.1–5.3; docs/architecture/ai-control-
// mcp.md item 32): one list (presets, Sky Studio's, the user's), a Sky Studio style can't be shadowed, available / why, where the
// list came from, the read answer (version, sha256, this Mac's copy, the shared rules when they fit, else a pointer and the style
// whole), version only for Sky Studio styles, save_recipe refuses their names, the Settings rows. The answers are pure: the Sky
// Studio side is built by hand here (AIRecipeSkyStudioPart); fetching, copies and the licence are in check-sky-studio.sh.

func runRecipeSkyStudioChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-recipes-sky-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var store = AIRecipeStore(directory: root.appendingPathComponent("Recipes", isDirectory: true))
    let trash = root.appendingPathComponent("trash", isDirectory: true)
    try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    store.retire = { url in
        let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    skyCatalogChecks()
    skyListChecks(store)
    skyReadChecks(store)
    skySaveChecks(store)
    skySettingsRowChecks()
    skyGuideChecks()
}

private let presets = [
    AIRecipe(id: "product-promo", title: "Product or course promo", useFor: "promo", body: "promo body", source: .builtIn),
    AIRecipe(id: "cinematic-opening", title: "Cinematic opening", useFor: "opening", body: "opening body", source: .builtIn)
]

private func trailer(onThisMac: Bool = false) -> AIRecipeSkyStudioPart.Style {
    AIRecipeSkyStudioPart.Style(id: "film-trailer", title: "Film trailer", useFor: "A story trailer.", version: "1.0", onThisMac: onThisMac)
}

private func part(entitled: Bool = true, origin: AIRecipeSkyStudioPart.Origin = .live(release: 1),
                  styles: [AIRecipeSkyStudioPart.Style] = [trailer()], read: AIRecipeSkyStudioPart.Read? = nil) -> AIRecipeSkyStudioPart {
    AIRecipeSkyStudioPart(styles: styles, origin: origin, entitled: entitled, read: read)
}

private func trailerRead(text: String = "# Film trailer\n\nThree acts.", cachedAt: Date? = nil,
                         newer: String? = nil) -> AIRecipeSkyStudioPart.Read {
    AIRecipeSkyStudioPart.Read(id: "film-trailer", title: "Film trailer", useFor: "A story trailer.", version: "1.0",
                               sha256: String(repeating: "a", count: 64), text: text, cachedAt: cachedAt, checkedAgainstNewer: newer)
}

private func skyCatalogChecks() {
    let mine = [AIRecipe(id: "film-trailer", title: "My trailer", useFor: "", body: "mine", source: .user),
                AIRecipe(id: "zoo", title: "FILM TRAILER", useFor: "", body: "zoo", source: .user),
                AIRecipe(id: "apple", title: "Apple style", useFor: "", body: "apple", source: .user)]
    let clash = AIRecipe(id: "product-promo", title: "Server promo", useFor: "", body: "", source: .skyStudio, version: "1.0")
    let catalog = AIRecipeCatalog(builtIn: presets, user: mine, skyStudio: [trailer().recipe, clash])
    checkEqual(catalog.recipes.map(\.id), ["product-promo", "cinematic-opening", "film-trailer", "apple"],
               "presets first, then Sky Studio's, then the user's; a Sky Studio style with a preset's id is left out")
    checkEqual(catalog.recipes[0].source, .builtIn, "a preset's id always means the preset")
    checkEqual(catalog.recipes[2].source, .skyStudio, "the Sky Studio style is listed as sky_studio")
    checkEqual(catalog.hiddenBySkyStudio.map(\.id).sorted(), ["film-trailer", "zoo"],
               "the user's files with a Sky Studio style's id or title are hidden, not listed")
    checkEqual(catalog.find("Film Trailer")?.source, .skyStudio, "the Sky Studio style's title finds it")
    checkEqual(catalog.find("film_trailer")?.source, .skyStudio, "and so does its id in any spelling")
    checkEqual(AIRecipeCatalog(builtIn: presets, user: mine).recipes.map(\.id), ["product-promo", "cinematic-opening", "apple", "zoo", "film-trailer"],
               "without Sky Studio the user's styles are all listed as before")
}

private func skyListChecks(_ store: AIRecipeStore) {
    func list(_ sky: AIRecipeSkyStudioPart) -> JSONValue? {
        try? AIRecipeTools.recipes(args([:]), store: store, builtIn: presets, sharedRules: "SHARED", skyStudio: sky).payload
    }
    func trailerEntry(_ payload: JSONValue?) -> JSONValue? {
        payload?["recipes"]?.arrayValue?.first { $0["id"]?.stringValue == "film-trailer" }
    }
    let live = list(part())
    checkEqual(trailerEntry(live)?["source"]?.stringValue, "sky_studio", "the Sky Studio style is listed with source sky_studio")
    checkEqual(trailerEntry(live)?["version"]?.stringValue, "1.0", "with its version")
    check(trailerEntry(live)?["available"] == nil, "readable: no available field")
    checkEqual(live?["sky_studio"]?.stringValue, "Sky Studio's styles (release 1) were checked with Sky Studio just now.",
               "one line says where the Sky Studio part came from")
    check(live?["next_step"]?.stringValue?.contains("available false") == false, "nothing locked, nothing said about it")

    let locked = list(part(entitled: false))
    checkEqual(trailerEntry(locked)?["available"], .bool(false), "not entitled: available false")
    checkEqual(trailerEntry(locked)?["why"]?.stringValue, "needs SkyCut Pro or the SkyCut trial", "and why")
    check(locked?["next_step"]?.stringValue?.contains("available false cannot be read now") == true, "next_step says to pick another")

    let fetched = Date(timeIntervalSince1970: 1_795_000_000)
    let offline = list(part(origin: .thisMac(release: 1, fetchedAt: fetched)))
    checkEqual(trailerEntry(offline)?["why"]?.stringValue, "Sky Studio cannot be reached and this Mac has no copy",
               "offline without a copy: why")
    check(offline?["sky_studio"]?.stringValue?.contains("this Mac's copy from 2026-") == true, "offline: the list is this Mac's copy, dated")
    let offlineCopy = list(part(origin: .thisMac(release: 1, fetchedAt: fetched), styles: [trailer(onThisMac: true)]))
    check(trailerEntry(offlineCopy)?["available"] == nil, "offline with a copy here: readable")
    let unreachable = list(part(origin: .unreachable, styles: []))
    check(unreachable?["sky_studio"]?.stringValue?.contains("only the presets and the user's own are listed") == true,
          "unreachable with nothing here: said plainly")
    // Nothing published yet (Sky Studio answers 503 content_unavailable): said plainly, the presets still listed and readable.
    let none = list(part(origin: .unavailable, styles: []))
    checkEqual(none?["sky_studio"]?.stringValue, "No Sky Studio editing styles are available yet: only the presets and the user's own are listed.",
               "nothing published yet: said plainly, not as unreachable")
    checkEqual(none?["recipes"]?.arrayValue?.compactMap { $0["source"]?.stringValue }, ["built_in", "built_in"], "and the presets are listed")
    checkEqual((try? AIRecipeTools.recipes(args(["id": "product-promo"]), store: store, builtIn: presets, sharedRules: "",
                                           skyStudio: part(origin: .unavailable, styles: [])))?.payload["text"]?.stringValue,
               "promo body", "and a preset still reads")
    checkThrows("a Sky Studio name before anything is published says none is available yet") {
        do {
            _ = try AIRecipeTools.recipes(args(["id": "film-trailer"]), store: store, builtIn: presets, sharedRules: "",
                                          skyStudio: part(origin: .unavailable, styles: []))
        } catch let error as AIToolError {
            check(error.message.hasSuffix("No Sky Studio editing styles are available yet."), "the error says none is available yet")
            throw error
        }
    }
    check(list(part(origin: .none, styles: []))?["sky_studio"] == nil, "no key: nothing about Sky Studio")
    checkThrows("an unknown style while Sky Studio is unreachable says so") {
        do {
            _ = try AIRecipeTools.recipes(args(["id": "nope"]), store: store, builtIn: presets, sharedRules: "",
                                          skyStudio: part(origin: .unreachable, styles: []))
        } catch let error as AIToolError {
            check(error.message.contains("Sky Studio could not be reached"), "the error says Sky Studio could not be reached")
            throw error
        }
    }
}

private func skyReadChecks(_ store: AIRecipeStore) {
    let shared = "SHARED RULES"
    let answer = try? AIRecipeTools.recipes(args(["id": "Film trailer"]), store: store, builtIn: presets, sharedRules: shared,
                                            skyStudio: part(read: trailerRead()))
    checkEqual(answer?.payload["text"]?.stringValue, "# Film trailer\n\nThree acts.\n\n" + shared, "the style followed by the shared rules")
    checkEqual(answer?.payload["source"]?.stringValue, "sky_studio", "source sky_studio")
    checkEqual(answer?.payload["version"]?.stringValue, "1.0", "its version")
    checkEqual(answer?.payload["sha256"]?.stringValue, String(repeating: "a", count: 64), "its checksum")
    check(answer?.payload["cached"] == nil && answer?.payload["fetched_at"] == nil, "fetched just now: no cached / fetched_at")
    check(answer?.payload["next_step"]?.stringValue?.contains("never save it") == true, "next_step: not the user's to save")

    let cached = try? AIRecipeTools.recipes(args(["id": "film-trailer"]), store: store, builtIn: presets, sharedRules: shared,
                                            skyStudio: part(read: trailerRead(cachedAt: Date(timeIntervalSince1970: 1_795_000_000), newer: "0.20.0")))
    checkEqual(cached?.payload["cached"], .bool(true), "this Mac's copy says cached")
    checkEqual(cached?.payload["fetched_at"]?.stringValue, "2026-11-18T11:06:40Z", "and when it was fetched")
    check(cached?.payload["note"]?.stringValue?.contains("SkyCut 0.20.0") == true, "checked against a newer SkyCut: a note")

    // Too long for one answer with the shared rules: the style whole, alone, and a pointer to recipes id=shared-rules.
    let long = "# Film trailer\n\n" + String(repeating: "Hold the shot. ", count: 1_000)
    let rules = String(repeating: "Rule. ", count: 3_500)
    let split = try? AIRecipeTools.recipes(args(["id": "film-trailer"]), store: store, builtIn: presets, sharedRules: rules,
                                           skyStudio: part(read: trailerRead(text: long)))
    checkEqual(split?.payload["text"]?.stringValue, long, "too long with the rules: the style alone, never cut")
    check(split?.payload["next_step"]?.stringValue?.contains("recipes id=\(MCPRecipeTools.sharedRulesID)") == true,
          "and next_step says to read the shared rules")
    let size = split?.payload.encodedString().utf16.count ?? .max
    check(size <= recipeAnswerLimit, "the split answer fits (\(size))")
    checkEqual(AIRecipeTools.answerLimit, 36_000, "the App splits at Claude Code's warning line, 36,000 characters")

    checkThrows("a Sky Studio style that was not read is not answered with an empty text") {
        _ = try AIRecipeTools.recipes(args(["id": "film-trailer"]), store: store, builtIn: presets, sharedRules: shared, skyStudio: part())
    }
    checkThrows("version is only for Sky Studio styles") {
        _ = try AIRecipeTools.recipes(args(["id": "product-promo", "version": "1.0"]), store: store, builtIn: presets, sharedRules: shared)
    }
    checkThrows("version goes with id") {
        _ = try AIRecipeTools.recipes(args(["version": "1.0"]), store: store, builtIn: presets, sharedRules: shared)
    }
    let latest = try? AIRecipeTools.recipes(args(["id": "product-promo", "version": "latest"]), store: store, builtIn: presets, sharedRules: shared)
    checkEqual(latest?.payload["id"]?.stringValue, "product-promo", "version latest is the current one for any style")
    let definition = MCPToolName.recipes.definition.json["inputSchema"]?["properties"]?["version"]?["description"]?.stringValue ?? ""
    check(definition.contains("Sky Studio"), "the recipes version parameter says it is for Sky Studio styles: \(definition)")
}

private func skySaveChecks(_ store: AIRecipeStore) {
    let sky = [trailer().recipe]
    for name in ["Film trailer", "film-trailer", "FILM_TRAILER"] {
        checkThrows("save_recipe refuses the Sky Studio name \(name)") {
            _ = try AIRecipeTools.save(args(["name": .string(name), "use_for": "x", "text": "y"]), store: store, builtIn: presets, skyStudio: sky)
        }
    }
    check(!store.userRecipes().contains { $0.id == "film-trailer" }, "nothing was written for a Sky Studio name")
    let promo = try? AIRecipeTools.save(args(["name": "Product or course promo", "use_for": "Mine.", "text": "my promo"]),
                                        store: store, builtIn: presets, skyStudio: sky)
    checkEqual(promo?.payload["replaces_built_in"]?.stringValue, "product-promo", "a preset stays saveable as the user's own")
    let own = try? AIRecipeTools.save(args(["name": "Trailer, my way", "use_for": "Mine.", "text": "mine"]),
                                      store: store, builtIn: presets, skyStudio: sky)
    checkEqual(own?.payload["saved"]?.stringValue, "trailer-my-way", "another name is saved as before")
}

private func skySettingsRowChecks() {
    let mine = [AIRecipe(id: "film-trailer", title: "My trailer", useFor: "", body: "mine", source: .user),
                AIRecipe(id: "product-promo", title: "My promo", useFor: "", body: "mine", source: .user),
                AIRecipe(id: "apple", title: "Apple style", useFor: "", body: "apple", source: .user)]
    let catalog = AIRecipeCatalog(builtIn: presets, user: mine, skyStudio: [trailer().recipe])
    let rows = AIRecipeSettingsRow.rows(catalog, skyStudioEntitled: true)
    checkEqual(rows.map(\.kind), [.yours(replacesPreset: true), .preset, .skyStudio(version: "1.0", locked: false),
                                  .yours(replacesPreset: false), .hiddenBySkyStudio],
               "Settings lists every source: the user's version of a preset, a preset, Sky Studio's, the user's own, the hidden file")
    checkEqual(rows.map(\.hasFile), [true, false, false, true, true], "only the user's own have a file (Show in Finder / Delete)")
    checkEqual(Set(rows.map(\.id)).count, rows.count, "row ids are unique even when a hidden file shares the Sky Studio id")
    checkEqual(AIRecipeSettingsRow.rows(catalog, skyStudioEntitled: false)[2].kind, .skyStudio(version: "1.0", locked: true),
               "not entitled: the Sky Studio row is locked")
}

private func skyGuideChecks() {
    let topic = MCPGuideTopics.topic(named: "recipes")
    let section = topic?.sections.first { $0.name == "sky_studio" }?.text ?? ""
    check(section.contains("save_recipe") && section.contains("Pro"), "the recipes guide topic explains Sky Studio's styles")
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    let opening = AIBuiltInRecipes.load(from: [resources]).first { $0.id == "cinematic-opening" }
    check(opening?.useFor.contains("film-trailer") == true, "the cinematic opening points a whole story trailer at film-trailer (D5)")
}
