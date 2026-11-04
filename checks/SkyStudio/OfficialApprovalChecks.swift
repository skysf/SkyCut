import Foundation
import SrtFlowMCPKit

// 真实预算/确认闸 + 幂等完成策略 + HTTP 适配器；确认或预算阻止不是已提交操作。
// 生产入口接同一个 completeStarted，由 sky-studio-wiring 与后台 MCP 场景共同守住。
@MainActor
func runOfficialApprovalChecks() async {
    let suite = "com.srtflow.official-approval-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkyStudioSpendStore(defaults: defaults)
    let access = AIAccessStore(defaults: defaults)
    store.setDailyLimit(1_000)
    let stage = "official-submission:" + suite
    let film = try! SkyStudioFilm(json: filmCheckJSON(middle: true))
    let request = SkyStudioJobRequest(kind: "image_to_video", model: "synthetic-video", prompt: "Original scene.",
        inputs: ["image_url": "https://assets.example/originals/account-a/first.png"],
        params: ["reference_image_count": 0, "mode": "frames"], maxCredits: 8, film: film,
        recipePin: "opaque-approval-pin", seamReview: .init(previous: "left-current", next: "right-current"))
    let approval = SkyStudioApproval.identity(job: request, credits: 8)
    let identity: JSONValue = ["arguments": .string(SkyStudioOfficialPrepared.digest(request.quoteBody)), "project": "/tmp/story.skycut"]
    SkyStudioStub.reset { _ in .http(200, #"{"job_id":"approval-original","kind":"image_to_video","status":"done","billing":{"status":"charged","credits_charged":8},"result":{"url":"https://assets.example/generations/approved.mp4","content_type":"video/mp4"}}"#) }

    func invoke(_ key: String, token: String? = nil) async throws -> AIToolResult {
        if let cached = try SkyStudioGenerationRequests.begin(key, identity: identity, scope: stage) { return cached }
        defer { SkyStudioGenerationRequests.abandonPreparation(key, scope: stage) }
        let decision = try SkyStudioJobGate.decide(credits: 8, summary: "Official upgraded shot", identity: approval,
            args: AIToolArguments(.object(token.map { ["confirm_token": .string($0)] } ?? [:])),
            store: store, access: access, reason: "Explicit quality upgrade")
        let response: AIToolResult
        switch decision {
        case .needsConfirmation(let question): response = question
        case .reserved:
            var paid = request
            paid.idempotencyKey = key
            _ = try await SkyStudioJobRun(api: jobAPI(), key: jobKey).run(paid)
            response = .ok(["status": "started", "job_id": .string("local-" + key)])
        }
        SkyStudioGenerationRequests.completeStarted(key, result: response, scope: stage)
        return response
    }

    do {
        let question = try await invoke("confirmed")
        let token = question.payload["confirm_token"]?.stringValue ?? ""
        checkEqual(question.payload["status"], "needs_confirmation", "official upgrade asks before paid work")
        check(!token.isEmpty, "official approval returns a usable confirmation token")
        check(!question.payload.encodedString().contains("opaque-approval-pin"), "approval result does not expose its bound pin")
        checkEqual(store.spentToday(), 0, "approval question reserves nothing")
        check(SkyStudioStub.log.isEmpty, "approval question sends no HTTP")
        let wrong = try await invoke("confirmed", token: "not-issued")
        check(wrong.payload["confirm_token_refused"] != nil, "same-key wrong confirmation is actually checked, not served from stale question cache")
        let started = try await invoke("confirmed", token: token)
        checkEqual(started.payload["status"], "started", "same key reaches the real gate after confirmation")
        checkEqual(store.spentToday(), 8, "confirmed official request reserves once")
        checkEqual(SkyStudioStub.log.map(\.method), ["POST"], "same-key confirmation sends exactly one paid POST")
        let sent = SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }
        checkEqual(sent?["idempotency_key"], "confirmed", "approved POST preserves original operation key")
        checkEqual(sent?["recipe_pin"], "opaque-approval-pin", "approved POST preserves the exact pinned request")
        let repeated = try await invoke("confirmed", token: token)
        checkEqual(repeated.payload, started.payload, "completed same-key retry returns the original local task")
        checkEqual(SkyStudioStub.log.count, 1, "completed retry never POSTs again")
        checkEqual(store.spentToday(), 8, "completed retry never reserves again")

        store.setDailyLimit(1)
        let blocked = try await invoke("budget-raised")
        checkEqual(blocked.payload["status"], "blocked", "hard budget blocks before confirmation and paid work")
        checkEqual(SkyStudioStub.log.count, 1, "budget block adds no paid POST")
        store.setDailyLimit(1_000)
        let fresh = try await invoke("budget-raised")
        checkEqual(fresh.payload["status"], "needs_confirmation", "same key rechecks current budget after user raises the limit")
        let accepted = try await invoke("budget-raised", token: fresh.payload["confirm_token"]?.stringValue)
        checkEqual(accepted.payload["status"], "started", "budget-unblocked operation can proceed with its current confirmation")
        checkEqual(SkyStudioStub.log.count, 2, "two approved operations produce exactly two POSTs")
        checkEqual(store.spentToday(), 16, "only the two actually approved operations reserve credits")

        for result: AIToolResult in [.ok(["status": "started"]), .ok(["status": "started", "job_id": ""])] {
            let key = UUID().uuidString
            _ = try SkyStudioGenerationRequests.begin(key, identity: identity, scope: stage)
            SkyStudioGenerationRequests.completeStarted(key, result: result, scope: stage)
            SkyStudioGenerationRequests.abandonPreparation(key, scope: stage)
            check(try SkyStudioGenerationRequests.begin(key, identity: identity, scope: stage) == nil,
                  "a started label without an actual local task cannot retire the operation key")
            SkyStudioGenerationRequests.abandonPreparation(key, scope: stage)
        }
    } catch { check(false, "official confirmation lifecycle: \(error)") }
}
