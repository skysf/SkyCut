import Foundation
import SrtFlowMCPKit

// 角色 A 的真实 API / 组合检查，假 URLSession 不碰生产 Key 或供应商。
let characterID = "11111111-1111-4111-8111-111111111111"
let characterRevision = String(repeating: "a", count: 64)
func characterJSON(revision: String = characterRevision) -> JSONValue {
    ["id": .string(characterID), "name": "Pilot", "status": "ready", "revision": .string(revision),
     "images": .object(Dictionary(uniqueKeysWithValues: SkyStudioCharacter.roles.map { role in
         (role, ["role": .string(role), "asset_url": .string("https://assets.example/characters/user/\(characterID)/\(role)/v1.png"), "mime_type": "image/png"])
     }))]
}
func characterUsage(roles: [String] = ["front", "headshot"], revision: String = characterRevision, mode: String? = nil, count: Int? = nil) -> JSONValue {
    var value: [String: JSONValue] = ["character_id": .string(characterID), "revision": .string(revision),
        "roles": .array(roles.map(JSONValue.string)), "reference_image_count": .number(Double(count ?? roles.count))]
    if let mode { value["mode"] = .string(mode) }
    return .object(value)
}

@MainActor
func runCharacterChecks() async {
    let api = SkyStudioAPI(session: SkyStudioStub.session)
    do {
        SkyStudioStub.reset { request in
            if request.url.contains("cursor=") { return .http(200, ["characters": [], "next_cursor": JSONValue.null].jsonText) }
            return .http(200, JSONValue.object(["characters": .array([characterJSON()]), "next_cursor": .string(characterID)]).encodedString())
        }
        let cache = SkyStudioCharacterCache()
        let first = try await cache.page(limit: 1, cursor: nil, status: "all", key: "key-A", api: api)
        checkEqual(first.characters.first?.revision, characterRevision, "list retains opaque revision")
        checkEqual(first.nextCursor, characterID, "list preserves pagination cursor")
        _ = try await cache.page(limit: 1, cursor: nil, status: "all", key: "key-A", api: api)
        checkEqual(SkyStudioStub.log.count, 1, "same account page may use hot cache")
        let second = try await cache.page(limit: 1, cursor: first.nextCursor, status: "all", key: "key-A", api: api)
        check(second.characters.isEmpty && second.nextCursor == nil, "last page terminates pagination")
        _ = try await cache.page(limit: 1, cursor: nil, status: "all", key: "key-B", api: api)
        checkEqual(SkyStudioStub.log.count, 3, "changing Key never serves another owner's cached page")
        check(SkyStudioStub.log[0].url.contains("status=all") && SkyStudioStub.log[1].url.contains("cursor=" + characterID), "page query uses limit/status/cursor")
        cache.forget()
        check(cache.cached(characterID) == nil, "forget clears cached character details")
        SkyStudioStub.reset { request in
            let old = request.headers["Authorization"] == "Bearer old-key"
            if old { Thread.sleep(forTimeInterval: 0.08) }
            return .http(200, JSONValue.object(["characters": .array([characterJSON(revision: String(repeating: old ? "a" : "b", count: 64))]), "next_cursor": .null]).encodedString())
        }
        let late = Task { try await cache.page(limit: 1, cursor: nil, status: "ready", key: "old-key", api: api) }
        while SkyStudioStub.log.isEmpty { await Task.yield() }
        cache.forget() // 换 Key 清缓存时，原 URLSession 仍可能在路上；不靠第二个 HTTP 的返回先后来断言。
        _ = try await late.value
        check(cache.cached(characterID) == nil, "late old-Key response cannot repopulate an invalidated cache")
        _ = try await cache.page(limit: 1, cursor: nil, status: "ready", key: "new-key", api: api)
        checkEqual(cache.cached(characterID)?.revision, String(repeating: "b", count: 64), "late old-Key response cannot repopulate the new owner's cache")

        SkyStudioStub.reset { _ in .http(200, JSONValue.object(["character": characterJSON()]).encodedString()) }
        let detail = try await api.character(characterID, key: "test")
        checkEqual(Set(detail.images.keys), Set(SkyStudioCharacter.roles), "detail retains available views")
        checkEqual(SkyStudioStub.log.first?.method, "GET", "detail is read-only")
        for invalid in ["../jobs", "x?query=1", "", "/tmp/image.png"] {
            do { _ = try await api.character(invalid, key: "test"); check(false, "invalid character paths rejected") } catch { check(true, "invalid character paths rejected") }
        }

        var request = SkyStudioJobRequest(kind: "image", model: "test-model", prompt: "Pilot",
            params: ["reference_image_count": 0], character: .init(id: characterID, roles: ["front", "headshot"]))
        SkyStudioStub.reset { _ in .http(200, JSONValue.object(["credits": 43, "character_usage": characterUsage()]).encodedString()) }
        let quote = try await api.quote(request, key: "test")
        let quotedBody = try JSONValue.decode(SkyStudioStub.log[0].body!)
        checkEqual(quotedBody["character_id"], .string(characterID), "quote uses server character id")
        checkEqual(quotedBody["character_roles"], ["front", "headshot"], "quote passes explicit ordered roles")
        check(quotedBody["inputs"] == nil && quotedBody["max_credits"] == nil && quotedBody["idempotency_key"] == nil, "quote does not upload, reserve or submit")
        checkEqual(SkyStudioStub.log.count, 1, "quote is exactly one HTTP quote without upload")
        request.character = try request.character!.quoted(quote.characterUsage!, localImages: 0)
        request.maxCredits = quote.credits; request.idempotencyKey = "stable-character-job"
        SkyStudioStub.reset { _ in .http(202, JSONValue.object(["job_id": "job", "status": "queued", "character_usage": characterUsage()]).encodedString()) }
        let accepted = try await api.submit(request, key: "test")
        let submitted = try JSONValue.decode(SkyStudioStub.log[0].body!)
        checkEqual(submitted["character_revision"], .string(characterRevision), "paid submit binds quoted revision")
        checkEqual(submitted["max_credits"], 43, "paid submit binds exact quote")
        checkEqual(submitted["idempotency_key"], "stable-character-job", "submit keeps stable operation key")
        checkEqual(accepted.characterUsage?.roles, ["front", "headshot"], "accepted job retains actual role selection")
        var missingRevision = request; missingRevision.character?.revision = nil
        do { _ = try await api.submit(missingRevision, key: "test"); check(false, "submission requires revision") } catch { check(true, "submission requires revision") }
        do {
            _ = try request.character!.quoted(SkyStudioCharacterUsage(json: characterUsage(revision: String(repeating: "b", count: 64))), localImages: 0)
            check(false, "changed view requires fresh quote")
        } catch { check(true, "changed view requires fresh quote") }

        runCharacterCombinationChecks()
        for (code, status) in [("character_not_ready", 409), ("character_changed", 409), ("character_checkpoint_failed", 503), ("not_found", 404), ("price_changed", 409)] {
            SkyStudioStub.reset { _ in .http(status, JSONValue.object(["error": ["code": .string(code), "message": "Server says why", "job_id": "original", "credits_reserved": 0, "submission_state": "not_submitted"]]).encodedString()) }
            let error = await expectFailure(code) { _ = try await api.quote(request, key: "test") }
            if let error {
                let tool = SkyStudioCharacterError.tool(error)
                checkEqual(tool.details["code"], .string(code), "machine-readable error survives: \(code)")
                checkEqual(tool.message, "Server says why", "server explanation survives: \(code)")
                check(tool.details["next_step"] != nil, "actionable recovery for \(code)")
            }
        }
    } catch { check(false, "Character A checks: \(error)") }
}

private func runCharacterCombinationChecks() {
    let character = SkyStudioCharacterReference(id: characterID, roles: nil)
    var plan = SkyStudioReferencePlan(mode: "images", files: [], character: character)
    var model = SkyStudioModel(id: "images", kind: "image", title: "Image", limits: ["references": ["max_images": 2, "max_total_files": 2]])
    plan = SkyStudioCharacterGeneration.references(plan, model: model, explicitMode: nil)
    checkEqual(plan.quoteParams["reference_image_count"], 0, "quote count excludes server character views")
    checkEqual(plan.files.count, 0, "server views never become local file paths")
    plan.character?.roles = ["front", "side", "back"]
    plan = SkyStudioCharacterGeneration.references(plan, model: model, explicitMode: nil)
    check(plan.problem(model: model) != nil, "explicit role overflow is rejected, never silently dropped")
    model.kind = "image_to_video"; model.params = ["mode": ["frames", "multimodal"]]
    model.inputs = ["modes": ["frames": ["max_images": 2], "multimodal": ["max_images": 4, "max_total_files": 4]]]
    plan.character?.roles = nil
    plan.mode = "frames"
    let multimodal = SkyStudioCharacterGeneration.references(plan, model: model, explicitMode: nil)
    checkEqual(multimodal.mode, "multimodal", "H3-compatible character-only input uses multimodal mode")
    model.params = [:]; model.inputs = ["modes": ["frames": ["max_images": 2]]]
    let frames = SkyStudioCharacterGeneration.references(plan, model: model, explicitMode: nil)
    checkEqual(frames.mode, "frames", "frames-only model uses front instead of automatic last frame")
    check(SkyStudioCharacterGeneration.problem(frames, model: model) == nil, "no local image needed for server front frame")
    var multiple = frames; multiple.character?.roles = ["front", "back"]
    check(SkyStudioCharacterGeneration.problem(multiple, model: model) != nil, "multiple explicit views cannot masquerade as start/end frames")
}

private extension Dictionary where Key == String, Value == JSONValue {
    var jsonText: String { JSONValue.object(self).encodedString() }
}
