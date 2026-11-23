import Foundation

// MARK: - Why a reference image cannot go to the chosen model and its fallbacks (pure value)
// What it does: one value per refusal (too small, outside the aspect range, animated, not fittable, changed into a non-image),
// with the file, the models and the limit it misses. `message` is the AI's English (the reference check, get_job, the
// official preparation's job); the user's words for the cloud task row are SkyStudioReferenceFitWords (localized).
// Thrown or returned before anything is uploaded or charged.
// Not here: deciding (SkyStudioReferenceFit), writing pixels (SkyStudioReferenceImageFit).

struct SkyStudioReferenceFitFailure: Error, Equatable, Sendable, LocalizedError {
    enum Reason: Equatable, Sendable {
        case tooSmall(minSide: Double, width: Double, height: Double)
        case aspect(min: Double?, max: Double?, ratio: Double)
        case animated(frames: Int)
        /// Not fittable within the limits (a byte limit only reachable below the minimum side, a decode or write that failed).
        case cannotFit(detail: String)
        /// The file was rewritten after it was measured and is no longer an image.
        case unreadable
    }

    var file: String
    var models: [String]
    var reason: Reason

    /// The AI's English: what is wrong, the limit, and that SkyCut neither upscales nor crops.
    var message: String {
        let to = models.joined(separator: " / ")
        let text = SkyStudioReferenceFit.text
        switch reason {
        case .tooSmall(let side, let width, let height):
            return "\(file) is too small for \(to): each side must be at least \(text(side)) px (it is \(text(width))×\(text(height))). SkyCut never upscales."
        case .aspect(let low, let high, let ratio):
            if let low, ratio < low { return "\(file) is too tall for \(to): width / height must be at least \(text(low)) (it is \(text(ratio))). SkyCut does not crop." }
            return "\(file) is too wide for \(to): width / height must be at most \(text(high ?? ratio)) (it is \(text(ratio))). SkyCut does not crop."
        case .animated(let frames):
            return "\(file) is animated (\(frames) frames); \(to) take one still image. Send a single frame."
        case .cannotFit(let detail):
            return "\(file) cannot be fitted for \(to): \(detail)."
        case .unreadable:
            return "\(file) changed after it was measured and is no longer a readable image. Nothing was sent or charged."
        }
    }

    /// Paths that read `localizedDescription` (the official preparation's job) get the AI's English too.
    var errorDescription: String? { message }
}
