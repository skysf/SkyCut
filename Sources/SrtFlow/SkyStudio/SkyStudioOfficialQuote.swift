import Foundation
import SrtFlowMCPKit

// 官方报价只持有不透明 pin、有效期和两侧预检指纹；不解密、不把它当作实际画面/听感验收。
// 报价与哪一份准备好的请求绑定、用户何时确认，交给生成流程；这里保住接口合同。
struct SkyStudioSeamReview: Equatable, Sendable, Codable {
    var previous: String?
    var next: String?

    init(previous: String? = nil, next: String? = nil) { self.previous = previous; self.next = next }

    init(json: JSONValue) throws {
        let o = try SkyStudioFilmReader.object(json, keys: ["previous", "next"], at: "seam_review")
        func fingerprint(_ side: String) throws -> String? {
            guard let value = o[side], value != .null else { return nil }
            guard let value = value.stringValue, !value.isEmpty else {
                throw SkyStudioFilmReader.error("seam_review." + side, "Use the current quote's fingerprint or null.")
            }
            return value
        }
        previous = try fingerprint("previous")
        next = try fingerprint("next")
    }

    init(from decoder: Decoder) throws { try self.init(json: JSONValue(from: decoder)) }
    func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
    var json: JSONValue { ["previous": previous.map(JSONValue.string) ?? .null, "next": next.map(JSONValue.string) ?? .null] }

    func validate(for film: SkyStudioFilm) throws {
        guard (film.previous != nil) == (previous?.isEmpty == false), (film.next != nil) == (next?.isEmpty == false) else {
            throw SkyStudioFilmReader.error("seam_review", "Review every adjacent seam from the current quote, including both sides of a middle shot at revision 1.")
        }
    }
}

struct SkyStudioOfficialRecipeQuote: Equatable, Sendable, Codable {
    var recipePin: String
    var expiresAt: Date
    var seamReview: SkyStudioSeamReview

    init(recipePin: String, expiresAt: Date, seamReview: SkyStudioSeamReview) {
        self.recipePin = recipePin; self.expiresAt = expiresAt; self.seamReview = seamReview
    }

    init(json: JSONValue) throws {
        guard let pin = json["recipe_pin"]?.stringValue, !pin.isEmpty,
              let date = json["expires_at"]?.stringValue.flatMap(SkyStudioJSON.parseDate), let review = json["seam_review"] else {
            throw SkyStudioFilmReader.error("official_recipe", "The official quote must include its opaque recipe_pin, expiry and seam review.")
        }
        self.init(recipePin: pin, expiresAt: date, seamReview: try SkyStudioSeamReview(json: review))
    }

    var json: JSONValue {
        ["recipe_pin": .string(recipePin), "expires_at": .string(ISO8601DateFormatter().string(from: expiresAt)), "seam_review": seamReview.json]
    }

    func validate(for film: SkyStudioFilm, review: SkyStudioSeamReview, now: Date = Date()) throws {
        guard expiresAt > now else { throw SkyStudioFilmReader.error("recipe_pin", "The official quote expired. Prepare a fresh quote and review its seams again.") }
        try seamReview.validate(for: film)
        guard review == seamReview else { throw SkyStudioFilmReader.error("seam_review", "The acknowledgements must match this exact quote's seam fingerprints.") }
    }
}

enum SkyStudioOfficialRequest {
    static func validate(_ job: SkyStudioJobRequest, submitting: Bool) throws {
        guard let film = job.film else {
            guard job.recipePin == nil && job.seamReview == nil else {
                throw SkyStudioFilmReader.error("film", "Recipe pins and seam reviews require an official film declaration.")
            }
            return
        }
        _ = try SkyStudioFilm(json: film.json) // 直接用 Swift 值构造后也不能绕过入口校验。
        try SkyStudioFilmInputs.validateOriginalURLs(job.allInputs) // 原始调用者输入仍只能是自己的 uploads。
        try SkyStudioFilmInputs.validate(job.renderInputs, kind: job.kind, params: job.renderParams, allowCharacterDeclarations: job.characterAssets != nil)
        if submitting {
            guard let pin = job.recipePin, !pin.isEmpty, let review = job.seamReview else {
                throw SkyStudioFilmReader.error("recipe_pin", "Use the current official quote and explicitly review its seams before submitting.")
            }
            try review.validate(for: film)
        }
    }
}
