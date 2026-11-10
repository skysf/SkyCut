import Foundation
import SrtFlowMCPKit

// 声音库的两个工具（声音 PR 6，SkyCut 声音方案 4.5、4.6、9.1 第 9 项）里的纯值和把关：
// - list_voices 列什么：一种语言 listed 的预设（默认的标出来、按这种语言报性别和说明）、没有自己名单的语言照英文那份并说明；
// - 令牌绑完整身份：授权（文件、内容哈希、那一段、语言、名字 / 声音、版本、账户）、一次性费用（kind、模型、声音、语言、精确积分）、设计、删除，
//   换一样 action 就不一样，都以 `skystudio:` 开头（换账户一起作废）；
// - SkyStudioJobGate 的三件事：授权和一次性费用两种模式都问（长期授权是声音 PR 7）、一次性费用先判每日硬预算、点过头才记账；
//   删除请求批准模式问、全部权限直接删；
// - 错误码换成能照做的话：声音库用不了（不退本机、预设照常）、删除时存储一时不可用（再发一次）、满了、语言已有录音、人声不够。

@MainActor
func runVoiceLibraryToolChecks() {
    listingChecks()
    approvalIdentityChecks()
    gateChecks()
    errorChecks()
    checkEqual(SkyStudioVoicePick.ask("voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"), .library("voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"),
               "a voice_… id is a library voice")
    checkEqual(SkyStudioVoicePick.ask("voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d")?.kind, SkyStudioVoiceKind.clone, "library voices read as voice_clone")
    checkEqual(SkyStudioVoicePick.ask("voice_nothex"), .name("voice_nothex"), "a malformed id is not a library voice")
    checkEqual(SkyStudioVoicePick.ask("gemini:Charon")?.kind, SkyStudioVoiceKind.narration, "presets read as narration")
}

private func listingChecks() {
    guard let catalog = voiceCatalogFixture() else { return check(false, "the voice catalog fixture reads") }
    let zh = SkyStudioVoiceListing.presets(catalog, language: "zh")
    let voices = zh["voices"]?.arrayValue ?? []
    check(!voices.isEmpty && zh["list_language"] == nil, "Chinese has its own preset list")
    checkEqual(voices.filter { $0["default"] == true }.compactMap { $0["id"]?.stringValue }, ["gemini:Charon"], "only the default preset is marked")
    check(voices.allSatisfy { $0["id"]?.stringValue?.hasPrefix("gemini:") == true && $0["description"]?.stringValue != nil },
          "every preset has its id and an English description")
    checkEqual(voices.count, catalog.listed(language: "zh").count, "the list is the language's listed presets")
    let ja = SkyStudioVoiceListing.presets(catalog, language: "ja")
    checkEqual(ja["list_language"], "en", "a language without its own list uses the English one")
    check(ja["note"]?.stringValue?.contains("Japanese") == true, "and says so")
    let gacrux = { (language: String) in
        SkyStudioVoiceListing.presets(catalog, language: language)["voices"]?.arrayValue?.first { $0["id"] == "gemini:Gacrux" }?["gender"]
    }
    if gacrux("zh") != nil, gacrux("en") != nil {
        check(gacrux("zh") != gacrux("en"), "a preset's gender is reported for the language asked (Gacrux differs between zh and en)")
    }
}

private func approvalIdentityChecks() {
    let base = SkyStudioVoiceApproval.Recording(
        path: "/Users/u/a.m4a", bytes: 1_000, modified: 10, sampleSHA256: "abc", start: 0, end: 30, language: "zh",
        target: "create:Sky", statementVersion: "voice-consent-v1"
    )
    let action = SkyStudioVoiceApproval.consentAction(base, account: "1:aa")
    check(action.hasPrefix("skystudio:voice_consent:1:aa:"), "consent actions are account-bound skystudio actions")
    let variants: [(String, (inout SkyStudioVoiceApproval.Recording) -> Void)] = [
        ("path", { $0.path = "/Users/u/b.m4a" }), ("size", { $0.bytes = 1_001 }), ("modification time", { $0.modified = 11 }),
        ("content", { $0.sampleSHA256 = "abd" }), ("start", { $0.start = 1 }), ("end", { $0.end = 31 }), ("language", { $0.language = "en" }),
        ("name", { $0.target = "create:Sky2" }), ("statement version", { $0.statementVersion = "voice-consent-v2" })
    ]
    for (what, change) in variants {
        var other = base
        change(&other)
        check(SkyStudioVoiceApproval.consentAction(other, account: "1:aa") != action, "another \(what) needs another consent")
    }
    check(SkyStudioVoiceApproval.consentAction(base, account: "1:bb") != action, "another account needs another consent")
    guard let item = SkyStudioVoiceOneTime(json: ["kind": "voice_enroll", "model": "minimax-voice-clone", "voice": "voice_x", "language": "en",
                                                   "credits": 377.6]) else { return check(false, "one-time item reads") }
    let fee = SkyStudioVoiceApproval.oneTimeAction(item, account: "1:aa")
    for (what, json) in [("price", ["credits": 377.7]), ("language", ["language": "es"]), ("voice", ["voice": "voice_y"]), ("model", ["model": "other"])] as [(String, JSONValue)] {
        var value = item.json.objectValue ?? [:]
        for (key, entry) in json.objectValue ?? [:] { value[key] = entry }
        let changed = SkyStudioVoiceOneTime(json: .object(value)).map { SkyStudioVoiceApproval.oneTimeAction($0, account: "1:aa") }
        check(changed != nil && changed != fee, "a one-time fee with another \(what) needs another approval")
    }
    let design = SkyStudioVoiceApproval.designAction(description: "calm", name: "Calm", sampleText: nil, credits: 22.5, account: "1:aa")
    check(SkyStudioVoiceApproval.designAction(description: "calm!", name: "Calm", sampleText: nil, credits: 22.5, account: "1:aa") != design
          && SkyStudioVoiceApproval.designAction(description: "calm", name: "Calm", sampleText: "Hi.", credits: 22.5, account: "1:aa") != design
          && SkyStudioVoiceApproval.designAction(description: "calm", name: "Calm", sampleText: nil, credits: 22.6, account: "1:aa") != design,
          "a design with another description, sample or price needs another approval")
    check(design.hasPrefix("skystudio:") && fee.hasPrefix("skystudio:")
          && SkyStudioVoiceApproval.deletionAction(voice: "voice_x", account: "1:aa").hasPrefix("skystudio:voice_delete:1:aa:"),
          "every voice approval is a skystudio action (discarded when the account changes)")
    checkEqual(SkyStudioVoiceApproval.idempotencyKey(for: action), SkyStudioVoiceApproval.idempotencyKey(for: action), "the same consent gives the same key")
    checkEqual(SkyStudioVoiceApproval.idempotencyKey(for: action).count, 32, "keys are 32 hex digits")
    let question = SkyStudioVoiceApproval.oneTimeQuestion(item, credits: 377.6, noFeeModel: "index-tts-2")
    check(question.contains("377.6") && question.contains("index-tts-2") && question.contains("English"), "the fee question names the price, language and the no-fee option")
}

@MainActor
private func gateChecks() {
    let suite = "com.srtflow.voice-gate-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let access = AIAccessStore(defaults: defaults)
    let spend = SkyStudioSpendStore(defaults: defaults)

    // 授权（照 SkyStudioJobGate.VoiceAsk，SkyStudioVoiceStanding 读出来的）：请求批准模式（.ask）和全部权限但还没有长期授权（.once）都问，
    // 同一件事等答复时回同一张、收了一次就作废、别的录音拿不走；.once 的问句后面接那段说明、令牌另绑（请求批准模式发的码答不了它）；
    // 全部权限 + 有效的长期授权（.standing）不问（声音 PR 7）。
    let once = SkyStudioJobGate.VoiceAsk.once(explanation: "FULL-ACCESS-EXPLANATION", statementVersion: "voice-standing-consent-v1")
    for (name, ask) in [("ask", SkyStudioJobGate.VoiceAsk.ask), ("once", once)] {
        let action = "skystudio:voice_consent:test:\(name)"
        let asked = SkyStudioJobGate.voiceConsent(action: action, question: "q", token: nil, ask: ask)
        let token = asked?.payload["confirm_token"]?.stringValue
        check(token != nil, "\(name): asks for recording consent")
        check((asked?.payload["question"]?.stringValue?.contains("FULL-ACCESS-EXPLANATION") == true) == (name == "once"),
              "\(name): only the full-access question carries the explanation")
        checkEqual(SkyStudioJobGate.voiceConsent(action: action, question: "q", token: nil, ask: ask)?.payload["confirm_token"]?.stringValue, token,
                   "\(name): asking again before the answer returns the same code")
        check(SkyStudioJobGate.voiceConsent(action: action + ":other", question: "q", token: token, ask: ask)?.payload["confirm_token_refused"] != nil,
              "\(name): another recording cannot use this consent")
        check(SkyStudioJobGate.voiceConsent(action: action, question: "q", token: token, ask: ask) == nil, "\(name): the consent is accepted once")
        check(SkyStudioJobGate.voiceConsent(action: action, question: "q", token: token, ask: ask)?.payload["confirm_token_refused"] != nil,
              "\(name): and only once")
    }
    let askToken = SkyStudioJobGate.voiceConsent(action: "skystudio:voice_consent:cross", question: "q", token: nil, ask: .ask)?
        .payload["confirm_token"]?.stringValue
    check(SkyStudioJobGate.voiceConsent(action: "skystudio:voice_consent:cross", question: "q", token: askToken, ask: once)?
            .payload["confirm_token_refused"] != nil, "a code asked in ask mode cannot answer the full-access question")
    check(SkyStudioJobGate.voiceConsent(action: "skystudio:voice_consent:standing", question: "q", token: nil, ask: .standing) == nil,
          "full access with the standing consent on record does not ask")

    // 一次性费用：每日硬预算先判（不发码、不记账），三种一样；问到了才记账；全部权限 + 长期授权不问、直接按报价记账。
    spend.setDailyLimit(100)
    for (name, ask) in [("ask", SkyStudioJobGate.VoiceAsk.ask), ("standing", .standing), ("once", once)] {
        let before = spend.spentToday()
        let blocked = try? SkyStudioJobGate.voiceOneTime(credits: 377.6, action: "skystudio:fee:\(name)", question: "q", token: nil, ask: ask,
                                                         store: spend)
        if case .needsConfirmation(let result)? = blocked {
            check(result.payload["code"] == "daily_budget_exceeded" && result.payload["confirm_token"] == nil && spend.spentToday() == before,
                  "\(name): over the daily limit nothing is asked or reserved")
        } else { check(false, "\(name): an over-budget fee must be blocked") }
    }
    spend.setDailyLimit(1_000)
    let before = spend.spentToday()
    let first = try? SkyStudioJobGate.voiceOneTime(credits: 22.5, action: "skystudio:fee:design", question: "q", token: nil, ask: .ask, store: spend)
    guard case .needsConfirmation(let asked)? = first, let token = asked.payload["confirm_token"]?.stringValue else {
        return check(false, "a one-time fee within the budget is asked first")
    }
    checkEqual(spend.spentToday(), before, "asking reserves nothing")
    if case .reserved(let reservation)? = try? SkyStudioJobGate.voiceOneTime(credits: 22.5, action: "skystudio:fee:design", question: "q",
                                                                               token: token, ask: .ask, store: spend) {
        checkEqual(reservation.credits, 22.5, "the approved fee is reserved at its quoted price")
        checkEqual(spend.spentToday(), before + 22.5, "and recorded against the daily limit")
    } else { check(false, "the approved fee is reserved") }
    if case .reserved(let reservation)? = try? SkyStudioJobGate.voiceOneTime(credits: 377.6, action: "skystudio:fee:standing", question: "q",
                                                                               token: nil, ask: .standing, store: spend) {
        checkEqual(reservation.credits, 377.6, "full access with the standing consent reserves the quoted fee without asking")
        checkEqual(spend.spentToday(), before + 22.5 + 377.6, "and records it against the daily limit")
    } else { check(false, "full access with the standing consent does not ask about a fee") }
    let onceFee = try? SkyStudioJobGate.voiceOneTime(credits: 22.5, action: "skystudio:fee:once", question: "q", token: nil, ask: once, store: spend)
    if case .needsConfirmation(let result)? = onceFee, let onceToken = result.payload["confirm_token"]?.stringValue {
        check(result.payload["question"]?.stringValue?.contains("FULL-ACCESS-EXPLANATION") == true,
              "full access without a standing consent asks once, with the explanation")
        if case .reserved? = try? SkyStudioJobGate.voiceOneTime(credits: 22.5, action: "skystudio:fee:once", question: "q", token: onceToken,
                                                               ask: once, store: spend) {
            check(true, "and the answered question reserves the fee")
        } else { check(false, "and the answered question reserves the fee") }
    } else { check(false, "full access without a standing consent asks once") }

    // 删除：请求批准模式问一句，全部权限直接删。
    access.setMode(.ask)
    let deletion = SkyStudioJobGate.voiceDeletion(action: "skystudio:voice_delete:test", question: "q", token: nil, access: access)
    check(deletion?.payload["confirm_token"] != nil, "ask mode asks before deleting a voice")
    access.setMode(.full)
    check(SkyStudioJobGate.voiceDeletion(action: "skystudio:voice_delete:test2", question: "q", token: nil, access: access) == nil,
          "full access deletes without asking")
}

private func errorChecks() {
    func server(_ status: Int, _ code: String, _ fields: [String: JSONValue] = [:]) -> SkyStudioFailure {
        .server(SkyStudioServerError(status: status, code: code, message: "server words", fields: fields))
    }
    let missingBucket = server(503, "voice_library_unavailable", ["reason": "not_configured"])
    check(SkyStudioVoiceLibraryErrors.isUnavailable(missingBucket) && !SkyStudioVoiceLibraryErrors.isStorageRetry(missingBucket),
          "a missing voice bucket is the library being unavailable")
    let message = SkyStudioVoiceLibraryErrors.message(missingBucket)
    check(message.contains("not available right now") && message.contains("nothing was charged") && message.contains("gemini:"),
          "it says the library is unavailable, nothing was charged and presets still work")
    let storage = server(503, "voice_library_unavailable", ["reason": "storage_unavailable", "retryable": true])
    check(SkyStudioVoiceLibraryErrors.isStorageRetry(storage) && !SkyStudioVoiceLibraryErrors.isUnavailable(storage),
          "a storage failure while deleting is a retry, not an outage")
    check(SkyStudioVoiceLibraryErrors.message(storage).contains("delete again"), "and says to call delete again")
    check(SkyStudioVoiceLibraryErrors.message(server(409, "voice_limit", ["limit": 50])).contains("at most 50 voices"), "voice_limit says the cap")
    check(SkyStudioVoiceLibraryErrors.message(server(409, "reference_exists", ["language": "zh"])).contains("Chinese"), "reference_exists names the language")
    check(SkyStudioVoiceLibraryErrors.message(server(400, "invalid_request", ["reason": "too_little_speech", "limit": 10])).contains("10 seconds"),
          "too_little_speech says how much speech is needed")
    check(SkyStudioVoiceLibraryErrors.isNotFound(server(404, "not_found")), "not_found is recognised (a voice being deleted is no longer listed)")
    checkEqual(SkyStudioVoiceLibraryErrors.uncharged(SkyStudioFailure.network("offline")), "Could not reach Sky Studio: offline Nothing was charged.",
               "a failure before paying says nothing was charged")
}

private func voiceCatalogFixture() -> SkyStudioVoiceCatalog? {
    let data = FileManager.default.contents(atPath: "checks/SkyStudio/Fixtures/models-voice-2026-11-10.json") ?? Data()
    return (try? JSONValue.decode(data)).flatMap(SkyStudioVoiceCatalog.init(json:))
}
