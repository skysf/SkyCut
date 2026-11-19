import Foundation
import SrtFlowMCPKit

// Sky Studio's editing styles for SkyCut (2026-11-19, SS5 plan §3, 5.1, 5.4): how the manifest and a style read (checksum checked,
// shapes that may go into an address), the two routes on a fake Sky Studio (paths, headers, If-None-Match / 304, errors kept),
// the copies on this Mac (round trip, a changed text ignored, deleting texts or everything), the licence's `recipes` flag and what
// the AI is told when it leaves Sky Studio's styles out. The library's behaviour is in StyleLibraryChecks.swift.

/// One style as Sky Studio would send it, with a checksum that matches its text.
func styleAnswer(_ id: String = "film-trailer", version: String = "1.0", text: String = "# Film trailer\n\nThree acts.",
                 useFor: String = "A story trailer from footage.", minSkyCut: String? = "0.18.60") -> JSONValue {
    var object: [String: JSONValue] = [
        "id": .string(id), "title": "Film trailer", "use_for": .string(useFor), "version": .string(version),
        "sha256": .string(SkyStudioContentRules.sha256(text)), "first_release": 1, "text": .string(text)
    ]
    if let minSkyCut { object["min_skycut_version"] = .string(minSkyCut) }
    return .object(object)
}

/// A manifest listing these styles (plan §3's shape, with a cards part SkyCut keeps but does not read yet).
func manifestAnswer(release: Int = 1, _ styles: [JSONValue] = [styleAnswer()]) -> JSONValue {
    let entries = styles.map { style -> JSONValue in
        ["id": style["id"]!, "title": style["title"]!, "use_for": style["use_for"]!, "version": style["version"]!,
         "sha256": style["sha256"]!, "min_skycut_version": style["min_skycut_version"] ?? .null]
    }
    return ["release": .number(Double(release)), "published_at": "2026-11-20T08:00:00.000Z", "entitled": true, "plan": "pro",
            "styles": .array(entries), "cards": ["entry": ["rev": 1, "sha256": .string(String(repeating: "c", count: 64))]]]
}

func runStyleContentChecks() async {
    contractChecks()
    await routeChecks()
    cacheChecks()
    licenceAndRefusalChecks()
}

private func contractChecks() {
    check(SkyStudioContentRules.isItemID("film-trailer") && SkyStudioContentRules.isItemID("512"), "ids like film-trailer and 512")
    for bad in ["", "-x", "Film", "a/b", "a..b", "a?b", String(repeating: "a", count: 61)] {
        check(!SkyStudioContentRules.isItemID(bad), "\(bad) is not an id that may go into an address")
    }
    check(SkyStudioContentRules.isVersion("1.0") && SkyStudioContentRules.isVersion("2") && SkyStudioContentRules.isVersion("2.0.1"),
          "versions like 1.0, 2 and 2.0.1 (digits with up to two dots)")
    for bad in ["", "v1", "1..0", "1.0/..", "1.0&x=1", "latest", "1.2.3.4"] {
        check(!SkyStudioContentRules.isVersion(bad), "\(bad) is not a version")
    }
    check(SkyStudioContentRules.isOlder("0.18.70", than: "0.19.0"), "0.18.70 is older than 0.19.0")
    check(!SkyStudioContentRules.isOlder("0.19.0", than: "0.19.0"), "the same version is not older")
    check(!SkyStudioContentRules.isOlder("0.19.0-local.3+abc", than: "0.19"), "build suffixes are ignored")
    check(!SkyStudioContentRules.isOlder("garbage", than: "0.19.0"), "an unreadable version is never called older")
    checkEqual(SkyStudioContentRules.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of the UTF-8 text")

    let manifest = SkyStudioContentManifest(json: manifestAnswer(release: 3))
    checkEqual(manifest?.release, 3, "the manifest's release")
    checkEqual(manifest?.styles.map(\.id), ["film-trailer"], "the manifest's styles")
    checkEqual(manifest?.styles.first?.minSkyCutVersion, "0.18.60", "min_skycut_version is read")
    check(manifest?.publishedAt != nil, "published_at with milliseconds is read")
    check(manifest?.raw["cards"] != nil, "the cards part is kept as it came")
    var odd = manifestAnswer()
    if case .object(var object) = odd {
        let good = object["styles"]!.arrayValue![0]
        object["styles"] = [good, good, ["id": "Bad Id", "version": "1.0", "sha256": good["sha256"]!],
                            ["id": "x", "version": "1..0", "sha256": good["sha256"]!], ["id": "y", "version": "1.0", "sha256": "abc"]]
        odd = .object(object)
    }
    checkEqual(SkyStudioContentManifest(json: odd)?.styles.map(\.id), ["film-trailer"],
               "a repeated id or an id / version / checksum of the wrong shape is left out, the rest is read")
    check(SkyStudioContentManifest(json: ["release": 1]) == nil, "no styles: not a manifest")
    check(SkyStudioContentManifest(json: ["release": 0, "styles": []]) == nil, "release 0: not a manifest")

    let style = SkyStudioStyleText(json: styleAnswer(), id: "film-trailer", version: "1.0")
    checkEqual(style?.text, "# Film trailer\n\nThree acts.", "a style's text")
    checkEqual(style.flatMap { SkyStudioStyleText(json: $0.json, id: "film-trailer", version: nil) }, style, "a style reads back from json")
    check(SkyStudioStyleText(json: styleAnswer(), id: "other", version: nil) == nil, "another style than the one asked: refused")
    check(SkyStudioStyleText(json: styleAnswer(), id: "film-trailer", version: "1.1") == nil, "another version than asked: refused")
    var tampered = styleAnswer()
    if case .object(var object) = tampered { object["text"] = "# Film trailer\n\nFour acts."; tampered = .object(object) }
    check(SkyStudioStyleText(json: tampered, id: "film-trailer", version: nil) == nil, "a text that does not match its checksum: refused")
    check(SkyStudioStyleText(json: styleAnswer(text: "  "), id: "film-trailer", version: nil) == nil, "an empty text: refused")
}

private func routeChecks() async {
    let base = URL(string: "http://127.0.0.1:8123/api/skycut/v1")!
    let key = "sk-" + String(repeating: "C", count: 43)
    let api = SkyStudioAPI(session: SkyStudioStub.session, base: base, version: "0.18.70", machine: String(repeating: "b", count: 64))
    let manifest = manifestAnswer().encodedString()

    SkyStudioStub.reset { _ in .headers(200, manifest, ["ETag": "\"m1\""]) }
    let first = try? await api.contentManifest(key: key, etag: nil)
    let seen = SkyStudioStub.log.first
    checkEqual(seen?.url, "http://127.0.0.1:8123/api/skycut/v1/content", "the manifest's address")
    checkEqual(seen?.headers["Authorization"], "Bearer \(key)", "the key goes along")
    checkEqual(seen?.headers["X-SkyCut-Version"], "0.18.70", "the version goes along")
    checkEqual(seen?.headers["X-SkyCut-Machine"], String(repeating: "b", count: 64), "the machine goes along")
    check(seen?.headers["If-None-Match"] == nil, "no ETag held, no If-None-Match")
    if case .changed(let read, let etag)? = first {
        checkEqual(read.styles.map(\.id), ["film-trailer"], "the manifest is read")
        checkEqual(etag, "\"m1\"", "the ETag is kept")
    } else {
        check(false, "a 200 is a new manifest")
    }
    SkyStudioStub.reset { _ in .headers(304, "", ["ETag": "\"m1\""]) }
    checkEqual(try? await api.contentManifest(key: key, etag: "\"m1\""), SkyStudioManifestAnswer.notModified, "a 304 means the copy held is current")
    checkEqual(SkyStudioStub.log.first?.headers["If-None-Match"], "\"m1\"", "the ETag held goes out as If-None-Match")

    let style = styleAnswer().encodedString()
    SkyStudioStub.reset { _ in .headers(200, style, ["ETag": "\"s1\"", "Cache-Control": "private, max-age=31536000, immutable"]) }
    checkEqual(try? await api.contentStyle("film-trailer", version: "1.0", key: key).version, "1.0", "a style is read")
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/content/styles/film-trailer?version=1.0",
               "a style is asked by id and version")
    var tampered = styleAnswer()
    if case .object(var object) = tampered { object["text"] = "changed"; tampered = .object(object) }
    let tamperedText = tampered.encodedString()
    SkyStudioStub.reset { _ in .http(200, tamperedText) }
    checkEqual(await expectFailure("tampered", { _ = try await api.contentStyle("film-trailer", version: nil, key: key) }),
               .badAnswer(status: 200), "a text that does not match its checksum is a bad answer")
    SkyStudioStub.reset { _ in .http(403, #"{"error": {"code": "not_entitled", "message": "Needs Pro.", "feature": "recipes"}}"#) }
    if case .server(let error)? = await expectFailure("403", { _ = try await api.contentStyle("film-trailer", version: nil, key: key) }) {
        checkEqual(error.code, "not_entitled", "not_entitled keeps its code")
        checkEqual(error.fields["feature"]?.stringValue, "recipes", "and its extra fields")
    } else {
        check(false, "403 is a server error")
    }
    SkyStudioStub.reset { _ in .http(200, "{}") }
    do {
        _ = try await api.contentStyle("../me", version: nil, key: key)
        check(false, "an id of the wrong shape is refused")
    } catch {
        check(error is SkyStudioContentRequestProblem, "an id of the wrong shape is refused before asking")
    }
    do {
        _ = try await api.contentStyle("film-trailer", version: "1.0&x=1", key: key)
        check(false, "a version of the wrong shape is refused")
    } catch {
        check(error is SkyStudioContentRequestProblem, "a version of the wrong shape is refused before asking")
    }
    check(SkyStudioStub.log.isEmpty, "nothing was sent for a wrong id or version")
}

private func cacheChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-content-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SkyStudioContentCache(directory: root)
    check(cache.manifest() == nil && cache.storedVersions().isEmpty, "an empty cache")
    guard let manifest = SkyStudioContentManifest(json: manifestAnswer(release: 2)),
          let style = SkyStudioStyleText(json: styleAnswer(), id: "film-trailer", version: nil),
          let older = SkyStudioStyleText(json: styleAnswer(version: "0.9", text: "# Film trailer\n\nOld."), id: "film-trailer", version: nil)
    else { return check(false, "the samples read") }
    try? cache.store(SkyStudioContentCache.Manifest(manifest: manifest, etag: "\"m2\"", fetchedAt: moment()))
    checkEqual(cache.manifest(), SkyStudioContentCache.Manifest(manifest: manifest, etag: "\"m2\"", fetchedAt: moment()),
               "the manifest, its ETag and when it was fetched read back (cards part too)")
    try? cache.store(style, fetchedAt: moment(60))
    try? cache.store(older, fetchedAt: moment(120))
    checkEqual(cache.style(id: "film-trailer", version: "1.0"), SkyStudioContentCache.Style(style: style, fetchedAt: moment(60)),
               "a style by id and version")
    checkEqual(cache.style(id: "film-trailer", version: "0.9")?.style.text, "# Film trailer\n\nOld.", "an older version by id and version")
    checkEqual(cache.storedVersions(), ["film-trailer@1.0", "film-trailer@0.9"], "the versions held")
    // Two versions with the same text (1.1 changes only use_for) are two copies: keeping one never overwrites the other, and a
    // copy is found only by its own id and version (Codex review CXS1 #5: the cache once keyed whole answers by the text checksum).
    if let same = SkyStudioStyleText(json: styleAnswer(version: "1.1", useFor: "A story trailer with a teaser cut."), id: "film-trailer", version: nil) {
        try? cache.store(same, fetchedAt: moment(180))
        checkEqual(cache.style(id: "film-trailer", version: "1.0")?.style.useFor, "A story trailer from footage.",
                   "keeping 1.1 with the same text did not overwrite 1.0")
        checkEqual(cache.style(id: "film-trailer", version: "1.1")?.style.useFor, "A story trailer with a teaser cut.", "1.1 is its own copy")
        check(cache.style(id: "film-trailer", version: "1.1", sha256: style.sha256) != nil, "id, version and checksum all match: found")
        check(cache.style(id: "film-trailer", version: "1.1", sha256: older.sha256) == nil, "a checksum that is not this version's: not found")
        check(cache.style(id: "other", version: "1.0") == nil, "another id with the same version: not found")
        // A copy under another version's name is not that version (identity is checked on every hit, not only the file name).
        let source = root.appendingPathComponent("styles/film-trailer@1.0.json")
        try? FileManager.default.copyItem(at: source, to: root.appendingPathComponent("styles/film-trailer@2.0.json"))
        check(cache.style(id: "film-trailer", version: "2.0") == nil, "1.0's copy under 2.0's name is not 2.0")
    } else {
        check(false, "the same-text sample reads")
    }
    // A copy whose text was changed on disk is never served.
    let file = root.appendingPathComponent("styles/film-trailer@1.0.json")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        try? text.replacingOccurrences(of: "Three acts", with: "Two acts").write(to: file, atomically: true, encoding: .utf8)
    }
    check(cache.style(id: "film-trailer", version: "1.0") == nil, "a copy whose text no longer matches its checksum is ignored")
    cache.removeTexts()
    check(cache.storedVersions().isEmpty && cache.manifest() != nil, "removing texts keeps the manifest (titles only)")
    cache.removeAll()
    check(cache.manifest() == nil && !FileManager.default.fileExists(atPath: root.path), "removing everything leaves nothing")
}

private func licenceAndRefusalChecks() {
    var me = try? SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: Data(sampleMe.utf8))
    checkEqual(me?.skycut.features.recipes, nil, "an older /me without recipes reads")
    let withRecipes = sampleMe.replacingOccurrences(of: #""features": {"mcp": true, "watermark": true}"#,
                                                    with: #""features": {"mcp": true, "watermark": true, "recipes": true}"#)
    me = try? SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: Data(withRecipes.utf8))
    checkEqual(me?.skycut.features.recipes, true, "features.recipes is read")
    guard var answer = me else { return check(false, "the sample /me reads") }
    let stored = SkyStudioStoredAnswer(me: answer, receivedAt: moment())
    check(SkyCutLicense.evaluate(stored, hasKey: true, now: moment(60)).recipes, "recipes true while the answer is valid")
    check(!SkyCutLicense.evaluate(stored, hasKey: true, now: moment(4 * 86_400)).recipes,
          "past valid_until (the trial's end at the latest) recipes is off, offline too")
    check(!SkyCutLicense.evaluate(stored, hasKey: false, now: moment(60)).recipes, "no key: recipes is off")
    answer.skycut.features.recipes = nil
    check(!SkyCutLicense.evaluate(SkyStudioStoredAnswer(me: answer, receivedAt: moment()), hasKey: true, now: moment(60)).recipes,
          "missing recipes = off")
    let roundTrip = (try? SkyStudioJSON.encoder().encode(stored)).flatMap { try? SkyStudioJSON.decoder().decode(SkyStudioStoredAnswer.self, from: $0) }
    checkEqual(roundTrip?.me.skycut.features.recipes, true, "the stored answer keeps recipes")

    // What the AI is told: not done, why, what the user can do, and that presets and the user's own still work.
    let free = SkyCutLicense(plan: .free, mcp: false, watermark: true, basis: .server, validUntil: moment(86_400))
    let trialOff = SkyCutLicense(plan: .trial, mcp: true, watermark: true, basis: .server, validUntil: moment(86_400))
    var limited = free
    limited.planReason = "machine_limit_reached"
    limited.machineLimit = 2
    for (name, license) in [("free", free), ("trial without recipes", trialOff), ("no key", SkyCutLicense.free(.noKey)),
                            ("expired", SkyCutLicense.free(.expired)), ("machine limit", limited)] {
        let text = SkyCutGates.styleRefusal(license: license, problem: nil)
        check(text.hasPrefix("Not done: Sky Studio's editing styles need SkyCut Pro or a SkyCut trial, and "), "\(name): says what was not done")
        check(text.hasSuffix("The preset styles and the user's own styles still work: pick one of them from recipes."),
              "\(name): says the presets and the user's own still work")
    }
    check(SkyCutGates.styleRefusal(license: trialOff, problem: nil).contains("plan does not include them"),
          "a trial or Pro account without recipes is told its plan leaves them out")
    check(SkyCutGates.styleRefusal(license: free, problem: nil).contains("free plan"), "a free account is told it is on the free plan")
    check(SkyCutGates.styleRefusal(license: .free(.noKey), problem: nil).contains("Settings → Sky Studio"), "no key: where to paste one")
    check(SkyCutGates.styleRefusal(license: limited, problem: nil).contains("2 Macs"), "the Mac limit: says so")
}
