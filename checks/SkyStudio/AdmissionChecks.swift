import Foundation
import SrtFlowMCPKit

// 真 HTTP 适配器上的提交边界：容量重试前重新核对、局部拒绝不冒充网络未知，已知原单只读且 ID 不可漂移。
@MainActor
func runAdmissionChecks() async {
    let request = SkyStudioJobRequest(kind: "image", model: "synthetic-image", prompt: "Original scene.", idempotencyKey: "admission-key")
    let full = #"{"error":{"code":"too_many_jobs","message":"Full","limit":3,"running":3}}"#
    let queued = #"{"job_id":"job-1","status":"queued"}"#
    var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
    let hooks = NameLog()
    let posts = NameLog()
    run.sleep = SleepLog().sleep
    SkyStudioStub.reset { seen in
        if seen.method == "POST" {
            posts.add("post")
            return posts.items.count == 1 ? .http(429, full) : .http(202, queued)
        }
        return .http(200, sampleDoneJobFor("job-1"))
    }
    run.beforeSubmit = {
        hooks.add("checked")
        if hooks.items.count == 2 { throw SkyStudioJobError.notSubmitted("The original project was closed while waiting for a slot.") }
    }
    let rejected = await jobFailure { _ = try await run.run(request) }
    checkEqual(hooks.items.count, 2, "clear capacity refusal rechecks caller state before retry")
    checkEqual(SkyStudioStub.log.map(\.method), ["POST"], "changed caller state sends no second paid POST")
    checkEqual(rejected?.rejectedBeforeAdmissionCode, "local_not_sent", "retry preflight rejection records definite local non-admission")
    check(rejected?.message.contains("project was closed") == true, "preflight failure preserves its specific cause")
    check(rejected?.canRefund(beforeAccepted: true) == true && rejected?.canRefund(beforeAccepted: false) == false,
          "local rejection can release only an unaccepted reservation")
    let suite = "com.srtflow.SrtFlow.admission-check"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkyStudioSpendStore(defaults: defaults)
    let reservation = SkyStudioJobGate.reserveWithoutAsking(credits: 8, store: store)!
    var held = SkyStudioHeldCredits(reservation, store: store)
    if rejected?.canRefund(beforeAccepted: true) == true { held.refund() }
    checkEqual(store.spentToday(), 0, "retry validation rejection refunds the existing local reservation")

    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, queued) : .http(200, sampleDoneJobFor("job-1")) }
    run.beforeSubmit = { throw SkyStudioJobError.notSubmitted("The original quote expired before submission.") }
    let expired = await jobFailure { _ = try await run.run(request) }
    check(expired?.message.contains("quote expired") == true && SkyStudioStub.log.isEmpty, "first preflight rejection sends zero HTTP and preserves reason")

    // 取消恰在异步核对返回前到达：不能仅依赖 while 顶部那次检查。
    run.beforeSubmit = { await Task.yield(); withUnsafeCurrentTask { $0?.cancel() } }
    let cancelled = Task { await jobFailure { _ = try await run.run(request) } }
    let cancelledError = await cancelled.value
    checkEqual(cancelledError?.rejectedBeforeAdmissionCode, "local_not_sent", "cancellation during pre-submit await remains definite non-admission")
    check(SkyStudioStub.log.isEmpty, "cancellation during pre-submit await sends zero HTTP")

    SkyStudioStub.reset { _ in .http(429, full) }
    run.beforeSubmit = {}
    run.sleep = SleepLog(throwOnCall: 1).sleep
    let waitingCancel = await jobFailure { _ = try await run.run(request) }
    checkEqual(waitingCancel?.rejectedBeforeAdmissionCode, "local_not_sent", "cancelled capacity wait persists definite non-admission")
    checkEqual(SkyStudioStub.log.count, 1, "cancelled slot wait never resubmits")
    await runAmbiguousAdmissionChecks(request)
    await runOriginalJobIdentityChecks(request)
}

private func runAmbiguousAdmissionChecks(_ request: SkyStudioJobRequest) async {
    let queued = #"{"job_id":"job-1","status":"queued"}"#
    var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
    run.sleep = SleepLog().sleep
    run.beforeSubmit = {}
    SkyStudioStub.reset { seen in
        seen.method == "POST" ? .http(429, #"{"error":{"code":"too_many_jobs","message":"Known original","job_id":"job-1"}}"#)
            : .http(200, sampleDoneJobFor("job-1"))
    }
    checkEqual(try? await run.run(request).state, .done, "known original id takes precedence over capacity code")
    checkEqual(SkyStudioStub.log.map(\.method), ["POST", "GET"], "capacity response with original id only GETs that operation")

    for fields: [String: JSONValue] in [["charged": true], ["refunded": true], ["billing": ["status": "charged", "credits_charged": 8]],
                                      ["provider_outcome": "succeeded"], ["generation_id": "existing"], ["unknown_admission": true], ["running": 1.5]] {
        var details = fields
        details["code"] = "too_many_jobs"; details["message"] = "Conflicting evidence"
        let body = JSONValue.object(["error": .object(details)]).encodedString()
        let posts = NameLog()
        SkyStudioStub.reset { seen in
            if seen.method == "POST" { posts.add("post"); return posts.items.count == 1 ? .http(429, body) : .http(202, queued) }
            return .http(200, sampleDoneJobFor("job-1"))
        }
        let failure = await jobFailure { _ = try await run.run(request) }
        checkEqual(SkyStudioStub.log.map(\.method), ["POST"], "ambiguous capacity response never retries: \(fields.keys.sorted())")
        check(failure?.canRefund(beforeAccepted: true) == false && failure?.rejectedBeforeAdmissionCode == nil,
              "ambiguous capacity code cannot invent refund or non-admission")
    }
    let returned = SkyStudioJobError.request(.server(.init(status: 503, code: "recipe_unavailable", message: "Net refunded",
        fields: ["billing": ["status": "refunded", "credits_charged": 0, "credits_refunded": 8]])))
    check(returned.canRefund(beforeAccepted: true), "explicit full refund still releases local reservation")
    check(returned.rejectedBeforeAdmissionCode == nil, "returnedAll proves net zero, not absence of prior admission")
    for code in SkyStudioJobAdmission.rejectedCodes {
        let charged = SkyStudioJobError.request(.server(.init(status: 503, code: code, message: "Charged", fields: ["charged": true])))
        check(!charged.canRefund(beforeAccepted: true) && charged.rejectedBeforeAdmissionCode == nil, "\(code) cannot override charged evidence")
    }
}

private func runOriginalJobIdentityChecks(_ request: SkyStudioJobRequest) async {
    for path in ["resume", "poll", "submit_error"] {
        let updates = UpdateLog()
        SkyStudioStub.reset { seen in
            if seen.method == "POST" {
                return path == "poll" ? .http(202, #"{"job_id":"job-1","status":"queued"}"#)
                    : .http(502, #"{"error":{"code":"provider_error","message":"Known operation","job_id":"job-1"}}"#)
            }
            return .http(200, sampleDoneJobFor("different-job").replacingOccurrences(of: "\"credits_charged\": 455",
                with: "\"billing\": {\"status\":\"charged\",\"credits_charged\":455}, \"credits_charged\":455"))
        }
        var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
        run.sleep = SleepLog().sleep
        do {
            if path == "resume" { _ = try await run.resume("job-1") { updates.add($0) } }
            else { _ = try await run.run(request) { updates.add($0) } }
            check(false, "wrong GET job identity must reject on \(path)")
        } catch { check(true, "wrong GET identity rejected on \(path)") }
        let reported = updates.items.compactMap { update -> SkyStudioJobStatus? in
            if case .status(let value) = update { return value }; return nil
        }
        checkEqual(reported.map(\.jobID), path == "resume" ? [] : ["job-1"], "wrong GET cannot replace original identity before checkpoint")
        check(reported.allSatisfy { $0.billing?.netCharged == nil }, "wrong GET cannot settle the original with another operation's billing")
        checkEqual(SkyStudioStub.log.map(\.method), path == "resume" ? ["GET"] : ["POST", "GET"], "wrong GET never causes paid replay")
    }
}
