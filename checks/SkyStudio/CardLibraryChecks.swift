import Foundation
import SrtFlowMCPKit

// craft_cards on a fake Sky Studio (2026-11-20, SS5 plan 5.6): every path SkyStudioStyleLibrary.readCard takes, and the answer the
// AI reads (AICraftCardsAnswer). Not entitled: refused, nothing asked. Nothing published (the list answers 503, or lists the trailer
// alone): "none published yet", nothing asked. The entry page, a catalogue and a card fetched by the version the list names and kept;
// read again = confirmed with its ETag (cached + fetched_at); an unknown group or card said plainly without asking; offline = this
// Mac's copy, or plain words; Sky Studio's refusal wins over the copy (403 machine_not_registered / machine_limit_reached in plain
// words); a 503 serves the copy; a page withdrawn since (404); a text that is not the listed one refused; a licence that ends
// mid-fetch keeps nothing; a /me without recipes deletes the card copies, removing the key everything; a new rev is fetched while
// the old copy stays. Shapes and routes are in CardContentChecks.swift; StyleEnvironment / makeLibrary come from StyleLibraryChecks.

@MainActor
func runCardLibraryChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-card-library-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    await nothingPublishedChecks(root.appendingPathComponent("empty"))
    let env = StyleEnvironment(entitled: false)
    let library = makeLibrary(root.appendingPathComponent("main"), env)
    let pages = [entryAnswer(), groupAnswer(), cardAnswer(), cardAnswer("513", rev: 1, related: [], text: "## What it is\nA held look.")]
    serveCards(cardManifest(entry: pages[0], groups: [pages[1]], cards: [pages[2], pages[3]]), pages: pages)

    // Not entitled: refused before anything is asked for a page.
    _ = await library.refreshedListing()
    await expectCardProblem(library, .entry, SkyStudioCardWords.needsPlan, "not entitled: refused")
    check(cardRequests().isEmpty, "not entitled: no card page was asked from Sky Studio")

    // Entitled: the entry page, a catalogue and a card are fetched by the version the list names, and kept.
    env.licence = StyleEnvironment.licence(true)
    let entry = try? await library.readCard(.entry)
    check(entry != nil && entry?.cachedAt == nil, "the entry page comes from Sky Studio")
    checkEqual((try? await library.readCard(.group("sound")))?.page.title, "Sound", "a group's catalogue")
    let card = try? await library.readCard(.card("512"))
    checkEqual(card?.page.related, ["511", "518"], "one card with its related cards")
    checkEqual(cardRequests(), ["/content/cards?version=1", "/content/cards?group=sound&version=2", "/content/cards/512?version=2"],
               "each asked by the version the list names")
    // Read again: confirmed with its ETag (Sky Studio checks this Mac's licence before its 304), labelled with when it was fetched.
    env.now = moment(1_100)
    let again = try? await library.readCard(.card("512"))
    checkEqual(again?.cachedAt, moment(1_000), "read again: this Mac's copy, with when it was fetched")
    checkEqual(SkyStudioStub.log.last?.headers["If-None-Match"], "\"card:512@2\"", "confirmed with the copy's own ETag")
    // Unknown pages are said plainly, without asking.
    SkyStudioStub.reset { _ in .http(500, "{}") }
    await expectCardProblem(library, .group("camera"), "Sky Studio has no craft-card group called camera. Groups: sound.", "an unknown group")
    await expectCardProblem(library, .card("999"), nil, "an unknown card", contains: "lists no craft card 999")
    check(SkyStudioStub.log.isEmpty, "unknown pages: nothing asked")

    await answerChecks(library)
    await cardOfflineChecks(library, env)
    await cardRefusedChecks(library, env, pages: pages)
    await cardMismatchChecks(library, env, pages: pages)
    await cardLicenceChecks(library, env, root: root.appendingPathComponent("main"))
}

/// The list answers 503 (nothing published at all), or lists the trailer alone (release 1, no cards part): no card page is asked.
@MainActor
private func nothingPublishedChecks(_ root: URL) async {
    let env = StyleEnvironment(entitled: true)
    let library = makeLibrary(root, env)
    SkyStudioStub.reset { _ in .http(503, #"{"error": {"code": "content_unavailable", "message": "Nothing is published yet."}}"#) }
    _ = await library.refreshedListing()
    await expectCardProblem(library, .entry, SkyStudioCardWords.nonePublished, "the list answers content_unavailable: none published yet")
    env.now = moment(1_000 + 61)
    var trailerOnly = manifestAnswer(release: 1).objectValue!
    trailerOnly["cards"] = ["entry": .null, "groups": [], "items": []]
    let manifest = JSONValue.object(trailerOnly).encodedString()
    SkyStudioStub.reset { _ in .headers(200, manifest, ["ETag": "\"m1\""]) }
    _ = await library.refreshedListing()
    await expectCardProblem(library, .entry, SkyStudioCardWords.nonePublished, "release 1 with the trailer alone: none published yet")
    await expectCardProblem(library, .card("512"), SkyStudioCardWords.nonePublished, "and no card either")
    check(cardRequests().isEmpty, "no card page was asked while none is published")
    check(SkyStudioCardWords.nonePublished.hasSuffix("Editing works without them."), "it says editing works without them")
}

/// The answer the AI reads (AICraftCardsAnswer) for pages read from this Mac's copy (Sky Studio answers 500 here, so the copies stand in).
@MainActor
private func answerChecks(_ library: SkyStudioStyleLibrary) async {
    let cards = library.listing.cards
    guard let entry = try? await library.readCard(.entry), let card = try? await library.readCard(.card("512")),
          let group = try? await library.readCard(.group("sound")) else { return check(false, "the three pages read for the answers") }
    let entryAnswer = AICraftCardsAnswer.answer(entry.page, cachedAt: entry.cachedAt, cards: cards, appVersion: "0.18.70")
    checkEqual(entryAnswer["page"], "entry", "the entry page says which page it is")
    checkEqual(entryAnswer["rev"], .number(1), "and its rev")
    checkEqual(entryAnswer["groups"], [["group": "sound", "title": "Sound", "count": 2]], "the groups the list holds, for group=")
    check(entryAnswer["text"]?.stringValue == entry.page.text, "the page's text as Sky Studio sent it")
    checkEqual(entryAnswer["cached"], .bool(true), "read again: cached")
    checkEqual(entryAnswer["fetched_at"]?.stringValue, AIRecipeSkyStudioPart.day(moment(1_000)), "with when it was fetched (recipes' words)")
    check(entryAnswer["next_step"]?.stringValue?.contains("craft_cards group=<group>") == true, "the entry page says how to read more")
    check(entryAnswer["note"] == nil, "checked against an older SkyCut than this one: no note")
    let cardAnswer = AICraftCardsAnswer.answer(card.page, cachedAt: nil, cards: cards, appVersion: "0.18.60")
    checkEqual(cardAnswer["id"], "512", "a card says its number")
    checkEqual(cardAnswer["related"], ["511", "518"], "and its related cards")
    check(cardAnswer["cached"] == nil && cardAnswer["fetched_at"] == nil, "fetched just now: no cached / fetched_at")
    check(cardAnswer["next_step"]?.stringValue?.contains("craft_cards id=511, craft_cards id=518") == true, "next_step names the related cards")
    check(cardAnswer["next_step"]?.stringValue?.contains("never save them with save_recipe") == true, "cards are never saved as a style")
    check(cardAnswer["note"]?.stringValue?.contains("SkyCut 0.18.66") == true, "checked against a newer SkyCut than this one: a note")
    let groupAnswer = AICraftCardsAnswer.answer(group.page, cachedAt: nil, cards: cards, appVersion: "0.18.70")
    checkEqual(groupAnswer["group"], "sound", "a catalogue says its group")
    checkEqual(groupAnswer["version"], "2", "and its version")
    checkEqual(groupAnswer["title"], "Sound", "and its title")
    let size = cardAnswer.encodedString().utf16.count
    check(size < 1_000, "a small card's answer stays small (\(size))")
}

@MainActor
private func cardOfflineChecks(_ library: SkyStudioStyleLibrary, _ env: StyleEnvironment) async {
    // Offline: the list is this Mac's copy; a page with a copy here is read, one without is said plainly.
    env.now = moment(1_000 + 700)
    SkyStudioStub.reset { _ in .failure(.notConnectedToInternet) }
    let listing = await library.refreshedListing()
    checkEqual(listing.origin, .thisMac(fetchedAt: moment(1_000)), "offline: the list is this Mac's copy")
    checkEqual(listing.cards.cards.map(\.id), ["512", "513"], "and still lists the cards")
    checkEqual((try? await library.readCard(.card("512")))?.cachedAt, moment(1_000), "offline: a page with a copy here is read")
    await expectCardProblem(library, .card("513"), nil, "offline with no copy of card 513",
                            contains: "cannot be reached and this Mac has no copy of craft card 513 (version 1)")
    // Sky Studio failing (a 503) is not a refusal: the copy is served; without a copy, plain words.
    SkyStudioStub.reset { _ in .http(503, #"{"error": {"code": "content_unavailable", "message": "Try later."}}"#) }
    checkEqual((try? await library.readCard(.entry))?.cachedAt, moment(1_000), "a 503 on a page: this Mac's copy")
    await expectCardProblem(library, .card("513"), nil, "a 503 with no copy", contains: "cannot send its craft cards right now")
    // The trial ends while offline (the stored answer's valid_until): the copies are no longer served.
    env.licence = SkyCutLicense.free(.expired)
    await expectCardProblem(library, .card("512"), SkyStudioCardWords.needsPlan, "past valid_until offline: the copy is not served")
    env.licence = StyleEnvironment.licence(true)
}

@MainActor
private func cardRefusedChecks(_ library: SkyStudioStyleLibrary, _ env: StyleEnvironment, pages: [JSONValue]) async {
    // Online, Sky Studio's refusal wins over the copy held, in plain words about the cards.
    env.now = moment(1_000 + 1_400)
    serveCards(cardManifest(entry: pages[0], groups: [pages[1]], cards: [pages[2], pages[3]]), pages: pages)
    _ = await library.refreshedListing()
    SkyStudioStub.reset { _ in .http(403, #"{"error": {"code": "not_entitled", "message": "Not registered.", "feature": "recipes", "plan_reason": "machine_not_registered"}}"#) }
    await expectCardProblem(library, .card("512"), nil, "a Mac Sky Studio has not registered is not served the copy",
                            contains: "has not registered this Mac for this account yet, so it does not send its craft cards here")
    SkyStudioStub.reset { _ in .http(403, #"{"error": {"code": "not_entitled", "message": "Mac limit.", "plan_reason": "machine_limit_reached", "manage_machines_url": "https://skystudioai.com/app?machines=1"}}"#) }
    await expectCardProblem(library, .entry, nil, "the Mac limit", contains: "https://skystudioai.com/app?machines=1")
    let words = SkyStudioCardWords.problem(.server(SkyStudioServerError(status: 403, code: "not_entitled", message: "Needs Pro.", fields: [:])),
                                           page: .entry, version: "1")
    check(words.contains("does not include its craft cards") && words.hasSuffix("Editing works without them."), "a plan without them: \(words)")
    // A page Sky Studio no longer holds at the version the list named (withdrawn since the list was asked).
    SkyStudioStub.reset { _ in .http(404, #"{"error": {"code": "not_found", "message": "No such card."}}"#) }
    await expectCardProblem(library, .card("513"), nil, "a page withdrawn since", contains: "no longer has craft card 513 at version 1")
}

@MainActor
private func cardMismatchChecks(_ library: SkyStudioStyleLibrary, _ env: StyleEnvironment, pages: [JSONValue]) async {
    // The list names one text for card 513 rev 1, Sky Studio sends another: refused and not kept.
    let other = cardAnswer("513", rev: 1, related: [], text: "## What it is\nSomething else.")
    serveCards(cardManifest(entry: pages[0], groups: [pages[1]], cards: [pages[2], pages[3]]), pages: [pages[0], pages[1], pages[2], other])
    await expectCardProblem(library, .card("513"), nil, "a text that is not the listed one",
                            contains: "sent a different text for craft card 513 (version 1) than its list names")
    // A new release: card 512 rev 3 is fetched by its new version, the rev 2 copy stays.
    let newer = cardAnswer(rev: 3, text: "## What it is\nSilence, sharper.\n\n## In SkyCut\nedit_clip volume_curve")
    env.now = moment(1_000 + 2_100)
    serveCards(cardManifest(release: 3, entry: pages[0], groups: [pages[1]], cards: [newer, pages[3]]), pages: [pages[0], pages[1], newer, pages[2], pages[3]])
    _ = await library.refreshedListing()
    let read = try? await library.readCard(.card("512"))
    checkEqual(read?.page.version, "3", "the new rev is read")
    checkEqual(cardRequests(), ["/content/cards/512?version=3"], "asked by its new version")
    // The licence ends while a page is fetched: nothing is kept or served.
    let text = pages[3].encodedString(), manifest = cardManifest(release: 3, entry: pages[0], groups: [pages[1]], cards: [newer, pages[3]]).encodedString()
    SkyStudioStub.reset { seen in
        if seen.url.hasSuffix("/content") { return .headers(200, manifest, ["ETag": "\"m3\""]) }
        env.licence = SkyCutLicense.free(.server)
        return .http(200, text)
    }
    await expectCardProblem(library, .card("513"), SkyStudioCardWords.needsPlan, "a licence that ends during the fetch: refused")
    env.licence = StyleEnvironment.licence(true)
}

@MainActor
private func cardLicenceChecks(_ library: SkyStudioStyleLibrary, _ env: StyleEnvironment, root: URL) async {
    let cache = SkyStudioContentCache(directory: root)
    check(cache.cardPage(.card("512"), version: "2") != nil && cache.cardPage(.card("512"), version: "3") != nil,
          "both revs of card 512 are on this Mac")
    check(cache.cardPage(.card("513"), version: "1") == nil, "the mismatched and the revoked fetches kept nothing")
    // A fresh /me without recipes: every card copy goes; the list (titles only) stays.
    env.licence = StyleEnvironment.licence(false)
    library.licenceChanged(hasKey: true, entitled: false)
    check(cache.cardPage(.entry, version: "1") == nil && cache.cardPage(.card("512"), version: "3") == nil,
          "a fresh /me without recipes deletes the card copies")
    check(!library.listing.cards.isEmpty, "the list still names the cards (locked)")
    // The key is removed: everything goes; reading says no key.
    env.hasKey = false
    library.licenceChanged(hasKey: false, entitled: false)
    env.licence = StyleEnvironment.licence(true)
    await expectCardProblem(library, .entry, SkyStudioJobKey.Problem.noKey.message, "no key: says so")
    env.hasKey = true
}

/// The fake Sky Studio's card routes (contract of c9a7ce5d): the manifest at /content, each page by its version with its own ETag
/// (`"<kind>:<id>@<version>"`), a 304 for the ETag held, 404 for a version it does not hold.
private func serveCards(_ manifest: JSONValue, pages: [JSONValue]) {
    let list = manifest.encodedString()
    SkyStudioStub.reset { seen in
        guard let url = URLComponents(string: seen.url) else { return .http(500, "{}") }
        if url.path.hasSuffix("/content") { return .headers(200, list, ["ETag": "\"m1\"", "Cache-Control": "private, no-cache"]) }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        let version = query["version"]
        var found: (kind: String, id: String, page: JSONValue)?
        if url.path.hasSuffix("/content/cards"), let group = query["group"] {
            found = pages.first { $0["id"] == nil && $0["group"]?.stringValue == group && SkyStudioCardCatalog.version($0["version"]) == version }
                .map { ("group", group, $0) }
        } else if url.path.hasSuffix("/content/cards") {
            found = pages.first { $0["id"] == nil && $0["group"] == nil && SkyStudioCardCatalog.version($0["rev"]) == version }
                .map { ("entry", "entry", $0) }
        } else if let range = url.path.range(of: "/content/cards/") {
            let id = String(url.path[range.upperBound...])
            found = pages.first { $0["id"]?.stringValue == id && SkyStudioCardCatalog.version($0["rev"]) == version }.map { ("card", id, $0) }
        }
        guard let found else { return .http(404, #"{"error": {"code": "not_found", "message": "No such page."}}"#) }
        let tag = "\"\(found.kind):\(found.id)@\(version ?? "")\""
        if seen.headers["If-None-Match"] == tag { return .headers(304, "", ["ETag": tag, "Cache-Control": "private, no-cache"]) }
        return .headers(200, found.page.encodedString(), ["ETag": tag, "Cache-Control": "private, no-cache"])
    }
}

/// The card page requests sent since the last reset, as paths with their query.
private func cardRequests() -> [String] {
    SkyStudioStub.log.compactMap { seen -> String? in
        guard let range = seen.url.range(of: "/content/cards") else { return nil }
        return String(seen.url[range.lowerBound...])
    }
}

/// readCard must fail with exactly `message` (or a message containing `contains`).
@MainActor
private func expectCardProblem(_ library: SkyStudioStyleLibrary, _ page: SkyStudioCardRequest, _ message: String?, _ what: String,
                               contains part: String? = nil) async {
    do {
        _ = try await library.readCard(page)
        check(false, "\(what): it was read")
    } catch let problem as SkyStudioStyleLibrary.ReadProblem {
        if let message { checkEqual(problem.message, message, what) }
        if let part { check(problem.message.contains(part), "\(what): \(problem.message)") }
    } catch {
        check(false, "\(what): \(error)")
    }
}
