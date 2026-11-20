import Foundation
import SrtFlowMCPKit

// MARK: - Copies of Sky Studio's content on this Mac (`~/Library/Application Support/SrtFlow/SkyStudioContent/`)
//
// What this owns: the files. `manifest.json` = the last manifest exactly as Sky Studio sent it, with its ETag and when it was
// fetched or last confirmed by a 304; `styles/<id>@<version>.json` = one version of one style (its own fields and text), with when
// it was fetched; `cards/<kind>/<id>@<version>.json` = one version of one craft-card page (kind entry / group / card, SS5 plan
// 5.6), the same way. **A copy is found only by its kind, id and version**, and by its checksum too when the caller knows it: two versions
// may share a text (1.1 changing only use_for), so a checksum alone never names a version (Codex review CXS1 #5; the first layout
// kept whole answers by checksum and served 1.0 for 1.1). Every write is atomic; a copy whose text no longer matches its checksum
// is ignored when read. The folder keeps the identity-class SrtFlow name (docs/architecture/product-name.md) and is never inside a
// project, a log or the app bundle.
// Not this file: whether a copy may be served (only while the licence includes `recipes`) and when to ask Sky Studio again
// (SkyStudioStyleLibrary, which also calls removeTexts / removeAll when the licence changes).

struct SkyStudioContentCache: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlow/SkyStudioContent", isDirectory: true)
    }

    struct Manifest: Equatable, Sendable {
        var manifest: SkyStudioContentManifest
        var etag: String?
        /// When Sky Studio last sent it or said it was still current.
        var fetchedAt: Date
    }

    struct Style: Equatable, Sendable {
        var style: SkyStudioStyleText
        var fetchedAt: Date
        /// The answer's ETag: sent back to ask whether the copy is still current and still allowed on this Mac.
        var etag: String? = nil
    }

    struct CardPage: Equatable, Sendable {
        var page: SkyStudioCardPage
        var fetchedAt: Date
        var etag: String? = nil
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var stylesURL: URL { directory.appendingPathComponent("styles", isDirectory: true) }
    private var cardsURL: URL { directory.appendingPathComponent("cards", isDirectory: true) }

    // MARK: The manifest

    func manifest() -> Manifest? {
        guard let json = Self.read(manifestURL), let answer = json["answer"],
              let manifest = SkyStudioContentManifest(json: answer),
              let fetchedAt = json["fetched_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate) else { return nil }
        return Manifest(manifest: manifest, etag: json["etag"]?.stringValue, fetchedAt: fetchedAt)
    }

    func store(_ manifest: Manifest) throws {
        var object: [String: JSONValue] = ["answer": manifest.manifest.raw, "fetched_at": .string(Self.text(manifest.fetchedAt))]
        if let etag = manifest.etag { object["etag"] = .string(etag) }
        try write(.object(object), to: manifestURL)
    }

    // MARK: Style texts

    /// The name a version of a style is kept under (`film-trailer@1.0`); nil for an id or version that may not name a file.
    static func key(id: String, version: String) -> String? {
        SkyStudioContentRules.isItemID(id) && SkyStudioContentRules.isVersion(version) ? id + "@" + version : nil
    }

    /// The copy of exactly this style at exactly this version (and with this checksum, when the caller knows it); nil when there
    /// is none, it names another id or version, or its text no longer matches its checksum.
    func style(id: String, version: String, sha256: String? = nil) -> Style? {
        guard let key = Self.key(id: id, version: version), let copy = Self.style(at: stylesURL.appendingPathComponent(key + ".json")),
              copy.style.id == id, copy.style.version == version, sha256 == nil || copy.style.sha256 == sha256 else { return nil }
        return copy
    }

    func store(_ style: SkyStudioStyleText, etag: String? = nil, fetchedAt: Date) throws {
        guard let key = Self.key(id: style.id, version: style.version) else {
            throw SkyStudioContentRequestProblem(message: "\(style.id) \(style.version) cannot be kept on this Mac.")
        }
        var object: [String: JSONValue] = ["style": style.json, "fetched_at": .string(Self.text(fetchedAt))]
        if let etag { object["etag"] = .string(etag) }
        try write(.object(object), to: stylesURL.appendingPathComponent(key + ".json"))
    }

    /// The versions with a copy here, as `key(id:version:)` names (not opened: `style(id:version:sha256:)` checks each when read).
    func storedVersions() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: stylesURL, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    // MARK: Craft-card pages

    /// The copy of exactly this page at exactly this version (and checksum, when the caller knows it); nil when there is none,
    /// it is another page or version, or its text no longer matches its checksum.
    func cardPage(_ request: SkyStudioCardRequest, version: String, sha256: String? = nil) -> CardPage? {
        guard let url = cardURL(request, version: version), let json = Self.read(url), let fields = json["page"],
              let page = SkyStudioCardPage(json: fields, request: request, version: version),
              sha256 == nil || page.sha256 == sha256,
              let fetchedAt = json["fetched_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate) else { return nil }
        return CardPage(page: page, fetchedAt: fetchedAt, etag: json["etag"]?.stringValue)
    }

    func store(_ page: SkyStudioCardPage, etag: String? = nil, fetchedAt: Date) throws {
        guard let url = cardURL(page.request, version: page.version) else {
            throw SkyStudioContentRequestProblem(message: "\(page.request.label) \(page.version) cannot be kept on this Mac.")
        }
        var object: [String: JSONValue] = ["page": page.json, "fetched_at": .string(Self.text(fetchedAt))]
        if let etag { object["etag"] = .string(etag) }
        try write(.object(object), to: url)
    }

    /// `cards/<kind>/<id>@<version>.json`; nil for a page or version that may not name a file.
    private func cardURL(_ request: SkyStudioCardRequest, version: String) -> URL? {
        guard let key = Self.key(id: request.id, version: version) else { return nil }
        return cardsURL.appendingPathComponent(request.kind, isDirectory: true).appendingPathComponent(key + ".json")
    }

    // MARK: Deleting

    /// The licence no longer includes the content: every text goes (everything but the manifest); the manifest (titles only)
    /// stays for the locked list.
    func removeTexts() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent != manifestURL.lastPathComponent {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// No key any more: everything goes.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Files

    private func write(_ json: JSONValue, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.encodedData().write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.decode(data)
    }

    private static func style(at url: URL) -> Style? {
        guard let json = read(url), let fields = json["style"], let id = fields["id"]?.stringValue,
              let style = SkyStudioStyleText(json: fields, id: id, version: nil),
              let fetchedAt = json["fetched_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate) else { return nil }
        return Style(style: style, fetchedAt: fetchedAt, etag: json["etag"]?.stringValue)
    }

    private static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
