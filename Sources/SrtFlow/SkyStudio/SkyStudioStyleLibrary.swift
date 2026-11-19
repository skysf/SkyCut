import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio's editing styles on this Mac: the list, reading one, the copies (SS5 plan 5.1, 5.4)
//
// What this owns:
// - the list: the manifest kept on this Mac, asked again when it is 10 minutes old (with its ETag, so usually a 304). When Sky
//   Studio cannot be reached the copy here is used and says when it was fetched; nothing here and unreachable = no Sky Studio
//   styles. After a failed ask, the next minute uses the copy without asking again;
// - reading one: this Mac's copy when it holds that version, else Sky Studio (checksum checked, then kept by checksum);
// - who may read: only while the licence includes `recipes` (SkyCutLicense.recipes). A licence's valid_until never passes the
//   trial's end, so the copies stop being served when the trial ends, offline too;
// - deleting (licenceChanged, from SkyStudioAccount): every text when a fresh /me leaves `recipes` out or the key is invalid,
//   everything when the key is removed. A fetch that was under way when that happened is not written back.
// The key is read silently, like the background /me: never a keychain prompt. Settings subscribes to `listing`.
// Not this file: the files (SkyStudioContentCache), HTTP (SkyStudioContentAPI), the recipes answer (AIRecipeTools,
// AIRecipeSkyStudio), what the AI is told when the licence refuses (SkyCutGates.styleRefusal).

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
        /// Checksums of the texts on this Mac (only while entitled): what can be read without Sky Studio.
        var stored: Set<String> = []
    }

    /// One style as read for the AI.
    struct Read: Equatable, Sendable {
        var style: SkyStudioStyleText
        /// Non-nil = from this Mac's copy, fetched then.
        var cachedAt: Date?
    }

    /// Why a style could not be read; `message` is for the AI (English).
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
        }
        if next.entitled { next.stored = cache.storedChecksums() }
        if next != listing { listing = next }
    }

    // MARK: Reading one

    /// One style at `version` (nil or `latest` = the version the list names now).
    func read(_ id: String, version: String?) async throws -> Read {
        guard licence().recipes else { throw ReadProblem.notEntitled }
        let listed = listing.styles.first { $0.id == id }
        let asked = version.flatMap { $0.lowercased() == "latest" ? nil : $0 }
        guard let wanted = asked ?? listed?.version else { throw ReadProblem.notListed(id: id) }
        if let listed, listed.version == wanted, let copy = cache.style(sha256: listed.sha256) {
            return Read(style: copy.style, cachedAt: copy.fetchedAt)
        }
        if let copy = cache.style(id: id, version: wanted) { return Read(style: copy.style, cachedAt: copy.fetchedAt) }
        let key: String
        switch await self.key() {
        case .success(let value): key = value
        case .failure(let problem): throw ReadProblem.key(problem.message)
        }
        let observed = generation
        let style: SkyStudioStyleText
        do {
            style = try await api().contentStyle(id, version: wanted, key: key)
        } catch let failure as SkyStudioFailure {
            throw Self.problem(failure, id: id, version: wanted)
        } catch let refused as SkyStudioContentRequestProblem {
            throw ReadProblem.server(refused.message)
        }
        if let listed, listed.version == wanted, listed.sha256 != style.sha256 {
            throw ReadProblem.server("Sky Studio sent a different text for \(id) \(wanted) than its list names; try again later.")
        }
        // The licence ended or the copies were deleted while this was asked: never keep or serve it.
        guard observed == generation, licence().recipes else { throw ReadProblem.notEntitled }
        try? cache.store(style, fetchedAt: now())
        publish(listing.origin)
        return Read(style: style, cachedAt: nil)
    }

    private static func problem(_ failure: SkyStudioFailure, id: String, version: String) -> ReadProblem {
        switch failure {
        case .network: return .unreachable(id: id, version: version)
        case .server(let error) where error.code == "not_found": return .notFound(id: id, version: version)
        case .server(let error) where error.code == "not_entitled":
            return .server("Sky Studio says this account cannot read its editing styles on this Mac: \(error.message) Ask the user to "
                + "click Check Again in SkyCut Settings → Sky Studio.")
        case .server(let error): return .server("Sky Studio did not send \(id): \(error.message)")
        case .badAnswer: return .server("Sky Studio sent an answer SkyCut does not understand for \(id) \(version); try again later.")
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
