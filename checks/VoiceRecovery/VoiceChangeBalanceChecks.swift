import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// change_voice refused by Sky Studio for the balance (MSG1, 2026-11-24; SkyStudioBalanceRefusal), with real App objects against
// the fake Sky Studio: the AI hears it is the user's Sky Studio account, not SkyCut's daily limit, with the numbers, the recharge
// address and its own retry; the task row says it in the app's language; nothing is charged or sent again.
// docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md

@MainActor
func voiceChangeBalanceChecks(_ root: URL) async throws {
    let short = try VoiceChangeFixture(folder: root.appendingPathComponent("change-balance"))
    let poor = short.placeClip(try short.stereoSource())
    let ledger = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.submitRefusal = (402, ["error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2.",
                                                         "balance": 2, "needed": 9, "recharge_url": "https://skystudioai.com/app?credits=1"]])
    }
    let refused = try await short.wait(try await short.change(["clip_id": .string(short.short(poor)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
    let next = refused["next_step"]?.stringValue ?? ""
    require(refused["status"] == "failed" && refused["blocked_by"] == "sky_studio_balance" && refused["balance_credits"] == 2
            && refused["needed_credits"] == 9 && refused["recharge_url"] == "https://skystudioai.com/app?credits=1"
            && next.contains("not SkyCut's daily limit") && next.contains("call change_voice again"),
            "a balance refusal names the Sky Studio account, the numbers, recharge_url and the retry: \(refused)")
    require(abs(SkyStudioSpendStore.shared.spentToday() - ledger) < 0.0001 && VoiceChangeHTTP.calls("POST", "/jobs").count == 1,
            "a balance refusal gives the reservation back and is not sent again")
    let poorRow = SkyStudioGenerationActivity.shared.runs.first { $0.issue?.contains("Not enough Sky Studio credits: your balance is 2 and this needs 9") == true }
    require(poorRow != nil, "the row shows the user's line, not Sky Studio's English: \(SkyStudioGenerationActivity.shared.runs.map { $0.issue ?? "" })")
    for row in SkyStudioGenerationActivity.shared.runs where row.issue != nil { SkyStudioGenerationActivity.shared.dismiss(row) }

    // A 402 that carries a job id and pending billing may have been charged (MSG1 review): the reservation stays on the books and
    // the AI queries that job instead of being told "not charged" and to change the voice again.
    let billed = try VoiceChangeFixture(folder: root.appendingPathComponent("change-balance-billed"))
    let clip = billed.placeClip(try billed.stereoSource())
    let books = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.submitRefusal = (402, ["error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2.",
                                                         "balance": 2, "needed": 9, "job_id": "convert-402", "billing": ["status": "pending_review"]]])
    }
    let pending = try await billed.wait(try await billed.change(["clip_id": .string(billed.short(clip)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
    let pendingNext = pending["next_step"]?.stringValue ?? ""
    require(pending["status"] == "failed" && pendingNext.contains("Query this original job with get_job") && !pendingNext.contains("not charged")
            && !pendingNext.contains("call change_voice again"),
            "a possibly billed balance refusal sends the AI to the original job, never to a redo: \(pending)")
    require(abs(SkyStudioSpendStore.shared.spentToday() - books - 9) < 0.0001, "and its reservation stays on the books")
    // get_job asks that original job (GET only) and settles the books by its billing (MSG1 review): Sky Studio refunded it.
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.originalJobs["convert-402"] = ["job_id": "convert-402", "kind": "voice_convert", "status": "failed",
            "error": ["code": "insufficient_credits", "message": "You need 9 credits; you have 2."],
            "billing": ["status": "refunded", "credits_charged": 0, "credits_refunded": 9]]
    }
    if let id = pending["job_id"]?.stringValue, let job = AIJobs.shared.job(id) {
        let gets = VoiceChangeHTTP.calls("GET", "/jobs/convert-402").count
        await job.refresh?()
        let asked = AIJobs.shared.json(job)
        require(VoiceChangeHTTP.calls("GET", "/jobs/convert-402").count == gets + 1 && VoiceChangeHTTP.calls("POST", "/jobs").count == 1
                && asked["skystudio_status"] == "failed" && asked["billing"]?["status"] == "refunded",
                "get_job asks the original job once and reports its billing, never submitting again (GET \(VoiceChangeHTTP.calls("GET", "/jobs/convert-402").count), POST \(VoiceChangeHTTP.calls("POST", "/jobs").count)): \(asked)")
        require(abs(SkyStudioSpendStore.shared.spentToday() - books) < 0.0001, "and the refunded reservation leaves the books")
    } else { require(false, "the billed change has a job") }
    for row in SkyStudioGenerationActivity.shared.runs where row.issue != nil { SkyStudioGenerationActivity.shared.dismiss(row) }
    try await voiceChangeSettleChecks(root)
}
