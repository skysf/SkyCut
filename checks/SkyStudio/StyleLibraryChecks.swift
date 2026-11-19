import Foundation
import SrtFlowMCPKit

// SkyStudioStyleLibrary on a fake Sky Studio (SS5 plan 5.1, 5.4): the list is asked again only when 10 minutes old (ETag → 304),
// offline it is this Mac's copy with its date, nothing here and offline = no Sky Studio styles, no key = none; a style is read
// from this Mac's copy when it holds that version, else fetched (checksum checked) and kept; only while the licence includes
// `recipes` (offline past the trial's end too); a licence that ends during a fetch keeps nothing; a fresh /me without `recipes`
// deletes the texts, removing the key deletes everything. Contract shapes are in StyleContentChecks.swift.

/// What the library is given: the licence, the key and the clock, changed by the checks (and by the fake server mid-request).
private final class StyleEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var _licence: SkyCutLicense
    private var _hasKey = true
    var now = moment(1_000)

    init(entitled: Bool) { _licence = StyleEnvironment.licence(entitled) }

    var licence: SkyCutLicense {
        get { lock.lock(); defer { lock.unlock() }; return _licence }
        set { lock.lock(); _licence = newValue; lock.unlock() }
    }

    var hasKey: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasKey }
        set { lock.lock(); _hasKey = newValue; lock.unlock() }
    }

    static func licence(_ recipes: Bool) -> SkyCutLicense {
        var licence = SkyCutLicense(plan: .pro, mcp: true, watermark: false, basis: .server, validUntil: moment(30 * 86_400))
        licence.recipes = recipes
        return licence
    }
}

@MainActor
func runStyleLibraryChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-styles-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let env = StyleEnvironment(entitled: false)
    let library = makeLibrary(root, env)
    let current = styleAnswer(), older = styleAnswer(version: "0.9", text: "# Film trailer\n\nThe 0.9 draft.")
    let manifest = manifestAnswer([current]).encodedString()
    serve(manifest: manifest, styles: [current, older])

    // Not entitled: the titles are listed (locked), nothing is read or fetched.
    var listing = await library.refreshedListing()
    checkEqual(listing.styles.map(\.id), ["film-trailer"], "not entitled: Sky Studio's titles are still listed")
    checkEqual(listing.origin, .live, "the list was asked just now")
    check(!listing.entitled && listing.stored.isEmpty, "not entitled: locked, no copies offered")
    await expectReadProblem(library, "film-trailer", nil, .notEntitled, "not entitled: reading is refused")
    check(styleRequests().isEmpty, "not entitled: no style was asked from Sky Studio")

    // Entitled: the first read fetches and keeps the text, the second comes from this Mac.
    env.licence = StyleEnvironment.licence(true)
    let first = try? await library.read("film-trailer", version: nil)
    checkEqual(first?.style.version, "1.0", "the current version is read")
    check(first != nil && first?.cachedAt == nil, "the first read comes from Sky Studio")
    checkEqual(styleRequests(), ["/content/styles/film-trailer?version=1.0"], "asked by id and the version the list names")
    env.now = moment(1_100)
    let second = try? await library.read("film-trailer", version: "latest")
    checkEqual(second?.cachedAt, moment(1_000), "the second read is this Mac's copy, with when it was fetched")
    checkEqual(styleRequests().count, 1, "and asks nothing")
    check(library.listing.stored.contains(SkyStudioContentRules.sha256("# Film trailer\n\nThree acts.")), "the list knows the copy is here")

    // The list is asked again only when 10 minutes old, with its ETag; a 304 keeps it and counts as live.
    SkyStudioStub.reset { _ in .http(500, "{}") }
    listing = await library.refreshedListing()
    check(SkyStudioStub.log.isEmpty && listing.origin == .live, "within 10 minutes the list is not asked again")
    env.now = moment(1_000 + 601)
    SkyStudioStub.reset { _ in .headers(304, "", ["ETag": "\"m1\""]) }
    listing = await library.refreshedListing()
    checkEqual(SkyStudioStub.log.first?.headers["If-None-Match"], "\"m1\"", "after 10 minutes it is asked with the ETag held")
    checkEqual(listing.origin, .live, "a 304 counts as checked just now")
    checkEqual(listing.styles.map(\.version), ["1.0"], "and keeps the list")

    // A new release: 1.1 is current, 1.0 stays readable from this Mac by version.
    let newer = styleAnswer(version: "1.1", text: "# Film trailer\n\nThree acts, sharper.")
    env.now = moment(1_000 + 1_300)
    serve(manifest: manifestAnswer(release: 2, [newer]).encodedString(), styles: [newer, current, older])
    listing = await library.refreshedListing()
    checkEqual(listing.release, 2, "the new release is listed")
    checkEqual(listing.styles.map(\.version), ["1.1"], "with the new version")
    checkEqual((try? await library.read("film-trailer", version: "1.0"))?.cachedAt, moment(1_000), "1.0 by version: this Mac's copy")
    check(styleRequests().isEmpty, "without asking")
    let draft = try? await library.read("film-trailer", version: "0.9")
    checkEqual(draft?.style.text, "# Film trailer\n\nThe 0.9 draft.", "a version no longer listed is fetched by version")
    checkEqual(styleRequests(), ["/content/styles/film-trailer?version=0.9"], "asked with ?version=0.9")

    await offlineChecks(library, env)
    await revokedDuringFetchChecks(library, env, newer: newer)
    await licenceChangeChecks(library, env, root: root)
    await mismatchAndMissingChecks(root.appendingPathComponent("second"))
}

@MainActor
private func offlineChecks(_ library: SkyStudioStyleLibrary, _ env: StyleEnvironment) async {
    // Offline: this Mac's copy of the list, with its date; a style with a copy here is read, one without is refused plainly.
    env.now = moment(1_000 + 2_000)
    SkyStudioStub.reset { _ in .failure(.notConnectedToInternet) }
    var listing = await library.refreshedListing()
    checkEqual(listing.origin, .thisMac(fetchedAt: moment(1_000 + 1_300)), "offline: this Mac's copy, fetched then")
    checkEqual(listing.styles.map(\.version), ["1.1"], "offline: the list is kept")
    SkyStudioStub.reset { _ in .http(500, "{}") }
    env.now = moment(1_000 + 2_030)
    listing = await library.refreshedListing()
    check(SkyStudioStub.log.isEmpty, "within a minute of a failed ask, the list is not asked again")
    checkEqual((try? await library.read("film-trailer", version: "1.0"))?.style.version, "1.0", "offline: a copy here is read")
    SkyStudioStub.reset { _ in .failure(.notConnectedToInternet) }
    await expectReadProblem(library, "film-trailer", nil, .unreachable(id: "film-trailer", version: "1.1"),
                            "offline with no copy of 1.1: refused plainly")
    // The trial ends while offline (the stored answer's valid_until): the copies are no longer served.
    env.licence = SkyCutLicense.free(.expired)
    await expectReadProblem(library, "film-trailer", "1.0", .notEntitled, "past valid_until offline: the copy is not served")
    env.licence = StyleEnvironment.licence(true)
}

@MainActor
private func revokedDuringFetchChecks(_ library: SkyStudioStyleLibrary, _ env: StyleEnvironment, newer: JSONValue) async {
    // The licence ends while a style is being fetched: nothing is kept or served.
    env.now = moment(1_000 + 4_000)
    let text = newer.encodedString(), manifest = manifestAnswer(release: 2, [newer]).encodedString()
    SkyStudioStub.reset { seen in
        if seen.url.hasSuffix("/content") { return .headers(200, manifest, ["ETag": "\"m2\""]) }
        env.licence = SkyCutLicense.free(.server)
        return .http(200, text)
    }
    _ = await library.refreshedListing()
    await expectReadProblem(library, "film-trailer", "1.1", .notEntitled, "a licence that ends during the fetch: refused")
    check(!library.listing.stored.contains(SkyStudioContentRules.sha256("# Film trailer\n\nThree acts, sharper.")),
          "and the text was not kept")
    env.licence = StyleEnvironment.licence(true)
}

@MainActor
private func licenceChangeChecks(_ library: SkyStudioStyleLibrary, _ env: StyleEnvironment, root: URL) async {
    let cache = SkyStudioContentCache(directory: root)
    check(!cache.storedChecksums().isEmpty, "copies are here before the licence changes")
    // A fresh /me without recipes: every text goes, the titles stay (locked).
    env.licence = StyleEnvironment.licence(false)
    library.licenceChanged(hasKey: true, entitled: false)
    check(cache.storedChecksums().isEmpty, "a fresh /me without recipes deletes every text")
    check(cache.manifest() != nil && !library.listing.styles.isEmpty, "the titles stay for the locked list")
    check(!library.listing.entitled && library.listing.stored.isEmpty, "the list says locked")
    // The key is removed: everything goes and nothing is listed.
    env.hasKey = false
    library.licenceChanged(hasKey: false, entitled: false)
    check(cache.manifest() == nil, "removing the key deletes everything")
    checkEqual(library.listing.origin, .none, "no key: no Sky Studio styles")
    check(library.listing.styles.isEmpty, "no key: nothing listed")
    env.now = moment(1_000 + 9_000)
    SkyStudioStub.reset { _ in .http(500, "{}") }
    let listing = await library.refreshedListing()
    check(listing.origin == .none && SkyStudioStub.log.isEmpty, "no key: Sky Studio is not asked")
}

@MainActor
private func mismatchAndMissingChecks(_ root: URL) async {
    let env = StyleEnvironment(entitled: true)
    let library = makeLibrary(root, env)
    // Nothing published yet (content_unavailable) and nothing here: nothing to list, which is not "unreachable".
    SkyStudioStub.reset { _ in .http(503, #"{"error": {"code": "content_unavailable", "message": "Nothing is published yet."}}"#) }
    var listing = await library.refreshedListing()
    check(listing.origin == .unavailable && listing.styles.isEmpty, "content_unavailable with nothing here: nothing to list, not unreachable")
    // Unreachable and nothing here: no Sky Studio styles at all.
    env.now = moment(1_000 + 61)
    SkyStudioStub.reset { _ in .failure(.cannotConnectToHost) }
    listing = await library.refreshedListing()
    check(listing.origin == .unreachable && listing.styles.isEmpty, "unreachable with nothing here: no Sky Studio styles")
    // The list names one checksum for 1.0, Sky Studio sends another text for 1.0: refused and not kept.
    let listed = styleAnswer(), other = styleAnswer(text: "# Film trailer\n\nSomething else.")
    env.now = moment(1_000 + 200)
    serve(manifest: manifestAnswer([listed]).encodedString(), styles: [other])
    listing = await library.refreshedListing()
    checkEqual(listing.origin, .live, "reachable again")
    do {
        _ = try await library.read("film-trailer", version: nil)
        check(false, "a text that is not the one the list names is refused")
    } catch let problem as SkyStudioStyleLibrary.ReadProblem {
        check(problem.message.contains("different text"), "a text that is not the one the list names is refused: \(problem.message)")
    } catch {
        check(false, "a ReadProblem, got \(error)")
    }
    check(SkyStudioContentCache(directory: root).storedChecksums().isEmpty, "and nothing was kept")
    SkyStudioStub.reset { _ in .http(404, #"{"error": {"code": "not_found", "message": "No such version."}}"#) }
    await expectReadProblem(library, "film-trailer", "3.0", .notFound(id: "film-trailer", version: "3.0"), "an unknown version: not found")
}

@MainActor
private func makeLibrary(_ root: URL, _ env: StyleEnvironment) -> SkyStudioStyleLibrary {
    let base = URL(string: "http://127.0.0.1:8123/api/skycut/v1")!
    let key = "sk-" + String(repeating: "D", count: 43)
    return SkyStudioStyleLibrary(
        cache: SkyStudioContentCache(directory: root),
        api: { SkyStudioAPI(session: SkyStudioStub.session, base: base, version: "0.18.70", machine: String(repeating: "c", count: 64)) },
        key: { env.hasKey ? .success(key) : .failure(.noKey) },
        licence: { env.licence }, now: { env.now })
}

/// The fake Sky Studio: the manifest at /content (ETag "m1"), each style by its version.
private func serve(manifest: String, styles: [JSONValue]) {
    SkyStudioStub.reset { seen in
        if seen.url.hasSuffix("/content") { return .headers(200, manifest, ["ETag": "\"m1\""]) }
        let version = URLComponents(string: seen.url)?.queryItems?.first { $0.name == "version" }?.value
        guard let style = styles.first(where: { $0["version"]?.stringValue == version }) else {
            return .http(404, #"{"error": {"code": "not_found", "message": "No such version."}}"#)
        }
        return .headers(200, style.encodedString(), ["ETag": "\"\(style["sha256"]?.stringValue ?? "")\""])
    }
}

/// The style requests sent since the last reset, as paths with their query.
private func styleRequests() -> [String] {
    SkyStudioStub.log.compactMap { seen -> String? in
        guard let range = seen.url.range(of: "/content/styles/") else { return nil }
        return String(seen.url[range.lowerBound...])
    }
}

@MainActor
private func expectReadProblem(_ library: SkyStudioStyleLibrary, _ id: String, _ version: String?,
                               _ expected: SkyStudioStyleLibrary.ReadProblem, _ message: String) async {
    do {
        _ = try await library.read(id, version: version)
        check(false, "\(message): it was read")
    } catch let problem as SkyStudioStyleLibrary.ReadProblem {
        checkEqual(problem, expected, message)
    } catch {
        check(false, "\(message): \(error)")
    }
}
