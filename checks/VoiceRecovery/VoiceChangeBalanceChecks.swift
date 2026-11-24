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
}
