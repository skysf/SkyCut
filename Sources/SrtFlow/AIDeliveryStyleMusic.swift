import Foundation
import SrtFlowCore

// MARK: - Does the editing style a film was cut with expect music? (inspect_video's no-music row; the user, 2026-11-20)
//
// What this owns: one answer for a film, read from the editing style it records (TimelineState.editingStyle, v40, written by
// AIEditingStyleStamp). The user's decision (「按风格定」): when the film's style expects music, a video of 15 s or more with no
// music anywhere is the suspect `audio_music_missing`, which can be marked intentional like any finding; otherwise it stays the
// grey hint `audio_no_music` (the rule is AIDeliveryMusic.noMusic). Each style says it in one place:
// - a preset in its header (`music: expected`, AIRecipe.expectsMusic): cinematic-opening and sci-fi, both trailer-like; the
//   other three say `optional`;
// - a Sky Studio style in the manifest's `expects_music` (SkyStudioContentManifest.Style.expectsMusic) when Sky Studio publishes
//   it (it does not yet), else `skyStudioExpectingMusic` below, by id.
// The user's own styles (a preset the user replaced too: their text is what was followed), a style SkyCut no longer knows and a
// film with no recorded style: no expectation, the grey hint. inspect_video asks once when it starts (AIInspectionTool.start),
// so a job keeps the answer it started with, like the rest of what it freezes.
// Not this file: the rule and its wording (AIDeliveryMusic.noMusic), the record (EditingStyleRecord), reading a style
// (AIRecipeSkyStudio), the rows' doc (docs/architecture/finished-video-inspection.md, "No music where the style expects it").

enum AIDeliveryStyleMusic {
    /// The style a film was cut with, when that style expects music.
    struct Style: Equatable, Sendable {
        var id: String
        var title: String
    }

    /// Sky Studio styles that expect music, while Sky Studio's manifest does not say (`expects_music`).
    static let skyStudioExpectingMusic: Set<String> = ["film-trailer"]

    /// The App's answer for a film's record: the presets in its resources, Sky Studio's styles as listed on this Mac. Each is
    /// read only for a record of its own source.
    @MainActor
    static func expecting(_ record: EditingStyleRecord?) -> Style? {
        guard let record else { return nil }
        switch record.source {
        case AIRecipe.Source.builtIn.rawValue: return expecting(record, presets: AIBuiltInRecipes.load(), listed: [])
        case AIRecipe.Source.skyStudio.rawValue: return expecting(record, presets: [], listed: SkyStudioStyles.shared.listing.styles)
        default: return nil
        }
    }

    /// Pure: `presets` the App's presets, `listed` Sky Studio's styles as listed on this Mac.
    static func expecting(_ record: EditingStyleRecord?, presets: [AIRecipe], listed: [SkyStudioContentManifest.Style]) -> Style? {
        guard let record else { return nil }
        switch record.source {
        case AIRecipe.Source.builtIn.rawValue:
            guard let preset = presets.first(where: { $0.id == record.id }), preset.expectsMusic == true else { return nil }
            return Style(id: preset.id, title: preset.title)
        case AIRecipe.Source.skyStudio.rawValue:
            let entry = listed.first { $0.id == record.id }
            guard entry?.expectsMusic ?? skyStudioExpectingMusic.contains(record.id) else { return nil }
            return Style(id: record.id, title: entry?.title ?? record.id)
        default:
            return nil
        }
    }
}
