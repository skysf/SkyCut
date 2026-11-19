import Foundation

// MARK: - The editing style a film was cut with (SS5 plan 5.5, FL-15; `TimelineState.editingStyle`, project format v40)
//
// What this owns: what a project remembers about the editing style the AI followed when it changed the film. For a Sky Studio
// style: its id, the version the film stays on (and that text's checksum) until the user moves it to a newer one. For a preset or
// the user's own style: its id, source, the SkyCut version that served it and the text's checksum — recorded, never pinned, as
// their text changes with the App or the user. Decoding is lenient in the project's way: a record without an id, a source or a
// checksum is not a record (the project still opens; TimelineState drops it).
// Not this file: when it is written (AIEditingStyleStamp, inside VideoEditProject.perform), reading the pinned version
// (AIRecipeSkyStudio), what get_timeline says (AIEditingStyleReport).

public struct EditingStyleRecord: Codable, Hashable, Sendable {
    /// `AIRecipe.Source.skyStudio`'s raw value: only these records pin a version.
    public static let skyStudioSource = "sky_studio"

    public var id: String
    /// Where the style comes from: `sky_studio`, `built_in`, `yours`, `yours_replacing_built_in`.
    public var source: String
    /// A Sky Studio style's version; nil for presets and the user's own.
    public var version: String?
    /// SHA-256 of the style text that was read (lowercase hex).
    public var sha256: String
    /// The SkyCut version that served a preset or the user's style.
    public var skycutVersion: String?

    public init(id: String, source: String, version: String? = nil, sha256: String, skycutVersion: String? = nil) {
        (self.id, self.source, self.version, self.sha256, self.skycutVersion) = (id, source, version, sha256, skycutVersion)
    }

    /// Reading this style again for the film returns `version`, not the newest one.
    public var isPinned: Bool { source == Self.skyStudioSource && version != nil }

    private enum CodingKeys: String, CodingKey {
        case id, source, version, sha256, skycutVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard let id = try text(.id), let source = try text(.source), let sha256 = try text(.sha256) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An editing style needs id, source and sha256."))
        }
        self.init(id: id, source: source, version: try text(.version), sha256: sha256, skycutVersion: try text(.skycutVersion))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(sha256, forKey: .sha256)
        try c.encodeIfPresent(skycutVersion, forKey: .skycutVersion)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
