import Foundation
import SrtFlowMCPKit

// When Sky Studio refuses a job for the balance (MSG1, 2026-11-24; SkyStudioBalanceRefusal): the AI is told it is the user's Sky
// Studio account, not SkyCut's daily limit, with the numbers Sky Studio sent, where only the user can add credits and how to retry
// once they have; a refusal that carries a job id or billing may have been charged, so the AI queries that job and never resubmits
// (MSG1 review, 2026-11-25). The user's line says the same in every string table. The jobs that use it are pinned by
// checks/sky-studio-wiring/daily-limit.sh. docs/bugfixes/2026-11-24-daily-limit-refusal-unclear.md

func runBalanceRefusalChecks() {
    let refusal = SkyStudioServerError(status: 402, code: "insufficient_credits", message: "You need 455 credits; you have 30.",
                                       fields: ["balance": 30, "needed": 455, "recharge_url": "https://skystudioai.com/app?credits=1"])
    let found = SkyStudioBalanceRefusal.refusal(of: SkyStudioJobError.request(.server(refusal)), accepted: false)
    checkEqual(found?.failure.balance, 30, "the refusal inside a request error, with Sky Studio's balance")
    checkEqual(found?.failure.needed, 455, "and what the request needs")
    checkEqual(found?.beforeAdmission, true, "a plain 402 was refused before Sky Studio accepted anything")
    let ended = SkyStudioBalanceRefusal.refusal(of: SkyStudioJobError.failed(SkyStudioJobFailure(message: "short", fields: ["code": "insufficient_credits"])),
                                                accepted: false)
    checkEqual(ended?.beforeAdmission, false, "a job that ended for the balance counts, as accepted")
    let other = SkyStudioServerError(status: 409, code: "price_changed", message: "Price changed.", fields: ["credits": 20])
    check(SkyStudioBalanceRefusal.refusal(of: SkyStudioJobError.request(.server(other)), accepted: false) == nil, "other refusals are not the balance")
    check(SkyStudioBalanceRefusal.refusal(of: CancellationError(), accepted: false) == nil, "nor are errors that are not Sky Studio's")
    // A balance error while polling a job Sky Studio already accepted carries no billing, yet the job may have been charged.
    checkEqual(SkyStudioBalanceRefusal.refusal(of: SkyStudioJobError.request(.server(refusal)), accepted: true)?.beforeAdmission, false,
               "a balance error for an accepted job is not before admission")

    guard let found else { return }
    let account = URL(string: "https://skystudioai.com/app?account=1")
    let fields = JSONValue.object(SkyStudioBalanceRefusal.fields(found, recharge: account, retry: "call upscale_clip again"))
    checkEqual(fields["blocked_by"], "sky_studio_balance", "which system stopped it: the user's Sky Studio account")
    checkEqual(fields["recharge_url"], "https://skystudioai.com/app?credits=1", "Sky Studio's own recharge address first")
    checkEqual(fields["balance_credits"], 30, "the balance")
    checkEqual(fields["needed_credits"], 455, "what this needs")
    let next = fields["next_step"]?.stringValue ?? ""
    for phrase in ["Sky Studio credit balance is too low (balance 30, this needs 455)", "not SkyCut's daily limit", "was not charged",
                   "Only they can add credits, at recharge_url (or SkyCut → Settings → Sky Studio → Add Credits)",
                   "once they say they have added credits: call upscale_clip again", "Do not retry or ask for approval before that"] {
        check(next.contains(phrase), "the balance's next step says \"\(phrase)\": \(next)")
    }
    let bare = SkyStudioBalanceRefusal.Refusal(failure: SkyStudioJobFailure(message: "Not enough credits.", fields: ["code": "insufficient_credits"]),
                                               beforeAdmission: true)
    let fallback = JSONValue.object(SkyStudioBalanceRefusal.fields(bare, recharge: account, retry: "call change_voice again"))
    checkEqual(fallback["recharge_url"], "https://skystudioai.com/app?account=1", "the account's address when the refusal carried none")
    check(fallback["balance_credits"] == nil && fallback["needed_credits"] == nil, "no numbers that Sky Studio did not send")
    check(fallback["next_step"]?.stringValue?.contains("too low. This is their Sky Studio account") == true, "and no empty brackets")
    let nowhere = JSONValue.object(SkyStudioBalanceRefusal.fields(bare, recharge: nil, retry: "call change_voice again"))
    checkEqual(nowhere["recharge_url"], .null, "no address at all")
    let nowhereNext = nowhere["next_step"]?.stringValue ?? ""
    check(nowhereNext.contains("Only they can add credits, in Sky Studio.") && !nowhereNext.contains("Add Credits"),
          "without an address the next step says Sky Studio and names no Add Credits link: \(nowhereNext)")

    // A 402 that carries a job id and pending billing may have been charged: query that job, never "not charged", never a redo.
    let billed = SkyStudioServerError(status: 402, code: "insufficient_credits", message: "You need 9 credits; you have 2.",
                                      fields: ["balance": 2, "needed": 9, "job_id": "job-402", "billing": ["status": "pending_review"]])
    if let pending = SkyStudioBalanceRefusal.refusal(of: SkyStudioJobError.request(.server(billed)), accepted: false) {
        checkEqual(pending.beforeAdmission, false, "a refusal with a job id and billing is not before admission")
        let next = JSONValue.object(SkyStudioBalanceRefusal.fields(pending, recharge: account, retry: "call change_voice again"))["next_step"]?.stringValue ?? ""
        check(next.contains("Query this original job with get_job") && next.contains("never submit it again") && !next.contains("not charged")
              && !next.contains("call change_voice again") && next.contains("not SkyCut's daily limit"),
              "a possibly billed refusal queries the original job and suggests no redo: \(next)")
    } else { check(false, "a 402 with a job id is still the balance") }
    balanceLineChecks(found, bare: bare)
    quoteRefusalChecks()
}

/// A refusal of the free price check names no order or bill: nothing was submitted (MSG1 review, 2026-11-25).
private func quoteRefusalChecks() {
    for (code, phrase) in [("upgrade_required", "newer SkyCut"), ("rate_limited", "after retry_after seconds"),
                           ("invalid_key", "paste a new key"), ("invalid_request", "this was only the price check")] {
        let error = SkyStudioFailure.server(SkyStudioServerError(status: 400, code: code, message: "Refused.", fields: [:]))
        let next = SkyStudioCharacterError.tool(error, beforeSubmission: true).details["next_step"]?.stringValue ?? ""
        check(next.contains("Nothing was submitted or charged") && next.contains(phrase) && !next.contains("billing") && !next.contains("original"),
              "a \(code) price check says nothing was submitted and what to do: \(next)")
    }
    let later = SkyStudioFailure.server(SkyStudioServerError(status: 429, code: "rate_limited", message: "Busy.", fields: [:]))
    check(SkyStudioCharacterError.tool(later).details["next_step"]?.stringValue?.contains("Inspect the original operation and billing") == true,
          "after a submission the original job is still where to look")
}

/// The user's line and its path, read from every real string table.
private func balanceLineChecks(_ failure: SkyStudioBalanceRefusal.Refusal, bare: SkyStudioBalanceRefusal.Refusal) {
    let full = "Not enough Sky Studio credits: your balance is %1$@ and this needs %2$@. This is your Sky Studio balance, not SkyCut's daily limit. Add credits in %3$@."
    let short = "Not enough Sky Studio credits. This is your Sky Studio balance, not SkyCut's daily limit. Add credits in %@."
    let paths = ["en": "SkyCut → Settings → Sky Studio → Add Credits", "zh-Hans": "SkyCut → 设置 → Sky Studio → 充值积分",
                 "es": "SkyCut → Ajustes → Sky Studio → Añadir créditos"]
    let folders = (try? FileManager.default.contentsOfDirectory(atPath: "Sources/SrtFlow/Resources"))?.filter { $0.hasSuffix(".lproj") } ?? []
    check(folders.count >= 3, "the string tables are found (\(folders.count))")
    for folder in folders.sorted() {
        let code = String(folder.dropLast(".lproj".count))
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "Sources/SrtFlow/Resources/\(folder)/Localizable.strings")),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            check(false, "\(folder): Localizable.strings reads as a strings table"); continue
        }
        for key in [full, short, "Settings", "Sky Studio", "Add Credits"] {
            check(table[key] != nil, "\(folder) translates \"\(key)\" (the balance's line and path)")
        }
        let lookup: (String) -> String = { table[$0] ?? $0 }
        if let want = paths[code] { checkEqual(SkyStudioBalanceRefusal.settingsPath(addCredits: true, lookup), want, "the Add Credits path in \(code)") }
        let pane = SkyStudioBalanceRefusal.settingsPath(addCredits: false, lookup)
        check(!pane.contains(lookup("Add Credits")), "\(code): without a recharge address the path stops at the pane")
        let shown = SkyStudioBalanceRefusal.userLine(failure, addCredits: true, localized: lookup)
        check(!shown.contains("%") && ["30", "455", SkyStudioBalanceRefusal.settingsPath(addCredits: true, lookup)].allSatisfy(shown.contains),
              "the balance's line in \(code) fills the numbers and the path: \(shown)")
        let shownBare = SkyStudioBalanceRefusal.userLine(bare, addCredits: false, localized: lookup)
        check(!shownBare.contains("%") && shownBare.contains(pane) && !shownBare.contains("455"),
              "without numbers the line in \(code) still names the account and the path: \(shownBare)")
    }
}
