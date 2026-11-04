import Foundation
import SrtFlowMCPKit

// 收费前的本地缓存边界：实际资产可复用，报价只准同一账户/工程/原始请求和显式双缝审查。
@MainActor
func runOfficialPreparedChecks() async {
    let cache = SkyStudioOfficialPrepared()
    let scope = SkyStudioOfficialPrepared.Scope(accountID: "account-a", keyDigest: "key-a", projectPath: "/tmp/story.skycut", projectGeneration: 10)
    let sources: JSONValue = [["role": "first_frame", "file": ["path": "/tmp/original.png", "inode": "1", "bytes": "23"]]]
    let first = "https://assets.example/originals/account-a/real-first.png"
    let token = cache.rememberAssets(scope: scope, sources: sources, inputs: ["image_url": first], references: [])
    checkEqual(try? cache.assets(token, scope: scope, sources: sources).inputs["image_url"], first, "prepared token preserves actual uploaded URL")
    checkEqual(cache.reusableAssets(scope: scope, sources: sources)?.0, token, "unchanged originals can reuse upload when model changes")
    for field in ["account", "key", "project", "generation"] {
        var changed = scope
        if field == "account" { changed.accountID = "account-b" }
        if field == "key" { changed.keyDigest = "key-b" }
        if field == "project" { changed.projectPath = "/tmp/other.skycut" }
        if field == "generation" { changed.projectGeneration += 1 }
        check((try? cache.assets(token, scope: changed, sources: sources)) == nil, "prepared token rejects changed " + field)
    }
    let changedFile: JSONValue = [["role": "first_frame", "file": ["path": "/tmp/original.png", "inode": "2", "bytes": "23"]]]
    check((try? cache.assets(token, scope: scope, sources: changedFile)) == nil, "same-path replacement invalidates prepared asset")
    check((try? cache.assets(token, scope: scope, sources: sources, now: Date().addingTimeInterval(90000))) == nil, "expired asset token rejected")

    let film = try! SkyStudioFilm(json: filmCheckJSON(middle: true))
    let request = SkyStudioJobRequest(kind: "image_to_video", model: "synthetic-video", prompt: "Original scene.",
        inputs: ["image_url": first], params: ["reference_image_count": 0, "mode": "frames"], film: film)
    let review = SkyStudioSeamReview(previous: "left-current", next: "right-current")
    let expiry = Date().addingTimeInterval(600)
    let quote = SkyStudioQuote(credits: 8, officialRecipe: .init(recipePin: "opaque-test-pin", expiresAt: expiry, seamReview: review))
    let identity: JSONValue = ["request": request.quoteBody, "sources": sources, "destination": "/tmp/result.mp4"]
    guard let quoted = try? cache.rememberQuote(scope: scope, identity: identity, request: request, quote: quote) else {
        check(false, "valid official quote cached"); return
    }
    guard let ready = try? cache.reviewedQuote(quoted, scope: scope, identity: identity, review: review) else {
        check(false, "explicit current double review accepts exact request"); return
    }
    checkEqual(ready.request.recipePin, "opaque-test-pin", "opaque server pin copied only to exact reviewed request")
    checkEqual(ready.request.maxCredits, 8, "exact server quote sets paid ceiling")
    checkEqual(ready.request.quoteBody, request.quoteBody, "pin/review addition never changes quoted body")
    checkEqual(ready.request.params["reference_image_count"], 0, "official frame roles are not multimodal reference counts")
    for badReview in [SkyStudioSeamReview(previous: "left-stale", next: "right-current"), .init(previous: "left-current"), .init()] {
        check((try? cache.reviewedQuote(quoted, scope: scope, identity: identity, review: badReview)) == nil, "missing or stale seam rejects before gate")
    }
    check((try? cache.reviewedQuote(quoted, scope: scope, identity: identity, review: review, now: expiry)) == nil, "expired exact quote rejects before gate")
    check((try? cache.reviewedQuote(quoted, scope: scope, identity: ["request": request.quoteBody, "sources": changedFile], review: review)) == nil,
          "changed original identity rejects old quote")
    check((try? cache.claim(quoted, for: "paid-key")) != nil, "quote claimed by its original operation")
    check((try? cache.claim(quoted, for: "paid-key")) != nil, "same operation may resume quote claim")
    check((try? cache.claim(quoted, for: "second-paid-key")) == nil, "one reviewed quote cannot start a second paid operation")

    let publicArgs: JSONValue = ["project": "p1", "kind": "image_to_video", "film": film.json, "image": "/tmp/original.png", "idempotency_key": "stable"]
    var restarted = publicArgs.objectValue!
    restarted["project"] = "p9"; restarted["quote_token"] = "expired"; restarted["seam_review"] = review.json
    checkEqual(SkyStudioOfficialPrepared.argumentsDigest(publicArgs), SkyStudioOfficialPrepared.argumentsDigest(.object(restarted)),
               "receipt recovery survives new short project id and stale preparation tokens")
    restarted["model"] = "other"
    check(SkyStudioOfficialPrepared.argumentsDigest(publicArgs) != SkyStudioOfficialPrepared.argumentsDigest(.object(restarted)), "receipt digest binds model choice")
    await runRecipeUnavailableRefundChecks(request, review: review)
}

private func runRecipeUnavailableRefundChecks(_ request: SkyStudioJobRequest, review: SkyStudioSeamReview) async {
    var paid = request
    paid.recipePin = "opaque-test-pin"; paid.seamReview = review; paid.maxCredits = 8
    SkyStudioStub.reset { _ in .http(503, #"{"error":{"code":"recipe_unavailable","message":"Official recipe unavailable."}}"#) }
    let failure = await jobFailure { _ = try await SkyStudioJobRun(api: jobAPI(), key: jobKey).run(paid) }
    check(failure?.canRefund(beforeAccepted: true) == true, "recipe_unavailable before admission releases local reservation")
    checkEqual(failure?.rejectedBeforeAdmissionCode, "recipe_unavailable", "clear recipe rejection can be persisted as not admitted")
    check(failure?.canRefund(beforeAccepted: false) == false, "recipe_unavailable never proves an accepted job refunded")
    checkEqual(SkyStudioStub.log.map(\.method), ["POST"], "unavailable recipe never retries, downgrades or polls an unaccepted operation")
    SkyStudioStub.reset { _ in .failure(.timedOut) }
    let unknown = await jobFailure { _ = try await SkyStudioJobRun(api: jobAPI(), key: jobKey).run(paid) }
    check(unknown?.canRefund(beforeAccepted: true) == false, "lost official POST keeps reservation and unknown outcome")
    checkEqual(SkyStudioStub.log.count, 1, "lost official POST is not replayed")
    for fields: [String: JSONValue] in [
        ["billing": ["status": "charged", "credits_charged": 8]], ["job_id": "already-admitted"]
    ] {
        let value = SkyStudioJobError.request(.server(.init(status: 503, code: "recipe_unavailable", message: "Conflicting evidence", fields: fields)))
        check(value.rejectedBeforeAdmissionCode == nil, "conflicting billing or accepted task identity cannot become a not-submitted receipt")
    }
}
