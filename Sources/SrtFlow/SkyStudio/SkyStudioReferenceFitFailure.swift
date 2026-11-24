import Foundation

// MARK: - Why a reference image cannot go to the chosen model and its fallbacks (pure value)
// What it does: one value per refusal (too small, outside the aspect range, animated, not fittable, changed into a non-image,
// a set over the total for all reference images together), with the file (or the files), the models and the limit it misses.
// `message` is the AI's English (the reference check, get_job, the official preparation's job); the user's words for the cloud
// task row are SkyStudioReferenceFitWords (localized). Thrown or returned before anything is uploaded or charged.
// Not here: deciding (SkyStudioReferenceFit, SkyStudioReferenceTotal), writing pixels (SkyStudioReferenceImageFit).

struct SkyStudioReferenceFitFailure: Error, Equatable, Sendable, LocalizedError {
    enum Reason: Equatable, Sendable {
        case tooSmall(minSide: Double, width: Double, height: Double)
        case aspect(min: Double?, max: Double?, ratio: Double)
        case animated(frames: Int)
        /// Not fittable within the limits (a byte limit only reachable below the minimum side, a decode or write that failed).
        case cannotFit(detail: String)
        /// The file was rewritten after it was measured and is no longer an image.
        case unreadable
        /// The images together pass the models' total for all of them even at the smallest size SkyCut allows
        /// (SkyStudioReferenceTotal.floorEdge); `file` lists them.
        case tooLargeTogether(total: Double, count: Int)
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
        case .tooLargeTogether(let total, let count):
            return "The \(count) reference images (\(file)) are too large together for \(to): at most \(text(total)) bytes for all of them, "
                + "and even at the smallest size SkyCut allows (a \(text(SkyStudioReferenceTotal.floorEdge)) px long side) they need more. "
                + "Send fewer or smaller images. Nothing was sent or charged."
        }
    }

    /// Paths that read `localizedDescription` (the official preparation's job) get the AI's English too.
    var errorDescription: String? { message }

    /// get_job's next step when official references could not be prepared because an image cannot be fitted.
    static let preparedNextStep = "Nothing was uploaded, reserved or charged. Tell the user what stopped it (message) and what to change: "
        + "fewer or smaller images, or images the models take. Then prepare again (prepare_references=true) with a new idempotency_key."

    /// get_job's next step when Sky Studio's /jobs refused the reference images as too large together, before creating a job.
    static func togetherNextStep(limit: Double?) -> String {
        "Sky Studio refused the reference images before creating a job: together they pass the model's limit of "
            + (limit.map { "\(SkyStudioReferenceFit.text($0)) bytes" } ?? "bytes") + " for all of them, a character's views included. "
            + "Nothing was submitted or charged, so there is no original job to query. Tell the user and change the request: fewer or "
            + "smaller images, fewer character views (character_roles), or a model without that total; then call generate_media again "
            + "with a new idempotency_key."
    }
}
