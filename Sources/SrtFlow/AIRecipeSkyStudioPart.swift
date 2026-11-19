import Foundation

// MARK: - The Sky Studio side of one recipes / save_recipe call (pure value, SS5 plan 5.1)
//
// What this owns: what the answers in AIRecipeTools need to know about Sky Studio's editing styles, gathered before the answer
// is built (by AIRecipeSkyStudio from SkyStudioStyleLibrary) so the answer stays a pure function that RecipeChecks build by hand:
// the styles Sky Studio lists now, where that list came from, whether the licence includes them, and the one style read for
// this call. Also the sentences the AI reads about them (where the list came from, why one cannot be read).
// Not this file: asking Sky Studio, the copies, the licence (SkyStudioStyleLibrary, SkyStudioAccount).

struct AIRecipeSkyStudioPart: Sendable {
    struct Style: Equatable, Sendable {
        var id: String
        var title: String
        var useFor: String
        var version: String
        /// A copy of this version's text is on this Mac (readable without Sky Studio).
        var onThisMac: Bool

        var recipe: AIRecipe {
            AIRecipe(id: id, title: title, useFor: useFor, body: "", source: .skyStudio, version: version)
        }
    }

    enum Origin: Equatable, Sendable {
        /// Asked within the last 10 minutes.
        case live(release: Int?)
        /// Sky Studio could not be reached: this Mac's copy of the list, fetched then.
        case thisMac(release: Int?, fetchedAt: Date)
        /// Unreachable and no copy here.
        case unreachable
        /// Sky Studio has nothing to list now (`content_unavailable`) and no copy is here.
        case unavailable
        /// No key: nothing to say about Sky Studio.
        case none
    }

    /// One style as read for this call.
    struct Read: Equatable, Sendable {
        var id: String
        var title: String
        var useFor: String
        var version: String
        var sha256: String
        var text: String
        /// Non-nil = from this Mac's copy, fetched then.
        var cachedAt: Date?
        /// The SkyCut version the style was checked against, when this SkyCut is older.
        var checkedAgainstNewer: String?
        /// Sky Studio lists a newer version than the one read (the film is pinned to an older one, SS5 plan 5.5).
        var newerVersion: String? = nil
    }

    var styles: [Style] = []
    var origin: Origin = .none
    /// The licence includes Sky Studio's styles now (`features.recipes`).
    var entitled = false
    var read: Read?

    /// Why the AI cannot read this style now; nil = it can.
    func unavailable(_ style: Style) -> String? {
        guard entitled else { return "needs SkyCut Pro or the SkyCut trial" }
        if case .live = origin { return nil }
        return style.onThisMac ? nil : "Sky Studio cannot be reached and this Mac has no copy"
    }

    /// The listing's one sentence on where Sky Studio's part came from (nil when there is no key).
    var originLine: String? {
        switch origin {
        case .live(let release):
            return "Sky Studio's styles" + (release.map { " (release \($0))" } ?? "") + " were checked with Sky Studio just now."
        case .thisMac(let release, let fetchedAt):
            return "Sky Studio could not be reached: Sky Studio's styles" + (release.map { " (release \($0))" } ?? "")
                + " are this Mac's copy from " + Self.day(fetchedAt) + "."
        case .unreachable:
            return "Sky Studio could not be reached and this Mac has no copy of its styles: only the presets and the user's own are listed."
        case .unavailable:
            return "Sky Studio has no editing styles to list now: only the presets and the user's own are listed."
        case .none:
            return nil
        }
    }

    static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
