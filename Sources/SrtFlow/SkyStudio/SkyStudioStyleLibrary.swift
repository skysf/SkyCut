import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio's editing styles and craft cards on this Mac: the list, reading one, the copies (SS5 plan 5.1, 5.4, 5.6)
//
// What this owns:
// - the list: the manifest kept on this Mac, asked again when it is 10 minutes old (with its ETag, so usually a 304). When Sky
//   Studio cannot be reached the copy here is used and says when it was fetched; nothing here and unreachable = no Sky Studio
//   styles. After a failed ask, the next minute uses the copy without asking again. The same manifest lists the craft cards;
// - reading one style or one craft-card page (the entry page, a group's catalogue, a card; since 2026-11-20): exactly that kind,
//   id and version, all through one flow (readText). Online, Sky Studio is asked with the ETag of the copy held (it checks this
//   Mac's licence before a 304, contract of c9a7ce5d: every answer is `private, no-cache`), so a refusal there is never answered
//   with the copy; the copy is served without asking only when Sky Studio cannot be reached. A new answer is checked (kind, id,
//   version, checksum) and kept by them. `403 not_entitled` is said in plain words (not registered yet, the Mac limit, the plan);
//   a card page is read at the version the list names now (cards are not pinned to a film), and the cards' own words (nothing
//   published yet, no such group or card) are in SkyStudioCardWords;
// - who may read: only while the licence includes `recipes` (SkyCutLicense.recipes). A licence's valid_until never passes the
//   trial's end, so the copies stop being served when the trial ends, offline too;
// - deleting (licenceChanged, from SkyStudioAccount): every text when a fresh /me leaves `recipes` out or the key is invalid,
//   everything when the key is removed. A fetch that was under way when that happened is not written back.
// The key is read silently, like the background /me: never a keychain prompt. Settings subscribes to `listing`.
// Not this file: the files (SkyStudioContentCache), HTTP (SkyStudioContentAPI), the recipes answer (AIRecipeTools,
// AIRecipeSkyStudio), the craft_cards answer (AICraftCardsAnswer, AICraftCardsTool), what the AI is told when the licence
// refuses (SkyCutGates.styleRefusal / cardRefusal).

@MainActor
final class SkyStudioStyleLibrary: ObservableObject {
    /// How old the manifest may be before the list asks Sky Studio again.
    static let manifestLifetime: TimeInterval = 600
    /// After a failed ask, how long the copy here is used without asking again.
    static let retryAfterFailure: TimeInterval = 60

    struct Listing: Equatable, Sendable {
        enum Origin: Equatable, Sendable {
            /// Asked (or confirmed by a 304) within the last 10 minutes.
            case live
            /// Sky Studio could not be reached, or the key could not be read: this Mac's copy, fetched then.
            case thisMac(fetchedAt: Date)
            /// Unreachable and nothing on this Mac.
            case unreachable
            /// Sky Studio answered `content_unavailable` (nothing published yet, or its store cannot be read) and nothing is here.
            case unavailable
            /// No key: no Sky Studio styles.
            case none
        }

        var styles: [SkyStudioContentManifest.Style] = []
        var release: Int?
        var origin: Origin = .none
        /// The licence included `recipes` when this list was made (the AI path asks the licence again at the moment it reads).
        var entitled = false
        /// The versions with a copy on this Mac (`SkyStudioContentCache.key(id:version:)`, only while entitled): what can be read
        /// without Sky Studio.
        var stored: Set<String> = []
        /// The craft cards the same manifest lists (empty: none published, or no manifest).
        var cards = SkyStudioCardCatalog()
    }

    /// One style as read for the AI.
    struct Read: Equatable, Sendable {
        var style: SkyStudioStyleText
        /// Non-nil = from this Mac's copy, fetched then.
        var cachedAt: Date?
    }

    /// One craft-card page as read for the AI.
    struct CardRead: Equatable, Sendable {
        var page: SkyStudioCardPage
        /// Non-nil = from this Mac's copy, fetched then.
        var cachedAt: Date?
    }

    /// Why a style or a craft-card page could not be read; `message` is for the AI (English). A card page's problems come as
    /// `server` with SkyStudioCardWords' sentences (the other cases' words are about styles).
    enum ReadProblem: Error, Equatable {
        case notEntitled
        case notListed(id: String)
        case notFound(id: String, version: String)
        case unreachable(id: String, version: String)
        case key(String)
        case server(String)

        var message: String {
            switch self {
            case .notEntitled:
                return "Sky Studio's editing styles need SkyCut Pro or the SkyCut trial."
            case .notListed(let id):
                return "Sky Studio does not list a style called \(id) now; give version to read an older one, or pick another style."
            case .notFound(let id, let version):
                return "Sky Studio has no version \(version) of \(id). Leave version out for the current one."
            case .unreachable(let id, let version):
                return "Sky Studio cannot be reached and this Mac has no copy of \(id) \(version). Pick a preset or one of the user's "
                    + "own styles, or try again when SkyCut is online."
            case .key(let message), .server(let message):
                return message
            }
        }
    }

    @Published private(set) var listing = Listing()

    private let cache: SkyStudioContentCache
    private let api: () -> SkyStudioAPI
    private let key: () async -> Result<String, SkyStudioJobKey.Problem>
    private let licence: () -> SkyCutLicense
    private let now: () -> Date
    private var refreshing: Task<Void, Never>?
    private var failedAt: Date?
    /// Bumped whenever copies are deleted: a fetch that started before must not write back.
    private var generation = 0

    init(cache: SkyStudioContentCache = SkyStudioContentCache(directory: SkyStudioContentCache.defaultDirectory),
         api: @escaping () -> SkyStudioAPI = { SkyStudioAPI(session: SkyStudioAPI.uncachedSession) },
         key: @escaping () async -> Result<String, SkyStudioJobKey.Problem> = { await SkyStudioJobKey.key(.silent) },
         licence: @escaping () -> SkyCutLicense, now: @escaping () -> Date = Date.init) {
        (self.cache, self.api, self.key, self.licence, self.now) = (cache, api, key, licence, now)
        let held = cache.manifest()
        publish(held.map { isFresh($0) ? .live : .thisMac(fetchedAt: $0.fetchedAt) } ?? .none)
    }

    // MARK: The list

    /// The list, asking Sky Studio first when the manifest here is 10 minutes old (one ask at a time).
    func refreshedListing() async -> Listing {
        if let held = cache.manifest(), isFresh(held) {
            publish(.live)  // the licence may have changed since (offline past valid_until): say so now
            return listing
        }
        if let failedAt, now().timeIntervalSince(failedAt) < Self.retryAfterFailure, now() >= failedAt {
            publish(cache.manifest().map { .thisMac(fetchedAt: $0.fetchedAt) } ?? (listing.origin == .unavailable ? .unavailable : .unreachable))
            return listing
        }
        if let refreshing {
            await refreshing.value
        } else {
            let task = Task { await self.refreshManifest() }
            refreshing = task
            await task.value
            refreshing = nil
        }
        return listing
    }

    /// Settings: ask again in the background when the list is stale.
    func refreshIfStale() {
        Task { _ = await refreshedListing() }
    }

    private func isFresh(_ held: SkyStudioContentCache.Manifest) -> Bool {
        let age = now().timeIntervalSince(held.fetchedAt)
        return age >= 0 && age < Self.manifestLifetime
    }

    private func refreshManifest() async {
        let held = cache.manifest()
        let observed = generation
        let key: String
        switch await self.key() {
        case .success(let value): key = value
        case .failure(.noKey): return publish(.none)
        case .failure: return publish(held.map { .thisMac(fetchedAt: $0.fetchedAt) } ?? .unreachable)
        }
        do {
            let fresh: SkyStudioContentCache.Manifest
            switch try await api().contentManifest(key: key, etag: held?.etag) {
            case .notModified:
                guard let held else { throw SkyStudioFailure.badAnswer(status: 304) }
                fresh = SkyStudioContentCache.Manifest(manifest: held.manifest, etag: held.etag, fetchedAt: now())
            case .changed(let manifest, let etag):
                fresh = SkyStudioContentCache.Manifest(manifest: manifest, etag: etag, fetchedAt: now())
            }
            guard observed == generation else { return }
            try cache.store(fresh)
            failedAt = nil
            publish(.live)
        } catch {
            failedAt = now()
            guard observed == generation else { return }
            if held == nil, let failure = error as? SkyStudioFailure, case .server(let server) = failure, server.code == "content_unavailable" {
                return publish(.unavailable)
            }
            publish(held.map { .thisMac(fetchedAt: $0.fetchedAt) } ?? .unreachable)
        }
    }

    private func publish(_ origin: Listing.Origin) {
        var next = Listing(origin: origin, entitled: licence().recipes)
        if origin != .none, let held = cache.manifest() {
            next.styles = held.manifest.styles
            next.release = held.manifest.release
            next.cards = held.manifest.cards
        }
        if next.entitled { next.stored = cache.storedVersions() }
        if next != listing { listing = next }
    }

    // MARK: Reading one

    /// One style at exactly `version` (nil or `latest` = the version the list names now). `sha256`: the checksum that version must
    /// have when the caller knows it (a film's record); the list's own is used for the version it names. The answer is always that
    /// id and version: a copy is matched on id + version (+ checksum), never on the text alone (Codex review CXS1 #5).
    func read(_ id: String, version: String?, sha256: String? = nil) async throws -> Read {
        guard licence().recipes else { throw ReadProblem.notEntitled }
        let listed = listing.styles.first { $0.id == id }
        let asked = version.flatMap { $0.lowercased() == "latest" ? nil : $0 }
        guard let wanted = asked ?? listed?.version else { throw ReadProblem.notListed(id: id) }
        let expected = sha256 ?? (listed?.version == wanted ? listed?.sha256 : nil)
        let copy = cache.style(id: id, version: wanted, sha256: expected)
        let read = try await readText(
            "\(id) \(wanted)", expected: expected, held: copy.map { ($0.style, $0.fetchedAt, $0.etag) }, refused: .notEntitled,
            checksum: \.sha256, problem: { Self.problem($0, id: id, version: wanted) },
            fetch: { key, etag in
                switch try await self.api().contentStyle(id, version: wanted, key: key, etag: etag) {
                case .notModified: return nil
                case .changed(let style, let etag): return (style, etag)
                }
            },
            keep: { style, etag, at in try self.cache.store(style, etag: etag, fetchedAt: at) })
        return Read(style: read.text, cachedAt: read.cachedAt)
    }

    /// One craft-card page at the version the list names now (the list asked first, `refreshedListing`). Nothing published, no
    /// such group or card, and every refusal are said in SkyStudioCardWords' plain words, as `ReadProblem.server` / `.key`.
    func readCard(_ page: SkyStudioCardRequest) async throws -> CardRead {
        let refused = ReadProblem.server(SkyStudioCardWords.needsPlan)
        guard licence().recipes else { throw refused }
        let listed = try listedCard(page)
        let copy = cache.cardPage(page, version: listed.version, sha256: listed.sha256)
        let read = try await readText(
            "\(page.label) (version \(listed.version))", expected: listed.sha256, held: copy.map { ($0.page, $0.fetchedAt, $0.etag) },
            refused: refused, checksum: \.sha256, problem: { .server(SkyStudioCardWords.problem($0, page: page, version: listed.version)) },
            fetch: { key, etag in
                switch try await self.api().contentCardPage(page, version: listed.version, key: key, etag: etag) {
                case .notModified: return nil
                case .changed(let read, let etag): return (read, etag)
                }
            },
            keep: { read, etag, at in try self.cache.store(read, etag: etag, fetchedAt: at) })
        return CardRead(page: read.text, cachedAt: read.cachedAt)
    }

    /// The version and checksum the list names for a card page, or why there is nothing to read.
    private func listedCard(_ page: SkyStudioCardRequest) throws -> (version: String, sha256: String) {
        switch listing.origin {
        case .none: throw ReadProblem.key(SkyStudioJobKey.Problem.noKey.message)
        case .unreachable: throw ReadProblem.server(SkyStudioCardWords.listUnreachable)
        case .unavailable: throw ReadProblem.server(SkyStudioCardWords.nonePublished)
        case .live, .thisMac: break
        }
        let cards = listing.cards
        guard !cards.isEmpty else { throw ReadProblem.server(SkyStudioCardWords.nonePublished) }
        guard let listed = cards.listed(page) else { throw ReadProblem.server(SkyStudioCardWords.notListed(page, in: cards)) }
        return listed
    }

    /// One version of one text, the same flow for every kind (a style, a card page): this Mac's copy confirmed with its ETag
    /// while online (Sky Studio checks the licence before its 304) and served without asking only when Sky Studio cannot be
    /// reached; a refusal is never answered with the copy; a new text must have the checksum the list names and is kept only
    /// while nothing was deleted and the licence still includes `recipes` (else `refused`). `fetch` gives nil for a 304.
    private func readText<Text: Sendable>(
        _ label: String, expected: String?, held: (text: Text, fetchedAt: Date, etag: String?)?, refused: ReadProblem,
        checksum: (Text) -> String, problem: (SkyStudioFailure) -> ReadProblem,
        fetch: (_ key: String, _ etag: String?) async throws -> (text: Text, etag: String?)?,
        keep: (Text, String?, Date) throws -> Void
    ) async throws -> (text: Text, cachedAt: Date?) {
        let observed = generation
        let offline = held.map { (text: $0.text, cachedAt: Optional($0.fetchedAt)) }
        let key: String
        switch await self.key() {
        case .success(let value): key = value
        case .failure(let failure):
            if let offline { return try served(offline, observed, refused) }
            throw ReadProblem.key(failure.message)
        }
        let answer: (text: Text, etag: String?)?
        do {
            answer = try await fetch(key, held?.etag)
        } catch let failure as SkyStudioFailure {
            if let offline, Self.unreachable(failure) { return try served(offline, observed, refused) }
            throw problem(failure)
        } catch let wrongShape as SkyStudioContentRequestProblem {
            throw ReadProblem.server(wrongShape.message)
        }
        guard let answer else {
            // 304: still current, and Sky Studio checked this Mac's licence before saying so.
            guard let offline else { throw ReadProblem.server("Sky Studio answered \(label) without a text; try again later.") }
            return try served(offline, observed, refused)
        }
        if let expected, expected != checksum(answer.text) {
            throw ReadProblem.server("Sky Studio sent a different text for \(label) than its list names; try again later.")
        }
        // The licence ended or the copies were deleted while this was asked: never keep or serve it.
        let fresh = try served((text: answer.text, cachedAt: nil), observed, refused)
        try? keep(answer.text, answer.etag, now())
        publish(listing.origin)
        return fresh
    }

    /// Served only while nothing was deleted since the read began and the licence still includes `recipes`.
    private func served<Text>(_ read: (text: Text, cachedAt: Date?), _ observed: Int, _ refused: ReadProblem) throws
        -> (text: Text, cachedAt: Date?) {
        guard observed == generation, licence().recipes else { throw refused }
        return read
    }

    /// Sky Studio could not answer (offline, a 5xx, `content_unavailable`): a copy held is served instead. A refusal is not this.
    private static func unreachable(_ failure: SkyStudioFailure) -> Bool {
        switch failure {
        case .network, .uploadFailed: return true
        case .badAnswer(let status): return status >= 500
        case .server(let error): return error.status >= 500
        }
    }

    private static func problem(_ failure: SkyStudioFailure, id: String, version: String) -> ReadProblem {
        switch failure {
        case .network, .uploadFailed: return .unreachable(id: id, version: version)
        case .server(let error) where error.code == "not_found": return .notFound(id: id, version: version)
        case .server(let error) where error.code == "not_entitled": return .server(notEntitledWords(error))
        case .server(let error): return .server("Sky Studio did not send \(id): \(error.message)")
        case .badAnswer: return .server("Sky Studio sent an answer SkyCut does not understand for \(id) \(version); try again later.")
        }
    }

    /// `403 not_entitled` in plain words (contract of c9a7ce5d: a text goes only to a Mac registered within the account's limit).
    nonisolated static func notEntitledWords(_ error: SkyStudioServerError) -> String {
        notEntitledWords(error, what: "editing styles", still: " The preset styles and the user's own styles still work.")
    }

    /// The same for any of Sky Studio's content: `what` was refused (the craft cards say "craft cards"); `still` keeps working.
    nonisolated static func notEntitledWords(_ error: SkyStudioServerError, what: String, still: String) -> String {
        switch error.fields["plan_reason"]?.stringValue {
        case "machine_not_registered":
            return "Not done: Sky Studio has not registered this Mac for this account yet, so it does not send its \(what) here. "
                + "Ask the user to click Check Again in SkyCut Settings → Sky Studio (that registers this Mac), then try again." + still
        case "machine_limit_reached":
            let action = SkyStudioLinks.webURL(error.fields["manage_machines_url"]?.stringValue).map {
                "Ask the user to open \($0.absoluteString) and remove a Mac in Sky Studio to use this account here."
            } ?? "Ask the user to email \(SkyStudioLinks.supportEmail) to use this account on this Mac."
            return "Not done: this account is already using SkyCut on all of its Macs, so this Mac is on the free plan and does not get "
                + "Sky Studio's \(what). " + action + still
        default:
            return "Not done: Sky Studio says this account's plan does not include its \(what) on this Mac (\(error.message)) "
                + "SkyCut Pro and the SkyCut trial include them; ask the user to click Check Again in SkyCut Settings → Sky Studio." + still
        }
    }

    // MARK: The licence changed

    /// A fresh /me, a new or invalid key, or the key removed (SkyStudioAccount). Not entitled: every text goes (the titles stay
    /// for the locked list); no key: everything goes.
    func licenceChanged(hasKey: Bool, entitled: Bool) {
        if !hasKey {
            generation += 1
            cache.removeAll()
            return publish(.none)
        }
        if !entitled {
            generation += 1
            cache.removeTexts()
        }
        publish(listing.origin)
    }
}
