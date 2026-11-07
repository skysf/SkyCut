import Foundation
import CryptoKit
import SrtFlowMCPKit

// 官方生成准备好的资产与报价：只活在本次 App 运行里；pin 不进工程、回执、日志或工具结果。
// 纯缓存合同可独立检查；上传、账户读取和真实收费仍经既有 Sky Studio 路径。
@MainActor
final class SkyStudioOfficialPrepared {
    static let shared = SkyStudioOfficialPrepared()

    struct Scope: Equatable, Sendable {
        var accountID: String
        var keyDigest: String
        var projectPath: String
        var projectGeneration: Int
    }

    struct Assets: Sendable {
        var scope: Scope
        var sources: JSONValue
        var inputs: [String: String]
        var references: [JSONValue]
        var expiresAt: Date

        var allInputs: JSONValue {
            var result = inputs.mapValues(JSONValue.string)
            if !references.isEmpty { result["references"] = .array(references) }
            return .object(result)
        }
    }

    struct Quote: Sendable {
        var scope: Scope
        var identity: JSONValue
        var request: SkyStudioJobRequest
        var quote: SkyStudioQuote
        var submittedKey: String?
    }

    private var assets: [String: Assets] = [:]
    private var quotes: [String: Quote] = [:]

    func forget() { assets = [:]; quotes = [:] }

    static func digest(_ value: JSONValue) -> String {
        SHA256.hash(data: Data(value.encodedString().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 准备、报价、确认的瞬时凭据不影响跨重启找原单；实际故事/输入/规格仍全部参与。
    static func argumentsDigest(_ arguments: JSONValue) -> String {
        var value = arguments.objectValue ?? [:]
        for key in ["project", "idempotency_key", "confirm_token", "prepare_references", "prepared_references", "quote_only", "quote_token", "seam_review"] {
            value[key] = nil
        }
        return digest(.object(value))
    }

    func rememberAssets(scope: Scope, sources: JSONValue, inputs: [String: String], references: [JSONValue], now: Date = Date()) -> String {
        let token = "refs-" + UUID().uuidString.lowercased()
        assets[token] = Assets(scope: scope, sources: sources, inputs: inputs, references: references, expiresAt: now.addingTimeInterval(86400))
        return token
    }

    func assets(_ token: String, scope: Scope, sources: JSONValue, now: Date = Date()) throws -> Assets {
        guard let found = assets[token], found.expiresAt > now else {
            throw AIToolError("prepared_references is missing, expired or from an earlier App run. Prepare original references again; no generation was started.")
        }
        guard found.scope == scope, found.sources == sources else {
            throw AIToolError("The prepared references belong to different files, roles, order, account or project. Prepare this exact image set again; no generation was started.")
        }
        return found
    }

    /// 同一组原始图片改选模型不必再上传；新模型仍在调用方按 /models 全量核对。
    func reusableAssets(scope: Scope, sources: JSONValue, now: Date = Date()) -> (String, Assets)? {
        assets.first { $0.value.scope == scope && $0.value.sources == sources && $0.value.expiresAt > now }
    }

    func rememberQuote(scope: Scope, identity: JSONValue, request: SkyStudioJobRequest, quote: SkyStudioQuote) throws -> String {
        guard let film = request.film, let official = quote.officialRecipe else {
            throw AIToolError("Sky Studio did not return an official quote. No generation or credit reservation was started; this does not prove production recipes are enabled.")
        }
        try official.validate(for: film, review: official.seamReview)
        let token = "quote-" + UUID().uuidString.lowercased()
        quotes[token] = Quote(scope: scope, identity: identity, request: request, quote: quote)
        return token
    }

    func reviewedQuote(_ token: String, scope: Scope, identity: JSONValue, review: SkyStudioSeamReview, now: Date = Date()) throws -> Quote {
        guard var found = quotes[token], let film = found.request.film, let official = found.quote.officialRecipe else {
            throw AIToolError("quote_token is missing or from an earlier App run. Request an official quote and review its adjacent seams first.")
        }
        guard found.scope == scope, found.identity == identity else {
            throw AIToolError("The official request, references, destination, account or project changed after quoting. Obtain a fresh quote and review both affected seams; nothing was reserved or submitted.")
        }
        try official.validate(for: film, review: review, now: now)
        found.request.recipePin = official.recipePin
        found.request.seamReview = review
        found.request.maxCredits = found.quote.credits
        try SkyStudioOfficialRequest.validate(found.request, submitting: true)
        return found
    }

    func claim(_ token: String, for operationKey: String) throws {
        guard var found = quotes[token] else { throw AIToolError("The official quote is no longer available.") }
        guard found.submittedKey == nil || found.submittedKey == operationKey else {
            throw AIToolError("This quote already started another operation. Query its original job; a new paid operation needs a new quote and review.")
        }
        found.submittedKey = operationKey
        quotes[token] = found
    }
}
