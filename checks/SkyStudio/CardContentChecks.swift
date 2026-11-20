import Foundation
import SrtFlowMCPKit

// Sky Studio's craft cards for SkyCut (2026-11-20, SS5 plan 5.6; contract: Sky Studio repo docs/agents/skycut-api.md, "Editing
// styles and craft cards"): how the cards part of the manifest and each kind of page read (identity and checksum checked, `rev`
// as a number), what craft_cards may ask for (shapes, padding, both refused), the card routes on a fake Sky Studio (paths, the
// group and version queries, headers, If-None-Match / 304, errors kept, wrong shapes refused before asking), the copies on this
// Mac (kind / id / version kept apart, a copy under another name or a changed text ignored, deleted with the texts), and what
// the AI is told when the licence leaves the cards out. The library on the fake server is in CardLibraryChecks.swift.

/// The entry page as Sky Studio sends it (`GET /content/cards`).
func entryAnswer(rev: Int = 1, text: String = "# Craft cards\n\nA quiet moment: 512. Groups: sound.", minSkyCut: String? = "0.18.66") -> JSONValue {
    var object: [String: JSONValue] = ["rev": .number(Double(rev)), "sha256": .string(SkyStudioContentRules.sha256(text)),
                                       "first_release": 2, "text": .string(text)]
    if let minSkyCut { object["min_skycut_version"] = .string(minSkyCut) }
    return .object(object)
}

/// A group's catalogue as Sky Studio sends it (`GET /content/cards?group=`).
func groupAnswer(_ key: String = "sound", version: String = "2", text: String = "# Sound\n\n512 Silence as a sound effect.") -> JSONValue {
    ["group": .string(key), "title": "Sound", "version": .string(version), "sha256": .string(SkyStudioContentRules.sha256(text)),
     "min_skycut_version": "0.18.66", "first_release": 2, "text": .string(text)]
}

/// One card as Sky Studio sends it (`GET /content/cards/{id}`): the craft sections, a blank line, then `## In SkyCut`.
func cardAnswer(_ id: String = "512", rev: Int = 2, related: [String] = ["511", "518"],
                text: String = "## What it is\nSilence before a hit.\n\n## In SkyCut\nedit_clip volume_curve") -> JSONValue {
    ["id": .string(id), "group": "sound", "title": "Silence as a sound effect", "rev": .number(Double(rev)),
     "related": .array(related.map(JSONValue.string)), "sha256": .string(SkyStudioContentRules.sha256(text)),
     "min_skycut_version": "0.18.66", "first_release": 2, "text": .string(text)]
}

/// A manifest whose cards part lists these pages (as the routes list a release: entry, groups with their counts, cards by number).
func cardManifest(release: Int = 2, entry: JSONValue?, groups: [JSONValue], cards: [JSONValue]) -> JSONValue {
    var object = manifestAnswer(release: release).objectValue ?? [:]
    let listedGroups = groups.map { group -> JSONValue in
        let count = cards.filter { $0["group"] == group["group"] }.count
        return ["group": group["group"]!, "title": group["title"]!, "version": group["version"]!, "count": .number(Double(count)),
                "sha256": group["sha256"]!]
    }
    let listedCards = cards.map { card -> JSONValue in
        ["id": card["id"]!, "group": card["group"]!, "title": card["title"]!, "rev": card["rev"]!, "sha256": card["sha256"]!]
    }
    object["cards"] = ["entry": entry.map { ["rev": $0["rev"]!, "sha256": $0["sha256"]!] } ?? .null,
                       "groups": .array(listedGroups), "items": .array(listedCards)]
    return .object(object)
}

func runCardContentChecks() async {
    catalogChecks()
    requestChecks()
    pageChecks()
    await cardRouteChecks()
    cardCacheChecks()
    cardRefusalChecks()
}

private func catalogChecks() {
    let manifest = SkyStudioContentManifest(json: cardManifest(entry: entryAnswer(), groups: [groupAnswer()], cards: [cardAnswer()]))
    let cards = manifest?.cards
    checkEqual(cards?.entry, SkyStudioCardCatalog.Entry(version: "1", sha256: entryAnswer()["sha256"]!.stringValue!),
               "the entry page's rev (a number) is read as version 1")
    checkEqual(cards?.groups.map(\.group), ["sound"], "the groups")
    checkEqual(cards?.groups.first?.count, 1, "with how many cards each holds")
    checkEqual(cards?.cards.map(\.id), ["512"], "the cards by number")
    checkEqual(cards?.cards.first?.version, "2", "a card's rev is its version")
    check(cards?.isEmpty == false, "cards are published")
    checkEqual(cards?.listed(.card("512"))?.version, "2", "a listed card's version")
    check(cards?.listed(.card("513")) == nil && cards?.listed(.group("camera")) == nil, "an unlisted card or group: nil")
    // Day one publishes the trailer alone: an empty cards part, or none at all, is "no cards".
    check(SkyStudioContentManifest(json: cardManifest(entry: nil, groups: [], cards: []))?.cards.isEmpty == true,
          "entry null with empty lists: no cards published")
    var noCards = manifestAnswer().objectValue!
    noCards["cards"] = nil
    check(SkyStudioContentManifest(json: .object(noCards))?.cards.isEmpty == true, "no cards part at all: no cards published")
    // Leniency: a repeated or badly shaped entry is left out, the rest is read.
    let sha = String(repeating: "a", count: 64)
    let odd: JSONValue = ["entry": ["rev": -1, "sha256": .string(sha)],
                          "groups": [["group": "sound", "version": "1", "sha256": .string(sha)], ["group": "sound", "version": "2", "sha256": .string(sha)],
                                     ["group": "Bad Key", "version": "1", "sha256": .string(sha)], ["group": "look", "version": "1..2", "sha256": .string(sha)]],
                          "items": [["id": "12", "rev": 1, "sha256": .string(sha)], ["id": "512", "rev": 1, "sha256": "abc"],
                                    ["id": "511", "rev": 1, "sha256": .string(sha)]]]
    let lenient = SkyStudioCardCatalog(json: odd)
    check(lenient.entry == nil, "an entry page with a negative rev is left out")
    checkEqual(lenient.groups.map(\.version), ["1"], "a repeated group, a bad key, a bad version are left out")
    checkEqual(lenient.cards.map(\.id), ["511"], "a two-digit id or a bad checksum is left out")
    checkEqual(lenient.groups.first?.title, "sound", "a group without a title is called by its key")
}

private func requestChecks() {
    func request(_ id: String?, _ group: String?) -> SkyStudioCardRequest? { try? SkyStudioCardRequest.from(id: id, group: group) }
    checkEqual(request(nil, nil), .entry, "no arguments: the entry page")
    checkEqual(request("", "  "), .entry, "empty arguments: the entry page")
    checkEqual(request("512", nil), .card("512"), "id: one card")
    checkEqual(request(" 7 ", nil), .card("007"), "a one-digit number is padded (the story cards are 001-014)")
    checkEqual(request("12", nil), .card("012"), "a two-digit number is padded")
    checkEqual(request(nil, "Sound"), .group("sound"), "group: that catalogue, any case")
    for bad in ["1234", "abc", "51a", "5 1", "-12", "512/../me"] {
        check(request(bad, nil) == nil, "\(bad) is not a card id")
    }
    for bad in ["a/b", "-x", "a?b", "sound&x=1"] {
        check(request(nil, bad) == nil, "\(bad) is not a group")
    }
    check(request("512", "sound") == nil, "id and group together are refused")
    checkEqual(SkyStudioCardRequest.card("512").label, "craft card 512", "a card's label")
    checkEqual(SkyStudioCardRequest.group("sound").label, "the sound group's catalogue", "a catalogue's label")
}

private func pageChecks() {
    let entry = SkyStudioCardPage(json: entryAnswer(), request: .entry, version: "1")
    checkEqual(entry?.version, "1", "the entry page reads")
    check(entry?.title == nil && entry?.group == nil, "the entry page has no title or group")
    check(SkyStudioCardPage(json: entryAnswer(), request: .entry, version: "2") == nil, "another version than asked: refused")
    let group = SkyStudioCardPage(json: groupAnswer(), request: .group("sound"), version: "2")
    checkEqual(group?.title, "Sound", "a catalogue reads with its title")
    check(SkyStudioCardPage(json: groupAnswer(), request: .group("camera"), version: nil) == nil, "another group than asked: refused")
    let card = SkyStudioCardPage(json: cardAnswer(), request: .card("512"), version: "2")
    checkEqual(card?.related, ["511", "518"], "a card reads with its related cards")
    checkEqual(card?.group, "sound", "and its group")
    check(card?.text.contains("## In SkyCut") == true, "and its In SkyCut part")
    check(SkyStudioCardPage(json: cardAnswer(), request: .card("511"), version: nil) == nil, "another card than asked: refused")
    check(SkyStudioCardPage(json: cardAnswer(), request: .entry, version: nil) == nil, "a card is not the entry page")
    check(SkyStudioCardPage(json: cardAnswer(), request: .group("sound"), version: nil) == nil, "a card is not its group's catalogue")
    var tampered = cardAnswer().objectValue!
    tampered["text"] = "## What it is\nSomething else."
    check(SkyStudioCardPage(json: .object(tampered), request: .card("512"), version: nil) == nil, "a text that does not match its checksum: refused")
    check(SkyStudioCardPage(json: cardAnswer(text: "  "), request: .card("512"), version: nil) == nil, "an empty text: refused")
    for (page, request) in [(entry, SkyStudioCardRequest.entry), (group, .group("sound")), (card, .card("512"))] {
        checkEqual(page.flatMap { SkyStudioCardPage(json: $0.json, request: request, version: $0.version) }, page,
                   "\(request.label) reads back from the json it writes")
    }
    checkEqual(card?.json["rev"], .number(2), "a card's rev is written back as a number, as Sky Studio sends it")
}

private func cardRouteChecks() async {
    let base = URL(string: "http://127.0.0.1:8123/api/skycut/v1")!
    let key = "sk-" + String(repeating: "E", count: 43)
    let api = SkyStudioAPI(session: SkyStudioStub.session, base: base, version: "0.18.70", machine: String(repeating: "d", count: 64))
    let entry = entryAnswer().encodedString(), group = groupAnswer().encodedString(), card = cardAnswer().encodedString()

    SkyStudioStub.reset { _ in .headers(200, entry, ["ETag": "\"e1\"", "Cache-Control": "private, no-cache"]) }
    if case .changed(let page, let etag)? = try? await api.contentCardPage(.entry, version: "1", key: key) {
        checkEqual(page.version, "1", "the entry page is read")
        checkEqual(etag, "\"e1\"", "with its ETag")
    } else {
        check(false, "a 200 is the entry page")
    }
    let seen = SkyStudioStub.log.first
    checkEqual(seen?.url, "http://127.0.0.1:8123/api/skycut/v1/content/cards?version=1", "the entry page's address, by version")
    checkEqual(seen?.headers["Authorization"], "Bearer \(key)", "the key goes along")
    checkEqual(seen?.headers["X-SkyCut-Machine"], String(repeating: "d", count: 64), "the machine goes along")
    checkEqual(seen?.headers["X-SkyCut-Version"], "0.18.70", "the version goes along")

    SkyStudioStub.reset { _ in .headers(200, group, ["ETag": "\"g2\""]) }
    _ = try? await api.contentCardPage(.group("sound"), version: "2", key: key)
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/content/cards?group=sound&version=2",
               "a catalogue is asked as ?group= with its version")
    SkyStudioStub.reset { _ in .headers(200, card, ["ETag": "\"c2\""]) }
    _ = try? await api.contentCardPage(.card("512"), version: "2", key: key)
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/content/cards/512?version=2", "a card by its number")
    SkyStudioStub.reset { _ in .headers(200, card, ["ETag": "\"c2\""]) }
    _ = try? await api.contentCardPage(.card("512"), version: nil, key: key)
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/content/cards/512", "no version: the current one")

    SkyStudioStub.reset { _ in .headers(304, "", ["ETag": "\"c2\""]) }
    checkEqual(try? await api.contentCardPage(.card("512"), version: "2", key: key, etag: "\"c2\""), SkyStudioCardAnswer.notModified,
               "a 304 confirms the copy held")
    checkEqual(SkyStudioStub.log.first?.headers["If-None-Match"], "\"c2\"", "the copy's ETag goes out as If-None-Match")
    checkEqual(await expectFailure("304 unasked", { _ = try await api.contentCardPage(.card("512"), version: "2", key: key) }),
               .badAnswer(status: 304), "a 304 to a question without an ETag is a bad answer")
    SkyStudioStub.reset { _ in .http(200, card) }
    checkEqual(await expectFailure("another card", { _ = try await api.contentCardPage(.card("511"), version: nil, key: key) }),
               .badAnswer(status: 200), "a 200 that is another card is a bad answer")
    SkyStudioStub.reset { _ in .http(403, #"{"error": {"code": "not_entitled", "message": "Needs Pro.", "feature": "recipes", "plan_reason": "machine_not_registered"}}"#) }
    if case .server(let error)? = await expectFailure("403", { _ = try await api.contentCardPage(.entry, version: "1", key: key) }) {
        checkEqual(error.fields["plan_reason"]?.stringValue, "machine_not_registered", "not_entitled keeps its plan_reason")
    } else {
        check(false, "403 is a server error")
    }
    SkyStudioStub.reset { _ in .http(200, "{}") }
    for (page, version) in [(SkyStudioCardRequest.card("12"), "1"), (.group("Bad Key"), "1"), (.card("512"), "1&x=1")] {
        do {
            _ = try await api.contentCardPage(page, version: version, key: key)
            check(false, "\(page.label) \(version) is refused")
        } catch {
            check(error is SkyStudioContentRequestProblem, "\(page.label) \(version) is refused before asking")
        }
    }
    check(SkyStudioStub.log.isEmpty, "nothing was sent for a wrong id, group or version")
}

private func cardCacheChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-cards-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SkyStudioContentCache(directory: root)
    guard let entry = SkyStudioCardPage(json: entryAnswer(), request: .entry, version: nil),
          let card = SkyStudioCardPage(json: cardAnswer(), request: .card("512"), version: nil),
          let newer = SkyStudioCardPage(json: cardAnswer(rev: 3), request: .card("512"), version: nil),
          let style = SkyStudioStyleText(json: styleAnswer(), id: "film-trailer", version: nil)
    else { return check(false, "the samples read") }
    try? cache.store(entry, etag: "\"e1\"", fetchedAt: moment(10))
    try? cache.store(card, fetchedAt: moment(20))
    try? cache.store(newer, fetchedAt: moment(30))
    try? cache.store(style, fetchedAt: moment(40))
    checkEqual(cache.cardPage(.entry, version: "1"), SkyStudioContentCache.CardPage(page: entry, fetchedAt: moment(10), etag: "\"e1\""),
               "the entry page, its ETag and when it was fetched read back")
    checkEqual(cache.cardPage(.card("512"), version: "2")?.fetchedAt, moment(20), "card 512 rev 2 by kind, id and version")
    // Two revs with one text (and so one checksum) are two copies (Codex review CXS1 #5, for cards too).
    checkEqual(cache.cardPage(.card("512"), version: "3")?.page.version, "3", "rev 3 is its own copy: keeping it did not overwrite rev 2")
    checkEqual(cache.cardPage(.card("512"), version: "2")?.fetchedAt, moment(20), "and rev 2 keeps its own")
    check(cache.cardPage(.card("512"), version: "2", sha256: card.sha256) != nil, "id, version and checksum all match: found")
    check(cache.cardPage(.card("512"), version: "2", sha256: entry.sha256) == nil, "a checksum that is not this version's: not found")
    check(cache.cardPage(.group("512"), version: "2") == nil, "a group with a card's number is another kind: not found")
    if let sameName = SkyStudioCardPage(json: groupAnswer("512", version: "2"), request: .group("512"), version: nil) {
        try? cache.store(sameName, fetchedAt: moment(50))
        check(cache.cardPage(.card("512"), version: "2") != nil && cache.cardPage(.group("512"), version: "2") != nil,
              "a group named like a card is kept under its own kind: neither copy overwrites the other")
    } else {
        check(false, "the same-name group sample reads")
    }
    checkEqual(cache.storedVersions(), ["film-trailer@1.0"], "card copies are not counted as style versions")
    // A copy under another version's name is not that version; a text changed on disk is never served.
    let folder = root.appendingPathComponent("cards/card")
    try? FileManager.default.copyItem(at: folder.appendingPathComponent("512@2.json"), to: folder.appendingPathComponent("512@4.json"))
    check(cache.cardPage(.card("512"), version: "4") == nil, "rev 2's copy under rev 4's name is not rev 4")
    let file = folder.appendingPathComponent("512@2.json")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        try? text.replacingOccurrences(of: "Silence before", with: "Noise before").write(to: file, atomically: true, encoding: .utf8)
    }
    check(cache.cardPage(.card("512"), version: "2") == nil, "a copy whose text no longer matches its checksum is ignored")
    try? cache.store(SkyStudioContentCache.Manifest(manifest: SkyStudioContentManifest(json: manifestAnswer())!, etag: nil, fetchedAt: moment()))
    cache.removeTexts()
    check(cache.cardPage(.entry, version: "1") == nil && cache.cardPage(.card("512"), version: "3") == nil,
          "removing texts (a /me without recipes) deletes the card copies too")
    check(cache.manifest() != nil, "and keeps the manifest")
}

private func cardRefusalChecks() {
    let free = SkyCutLicense(plan: .free, mcp: false, watermark: true, basis: .server, validUntil: moment(86_400))
    let trialOff = SkyCutLicense(plan: .trial, mcp: true, watermark: true, basis: .server, validUntil: moment(86_400))
    var limited = free
    limited.planReason = "machine_limit_reached"
    limited.machineLimit = 2
    for (name, license) in [("free", free), ("trial without recipes", trialOff), ("no key", SkyCutLicense.free(.noKey)),
                            ("expired", SkyCutLicense.free(.expired)), ("machine limit", limited)] {
        let text = SkyCutGates.cardRefusal(license: license, problem: nil)
        check(text.hasPrefix("Not done: Sky Studio's craft cards need SkyCut Pro or a SkyCut trial, and "), "\(name): says what was not done")
        check(text.hasSuffix("Editing works without them."), "\(name): says editing works without them")
        check(!text.contains("editing styles"), "\(name): about the cards, not the styles")
    }
    check(SkyCutGates.cardRefusal(license: trialOff, problem: nil).contains("plan does not include them"),
          "a trial or Pro account without recipes is told its plan leaves them out")
    check(SkyCutGates.cardRefusal(license: .free(.noKey), problem: nil).contains("Settings → Sky Studio"), "no key: where to paste one")
    check(SkyCutGates.cardRefusal(license: limited, problem: nil).contains("2 Macs"), "the Mac limit: says so")
    check(SkyCutGates.styleRefusal(license: free, problem: nil).hasSuffix("pick one of them from recipes."),
          "the styles' refusal keeps its own last sentence")
}
