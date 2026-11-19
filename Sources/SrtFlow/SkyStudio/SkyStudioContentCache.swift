import Foundation
import SrtFlowMCPKit

// MARK: - Copies of Sky Studio's content on this Mac (`~/Library/Application Support/SrtFlow/SkyStudioContent/`)
//
// What this owns: the files. `manifest.json` = the last manifest exactly as Sky Studio sent it, with its ETag and when it was
// fetched or last confirmed by a 304; `items/<sha256>.json` = one style text per checksum, with when it was fetched. Every write
// is atomic; a copy whose text no longer matches its checksum is ignored when read. The folder keeps the identity-class SrtFlow
// name (docs/architecture/product-name.md) and is never inside a project, a log or the app bundle.
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
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var itemsURL: URL { directory.appendingPathComponent("items", isDirectory: true) }

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

    /// The copy with this checksum; nil when there is none or its text no longer matches the checksum.
    func style(sha256: String) -> Style? {
        guard SkyStudioContentRules.isChecksum(sha256) else { return nil }
        let copy = Self.style(at: itemsURL.appendingPathComponent(sha256 + ".json"))
        return copy?.style.sha256 == sha256 ? copy : nil
    }

    /// Any copy of this style at this version: a version that is no longer the current one is found here by id.
    func style(id: String, version: String) -> Style? {
        storedChecksums().sorted().lazy.compactMap { style(sha256: $0) }
            .first { $0.style.id == id && $0.style.version == version }
    }

    func store(_ style: SkyStudioStyleText, fetchedAt: Date) throws {
        let object: JSONValue = ["style": style.json, "fetched_at": .string(Self.text(fetchedAt))]
        try write(object, to: itemsURL.appendingPathComponent(style.sha256 + ".json"))
    }

    /// Checksums with a copy here (not opened: `style(sha256:)` checks the text when it is read).
    func storedChecksums() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: itemsURL, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
            .filter(SkyStudioContentRules.isChecksum))
    }

    // MARK: Deleting

    /// The licence no longer includes the content: every text goes; the manifest (titles only) stays for the locked list.
    func removeTexts() {
        try? FileManager.default.removeItem(at: itemsURL)
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
        return Style(style: style, fetchedAt: fetchedAt)
    }

    private static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
