import Foundation

// MARK: - What the user reads when a reference image could not be fitted (localized)
//
// What it covers: the one line the cloud task row shows (`status.issue`, drawn verbatim) when a generation stopped before
// uploading because a reference image (or the images together) cannot meet the chosen model's limits: which file, which limit,
// and that nothing was charged. What it does not cover: the AI's English (SkyStudioReferenceFitFailure.message), the decision itself
// (SkyStudioReferenceFit).

enum SkyStudioReferenceFitWords {
    static func shown(_ failure: SkyStudioReferenceFitFailure) -> String {
        let text = SkyStudioReferenceFit.text
        switch failure.reason {
        case .tooSmall(let side, _, _):
            return String(format: L10n("“%1$@” is too small for this model: each side must be at least %2$@ px. Nothing was charged."),
                          failure.file, text(side))
        case .aspect(let low, let high, _):
            return String(format: L10n("“%1$@” is too narrow for this model: width / height must be between %2$@ and %3$@. Nothing was charged."),
                          failure.file, text(low ?? 0), high.map(text) ?? "∞")
        case .animated:
            return String(format: L10n("“%@” is animated; this model takes one still image. Nothing was charged."), failure.file)
        case .cannotFit:
            return String(format: L10n("“%@” could not be fitted to this model's limits. Nothing was charged."), failure.file)
        case .unreadable:
            return String(format: L10n("“%@” changed and is no longer a readable image. Nothing was charged."), failure.file)
        case .tooLargeTogether(let total, _):
            return together(limit: total)
        }
    }

    /// The images too large together: SkyCut's own refusal, or Sky Studio's (`too_large_together`, a character's views counted).
    static func together(limit: Double) -> String {
        String(format: L10n("The reference images are too large together for this model: at most %@ bytes for all of them. Send fewer or smaller images. Nothing was charged."),
               SkyStudioReferenceFit.text(limit))
    }
}
