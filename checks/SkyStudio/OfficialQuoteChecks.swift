import Foundation
import SrtFlowMCPKit

// 假 URLSession 上核对真实引用、报价 pin 和双邻缝；没有生产凭据、网络、上传或扣费。
private let officialQuoteSample = """
{"credits":8,"typical_seconds":30,"official_recipe":{"recipe_pin":"opaque.test.pin",
"expires_at":"2099-01-01T00:00:00.000Z","seam_review":{"previous":"left-current","next":"right-current"}}}
"""

func runOfficialQuoteChecks() async {
    guard let film = try? SkyStudioFilm(json: filmCheckJSON(middle: true)) else { check(false, "official quote fixture parses"); return }
    let references: [JSONValue] = [
        ["type": "image", "url": "https://assets.example/originals/test-account/first.png"],
        ["type": "image", "url": "https://assets.example/originals/test-account/second.png"]
    ]
    var job = SkyStudioJobRequest(kind: "image", model: "synthetic-image", prompt: "Original science-fiction test shot.",
                                  params: ["reference_image_count": 2], maxCredits: 8, idempotencyKey: "official-same-key",
                                  references: references, film: film)
    SkyStudioStub.reset { _ in .http(200, officialQuoteSample) }
    guard let quote = try? await jobAPI().quote(job, key: jobKey), let official = quote.officialRecipe else {
        check(false, "full official quote parses"); return
    }
    checkEqual(quote.credits, 8, "official price comes from server")
    checkEqual(official.recipePin, "opaque.test.pin", "opaque pin unchanged")
    checkEqual(official.seamReview.previous, "left-current", "left review preserved")
    checkEqual(official.seamReview.next, "right-current", "right review preserved")
    let sent = SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(sent?["film"], film.json, "official quote contains entire public film")
    checkEqual(sent?["inputs"]?["references"], .array(references), "official quote contains actual image URLs in order")
    check(sent?["max_credits"] == nil && sent?["idempotency_key"] == nil && sent?["recipe_pin"] == nil,
          "quote contains no submission credentials")

    job.recipePin = official.recipePin
    job.seamReview = official.seamReview
    SkyStudioStub.reset { _ in .http(202, #"{"job_id":"official-job","status":"queued","credits_reserved":8}"#) }
    _ = try? await jobAPI().submit(job, key: jobKey)
    let submitted = SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(submitted?["recipe_pin"], "opaque.test.pin", "job sends exact pin")
    checkEqual(submitted?["seam_review"], official.seamReview.json, "job sends both explicit seam acknowledgements")
    checkEqual(submitted?["film"], sent?["film"], "job keeps exact public film")
    checkEqual(submitted?["inputs"], sent?["inputs"], "job keeps actual inputs and order quoted")
    checkEqual(submitted?["idempotency_key"], "official-same-key", "job keeps original submission key")
    checkEqual(try? JSONDecoder().decode(SkyStudioJobRequest.self, from: JSONEncoder().encode(job)), job, "request round trip preserves official credentials")
    checkEqual(try? JSONDecoder().decode(SkyStudioQuote.self, from: JSONEncoder().encode(quote)), quote, "quote round trip preserves credentials")

    check((try? official.validate(for: film, review: official.seamReview, now: Date(timeIntervalSince1970: 0))) != nil, "current exact reviews valid")
    check((try? official.validate(for: film, review: official.seamReview, now: official.expiresAt)) == nil, "expiry boundary is invalid")
    check((try? official.validate(for: film, review: .init(previous: "left-old", next: "right-current"))) == nil, "stale left acknowledgement rejected")
    check((try? official.validate(for: film, review: .init(previous: "left-current", next: "right-old"))) == nil, "stale right acknowledgement rejected")
    check((try? official.validate(for: film, review: .init(previous: "left-current"))) == nil, "middle revision one requires right acknowledgement")

    await runOfficialFailureChecks(job)
    runOfficialApprovalChecks(job)
    runOfficialFrameChecks(film)
}

private func runOfficialFailureChecks(_ good: SkyStudioJobRequest) async {
    for response in [#"{"credits":8}"#, #"{"credits":8,"official_recipe":null}"#,
                     #"{"credits":8,"official_recipe":{"recipe_pin":"x","expires_at":"bad","seam_review":{}}}"#,
                     #"{"credits":8,"official_recipe":{"recipe_pin":"x","expires_at":"2099-01-01T00:00:00Z","seam_review":{"previous":"left"}}}"#] {
        SkyStudioStub.reset { _ in .http(200, response) }
        if case .badAnswer? = await expectFailure("incomplete official quote fails closed", { _ = try await jobAPI().quote(good, key: jobKey) }) {} else {
            check(false, "missing official pin cannot downgrade to ordinary generation")
        }
        checkEqual(SkyStudioStub.log.count, 1, "incomplete quote never submits")
    }
    for omit in ["pin", "left", "right", "film"] {
        var invalid = good
        if omit == "pin" { invalid.recipePin = nil }
        if omit == "left" { invalid.seamReview?.previous = nil }
        if omit == "right" { invalid.seamReview?.next = nil }
        if omit == "film" { invalid.film = nil }
        SkyStudioStub.reset { _ in .http(202, #"{"job_id":"unexpected","status":"queued"}"#) }
        do { _ = try await jobAPI().submit(invalid, key: jobKey); check(false, "missing \(omit) must not submit") }
        catch is SkyStudioFilmError { check(true, "missing \(omit) rejected before HTTP") }
        catch { check(false, "unexpected error for missing \(omit): \(error)") }
        check(SkyStudioStub.log.isEmpty, "no HTTP without \(omit)")
    }
    var invalidInput = good
    invalidInput.inputs["audio_url"] = "https://assets.example/originals/test-account/audio.wav"
    SkyStudioStub.reset { _ in .http(200, officialQuoteSample) }
    check((try? await jobAPI().quote(invalidInput, key: jobKey)) == nil, "current official input rejects audio")
    check(SkyStudioStub.log.isEmpty, "invalid current input does not request quote")

    SkyStudioStub.reset { _ in .http(503, #"{"error":{"code":"recipe_unavailable","message":"Official recipe unavailable."}}"#) }
    if case .server(let error)? = await expectFailure("unavailable recipe", { _ = try await jobAPI().quote(good, key: jobKey) }) {
        checkEqual(error.code, "recipe_unavailable", "service availability remains explicit")
    }
    checkEqual(SkyStudioStub.log.count, 1, "unavailable recipe never falls back or submits")

    var ordinary = good
    ordinary.film = nil; ordinary.recipePin = nil; ordinary.seamReview = nil
    SkyStudioStub.reset { _ in .http(200, #"{"credits":8}"#) }
    check((try? await jobAPI().quote(ordinary, key: jobKey)) != nil, "ordinary quote does not require official recipe")
    check(ordinary.quoteBody["inputs"] == nil && ordinary.quoteBody["film"] == nil, "ordinary quote contract stays unchanged")
    let oldJSON = filmChanging(try! JSONValue.decode(JSONEncoder().encode(ordinary)), ["film"], to: nil)
    check((try? JSONDecoder().decode(SkyStudioJobRequest.self, from: oldJSON.encodedData())) != nil, "old stored request has no required film field")
}

private func runOfficialApprovalChecks(_ good: SkyStudioJobRequest) {
    let original = SkyStudioApproval.identity(job: good, credits: 8)
    var changed = good
    changed.film?.context.lightSource = .mixed
    check(SkyStudioApproval.identity(job: changed, credits: 8) != original, "context changes approval identity")
    changed = good; changed.film?.next?.render.prompt = "A changed neighboring shot."
    check(SkyStudioApproval.identity(job: changed, credits: 8) != original, "neighbor prompt changes approval identity")
    changed = good; changed.references.reverse()
    check(SkyStudioApproval.identity(job: changed, credits: 8) != original, "actual ordered references change approval identity")
    changed = good; changed.film?.sound.foley = "A soft switch click."
    check(SkyStudioApproval.identity(job: changed, credits: 8) != original, "sound plan changes approval identity")
    changed = good; changed.recipePin = "new-opaque-pin"
    check(SkyStudioApproval.identity(job: changed, credits: 8) != original, "new pin changes approval identity even at the same price")
    changed = good; changed.seamReview?.next = "new-right-fingerprint"
    check(SkyStudioApproval.identity(job: changed, credits: 8) != original, "new seam review changes approval identity")
    changed = good; changed.idempotencyKey = "another-submission-key"
    checkEqual(SkyStudioApproval.identity(job: changed, credits: 8), original, "random submission key still not approval identity")
}

private func runOfficialFrameChecks(_ film: SkyStudioFilm) {
    let first = "https://assets.example/originals/test-account/first.png"
    let last = "https://assets.example/originals/test-account/last.png"
    let frames = SkyStudioJobRequest(kind: "image_to_video", model: "synthetic-video", prompt: "Continue the held pose.",
                                    inputs: ["image_url": first, "last_frame_url": last], params: ["mode": "frames"], film: film)
    check((try? SkyStudioOfficialRequest.validate(frames, submitting: false)) != nil, "first and last frames validate")
    checkEqual(frames.quoteBody["inputs"]?["image_url"], .string(first), "first frame role preserved in quote")
    checkEqual(frames.quoteBody["inputs"]?["last_frame_url"], .string(last), "last frame role preserved in quote")
    var bad = frames; bad.inputs["image_url"] = nil
    check((try? SkyStudioOfficialRequest.validate(bad, submitting: false)) == nil, "last frame cannot replace missing first")
    bad = frames; bad.references = [["type": "image", "url": .string(first)]]
    check((try? SkyStudioOfficialRequest.validate(bad, submitting: false)) == nil, "frame and multimodal roles cannot mix")
}
