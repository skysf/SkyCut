import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// A voice change's books follow Sky Studio's final bill only (Codex CXM3, 2026-11-26; VoiceChangeBilling), with real App objects
// against the fake Sky Studio:
// - a 402 while following an accepted change may come with a charge: the AI queries that job, never "not charged" or a redo;
// - get_job on the original job answering 402 with a final bill of 6.5 settles the books at 6.5 (a try? dropped it: 9 stayed);
// - without a final bill a top-level credits_charged of 0 is neither settled nor reported as the charge;
// - a default change whose result lacks its background keeps the 9 reserved until a final bill comes;
// - get_job's spent_today_credits after a 402 with a final bill is read from the books after settling (Codex CXM4: 9, not 6.5).
// docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md

@MainActor
func voiceChangeSettleChecks(_ root: URL) async throws {
    try await polledRefusalChecks(root)
    try await refusalBillChecks(root)
    try await noFinalBillChecks(root)
    try await missingBackgroundChecks(root)
    try await refusalBillReplyChecks(root)
}

@MainActor
private func refusalBillReplyChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-no-background-402-bill"))
    let clip = fixture.placeClip(try fixture.stereoSource())
    let books = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.omitBackground = true; VoiceChangeHTTP.unbilled = true }
    let failed = try await change(fixture, clip)
    let before = failed["spent_today_credits"]?.doubleValue ?? -1
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.originalJobErrors["convert-1"] = (402, ["error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2."],
                                                                "billing": ["status": "charged", "credits_charged": 6.5]])
    }
    guard let id = failed["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { return require(false, "the failed change has a job") }
    await job.refresh?()
    let asked = AIJobs.shared.json(job)
    let ledger = SkyStudioCredits.number(SkyStudioSpendStore.shared.spentToday())
    require(abs(held(since: books) - 6.5) < 0.0001 && asked["spent_today_credits"]?.doubleValue == ledger && abs(before - ledger - 2.5) < 0.0001,
            "after a 402 with a final bill of 6.5, get_job's spent_today_credits is the books' \(ledger), not \(before) from before settling: \(asked)")
    dismissFailedRows()
}

@MainActor
private func change(_ fixture: VoiceChangeFixture, _ clip: UUID) async throws -> JSONValue {
    try await fixture.wait(try await fixture.change(["clip_id": .string(fixture.short(clip)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
}

@MainActor
private func held(since books: Double) -> Double { SkyStudioSpendStore.shared.spentToday() - books }

@MainActor
private func dismissFailedRows() {
    for row in SkyStudioGenerationActivity.shared.runs where row.issue != nil { SkyStudioGenerationActivity.shared.dismiss(row) }
}

@MainActor
private func polledRefusalChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-polled-402"))
    let clip = fixture.placeClip(try fixture.stereoSource())
    let books = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.holdJob = true
        VoiceChangeHTTP.pollRefusal = (402, ["error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2.", "balance": 2, "needed": 9]])
    }
    let polled = try await change(fixture, clip)
    let next = polled["next_step"]?.stringValue ?? ""
    require(polled["status"] == "failed" && polled["blocked_by"] == "sky_studio_balance" && next.contains("Query this original job with get_job")
            && !next.contains("not charged") && !next.contains("call change_voice again"),
            "a 402 while following an accepted change may have been charged: the AI queries that job, never a redo: \(polled)")
    require(abs(held(since: books) - 9) < 0.0001 && VoiceChangeHTTP.calls("POST", "/jobs").count == 1,
            "and the 9 reserved stay on the books, sent once (\(held(since: books)))")
    dismissFailedRows()
}

@MainActor
private func refusalBillChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-402-final-bill"))
    let clip = fixture.placeClip(try fixture.stereoSource())
    let books = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.submitRefusal = (402, ["error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2.",
                                                         "job_id": "convert-billed", "billing": ["status": "pending_review"]]])
    }
    let pending = try await change(fixture, clip)
    require(abs(held(since: books) - 9) < 0.0001, "a refusal that may have been charged keeps the 9 reserved")
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.originalJobErrors["convert-billed"] = (402, ["error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2."],
                                                                    "billing": ["status": "charged", "credits_charged": 6.5]])
    }
    guard let id = pending["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { return require(false, "the refused change has a job") }
    await job.refresh?()
    let asked = AIJobs.shared.json(job)
    require(abs(held(since: books) - 6.5) < 0.0001,
            "get_job on the original job answering 402 with a final bill of 6.5 settles the books at 6.5 (\(held(since: books)))")
    require(asked["credits_charged"] == 6.5 && asked["billing"]?["status"] == "charged" && VoiceChangeHTTP.calls("POST", "/jobs").count == 1,
            "and reports that bill, never submitting again: \(asked)")
    dismissFailedRows()
}

@MainActor
private func noFinalBillChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-unbilled"))
    let clip = fixture.placeClip(try fixture.stereoSource())
    let books = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.unbilled = true }
    let done = try await change(fixture, clip)
    require(done["status"] == "done" && abs(held(since: books) - 9) < 0.0001,
            "a done change whose answer has no final bill keeps the 9 reserved, top-level credits_charged 0 or not (\(held(since: books))): \(done)")
    require(done["credits_charged"] == nil && done["billing_note"] != nil, "and does not report that 0 as the charge: \(done)")

    let refused = try VoiceChangeFixture(folder: root.appendingPathComponent("change-unbilled-original"))
    let other = refused.placeClip(try refused.stereoSource())
    let before = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.submitRefusal = (402, ["error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2.",
                                                         "job_id": "convert-unbilled", "billing": ["status": "pending_review"]]])
        VoiceChangeHTTP.originalJobs["convert-unbilled"] = ["job_id": "convert-unbilled", "kind": "voice_convert", "status": "failed",
                                                             "credits_charged": 0, "error": ["code": "insufficient_credits", "message": "Not enough credits."]]
    }
    let failed = try await change(refused, other)
    guard let id = failed["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { return require(false, "the refused change has a job") }
    await job.refresh?()
    let asked = AIJobs.shared.json(job)
    require(asked["credits_charged"] == nil && asked["billing_note"] != nil && abs(held(since: before) - 9) < 0.0001,
            "get_job on an original job without a final bill neither reports nor settles its top-level credits_charged 0 (\(held(since: before))): \(asked)")
    dismissFailedRows()
}

@MainActor
private func missingBackgroundChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-no-background-unbilled"))
    let clip = fixture.placeClip(try fixture.stereoSource())
    let books = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.omitBackground = true; VoiceChangeHTTP.unbilled = true }
    let failed = try await change(fixture, clip)
    require(failed["status"] == "failed" && failed["message"]?.stringValue?.contains("background") == true && abs(held(since: books) - 9) < 0.0001,
            "a default result without its background keeps the 9 reserved while no final bill came (\(held(since: books))): \(failed)")
    // The final bill comes later: get_job asks the job again and the books follow it.
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.unbilled = false }
    guard let id = failed["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { return require(false, "the failed change has a job") }
    await job.refresh?()
    require(abs(held(since: books) - 7.5) < 0.0001, "and its final bill (7.5) settles them when get_job asks (\(held(since: books)))")
    dismissFailedRows()
}
