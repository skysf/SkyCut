import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 全部权限下的长期授权（声音 PR 7，SkyCut 声音方案 4.5、5.6、9.1 第 9 项）走真 App 对象 + 假协议（VoiceLibraryHTTP / VoiceRecoveryHTTP）：
// - 全部权限 + 有效的长期授权：用录音建声音不问、带 consent: "standing_grant"、结果带 full_access、提示条说一句；设计直接起任务；
//   配旁白要建 MiniMax 版直接起 voice_enroll；中途备用要先建 MiniMax 版直接建（get_job 带 enroll_job_id）；每日硬预算照拦。
// - 全部权限、还没有长期授权：第一次照请求批准模式问一次（问句带那段说明），点过头先记长期授权、这一段录音带 consent: true 建；之后不再问。
// - 全部权限、GET 说有效但建的那一刻被拒（刚被别的 Mac 撤了）：照 4.5 问一次。
// - set_settings 打开全部权限：问句带说明（价目、长期授权那句）；点过头记问句里那一版、结果报 voice_standing_consent；关掉撤掉。
// - 升级前就开着全部权限：读到 Key 时替用户记上（这台 Mac 上一次），开着请求批准什么都不做，已经有有效的不再记，记不上下次再试。

@MainActor
func runVoiceStandingChecks(_ root: URL) async throws {
    let access = AIAccessStore.shared
    let mode = access.mode
    // 这一组花掉的（好几笔 MiniMax 版、设计）还回去：同一天的账跨组累计，后面的组（各自把额度设成 1,000）不该因为这一组被拦下。
    let spend = SkyStudioSpendStore.shared
    let spentBefore = spend.spentToday()
    defer {
        access.setMode(mode)
        let spentHere = spend.spentToday() - spentBefore
        if spentHere > 0 { spend.refund(spentHere, on: Date()) }
    }
    try await standingLibraryChecks(root)
    try await missingStandingChecks(root)
    try await refusedStandingChecks(root)
    try await standingNarrationChecks(root)
    try await standingFallbackChecks(root)
    try await settingsChecks(root)
    try await migrationChecks(root)
}

private let standingVersion = "voice-standing-consent-v1"

@MainActor
private func standingLibraryChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("standing-library"))
    AIAccessStore.shared.setMode(.full)
    VoiceLibraryHTTP.standing = (standingVersion, true)
    fixture.project.notice = nil
    let file = try fixture.recording()
    let created = try await fixture.manage(["action": "create", "file": .string(file.path), "name": "Sky Three", "language": "zh"])
    require(created.payload["status"] == "created" && created.payload["confirm_token"] == nil,
            "full access with the standing consent on record creates the voice without asking")
    let creation = VoiceLibraryHTTP.calls("POST", "/voices").first
    require(creation?["consent"] == "standing_grant" && creation?["consent_statement_version"] == nil,
            "and sends consent: \"standing_grant\" (no per-recording statement)")
    require(created.payload["consent"] == "standing_grant" && created.payload["full_access"]?.stringValue?.contains("did not ask") == true,
            "the result says it used the standing consent and did not ask")
    require(fixture.project.notice?.contains("Sky Three") == true, "and the project's notice bar says so too")

    let designed = try await fixture.manage(["action": "design", "description": "A calm narrator.", "name": "Calm"])
    require(designed.payload["status"] == "started" && designed.payload["confirm_token"] == nil
            && designed.payload["full_access"]?.stringValue?.contains("22.5") == true,
            "design starts without asking, and the result says what it costs at most")
    let done = try await fixture.wait(designed)
    require(done["status"] == "done", "the design job finishes")

    SkyStudioSpendStore.shared.setDailyLimit(0)
    defer { SkyStudioSpendStore.shared.setDailyLimit(100_000) }
    let jobs = VoiceLibraryHTTP.calls("POST", "/jobs").count
    let blocked = try await fixture.manage(["action": "design", "description": "Another narrator.", "name": "Other"])
    require(blocked.payload["code"] == "daily_budget_exceeded" && blocked.payload["confirm_token"] == nil
            && VoiceLibraryHTTP.calls("POST", "/jobs").count == jobs, "the daily limit still stops a one-time fee in full access")
}

@MainActor
private func missingStandingChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("standing-missing"))
    AIAccessStore.shared.setMode(.full)
    VoiceLibraryHTTP.standing = nil
    let file = try fixture.recording()
    let args: JSONValue = ["action": "create", "file": .string(file.path), "name": "Sky Four", "language": "en"]
    let asked = try await fixture.manage(args)
    let question = asked.payload["question"]?.stringValue ?? ""
    require(asked.payload["confirm_token"] != nil && question.contains("I am the person in this recording")
            && question.contains("no standing voice consent on record") && question.contains("For every recording I later use")
            && question.contains("377.6"),
            "full access without a standing consent asks once: this recording's statement plus the Full access explanation")
    require(VoiceLibraryHTTP.calls("POST", "/voices").isEmpty && VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").isEmpty,
            "nothing is recorded or created before the answer")
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = asked.payload["confirm_token"]
    let created = try await fixture.manage(.object(confirmed))
    require(created.payload["status"] == "created", "the answered question creates the voice")
    require(VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").first?["statement_version"] == .string(standingVersion),
            "agreeing records the standing consent, the version the question showed")
    require(VoiceLibraryHTTP.calls("POST", "/voices").last?["consent"] == true, "this recording goes with consent: true (the question asked for it)")

    guard let voice = created.payload["voice"]?["id"]?.stringValue else { return require(false, "the created voice has an id") }
    let second = try await fixture.manage(["action": "add_reference", "file": .string(file.path), "voice": .string(voice), "language": "zh"])
    require(second.payload["status"] == "reference_added" && second.payload["confirm_token"] == nil,
            "after that, full access does not ask again")
    require(VoiceLibraryHTTP.calls("POST", "/references").last?["consent"] == "standing_grant", "and uses the standing consent it recorded")
}

@MainActor
private func refusedStandingChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("standing-refused"))
    AIAccessStore.shared.setMode(.full)
    VoiceLibraryHTTP.standing = (standingVersion, true)
    VoiceLibraryHTTP.refuseStanding = true
    let file = try fixture.recording()
    let asked = try await fixture.manage(["action": "create", "file": .string(file.path), "name": "Sky Five", "language": "en"])
    require(asked.payload["status"] == "needs_confirmation"
            && asked.payload["question"]?.stringValue?.contains("no standing voice consent on record") == true,
            "a standing consent revoked at that very moment (Sky Studio refuses it) asks once instead")
    require(VoiceLibraryHTTP.voices.count == 1, "and nothing was created")
}

@MainActor
private func standingNarrationChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("standing-narrate"))
    AIAccessStore.shared.setMode(.full)
    VoiceLibraryHTTP.standing = (standingVersion, true)
    VoiceLibraryHTTP.needsEnroll = true
    guard case .result(let started) = try await fixture.narrate(["Hello there."]) else {
        return require(false, "a library voice never falls back to a local one")
    }
    require(started.payload["kind"] == "voice_enroll" && started.payload["confirm_token"] == nil
            && started.payload["full_access"]?.stringValue?.contains("377.6") == true,
            "full access builds the voice's MiniMax version without asking, and says what it costs at most")
    let built = try await fixture.wait(started)
    let enrolls = VoiceLibraryHTTP.calls("POST", "/jobs").filter { $0["kind"] == "voice_enroll" }
    require(built["status"] == "done" && enrolls.count == 1 && enrolls.first?["max_credits"] == 377.6, "one voice_enroll at the quoted price")

    VoiceLibraryHTTP.reset()
    VoiceLibraryHTTP.standing = (standingVersion, true)
    VoiceLibraryHTTP.needsEnroll = true
    guard case .result(let skipped) = try await fixture.narrate(["Hello there."], skipOneTime: true) else {
        return require(false, "skip_one_time reads in the cloud")
    }
    let read = try await fixture.wait(skipped)
    require(read["status"] == "done" && VoiceLibraryHTTP.calls("POST", "/jobs").allSatisfy { $0["kind"] == "voice_clone" },
            "skip_one_time is still honoured in full access: no MiniMax version is built")
}

@MainActor
private func standingFallbackChecks(_ root: URL) async throws {
    let lines = ["Our story starts here.", "The ship leaves at dawn.", "Nobody knows the way.", "But the stars do."]
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("standing-fallback"), cap: 30, audioSlots: 2)
    fixture.failSplitOnce = false
    // 这一次运行前面几组已经花掉好几笔一次性费用（同一天的账）：额度照声音库那几组给足，这里验的是不问，不是额度。
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    VoiceRecoveryHTTP.promptIndex = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element, $0.offset) })
    VoiceRecoveryHTTP.oneTimeAt = 1
    VoiceRecoveryHTTP.standingActive = true
    AIAccessStore.shared.setMode(.full)
    let failed = try await fixture.wait(fixture.clone(lines, subtitles: false))
    VoiceRecoveryHTTP.oneTimeAt = nil
    require(failed["status"] == "failed" && failed["failure"]?["code"] == "fallback_needs_one_time" && failed["confirm_token"] == nil
            && failed["full_access"] != nil, "full access does not ask about a mid-script fallback fee")
    guard let enrollID = failed["enroll_job_id"]?.stringValue else { return require(false, "get_job names the voice_enroll job it started") }
    let built = try await fixture.wait(.ok(["job_id": .string(enrollID)]))
    let file = failed["recovery_file"]?.stringValue ?? ""
    require(built["status"] == "done" && VoiceRecoveryHTTP.enrolls.count == 1 && VoiceRecoveryHTTP.enrolls.first?["max_credits"] == 377.6,
            "it builds the voice's MiniMax version once, at the quoted price")
    require(try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file)).fallbackFee == nil, "nothing is left waiting for an answer")
    guard let resumed = try await SkyStudioVoiceRecovery.resumeIfAsked(AIToolArguments(["resume": .string(file), "generate_missing": true]),
                                                                       project: fixture.project, services: fixture.services) else {
        return require(false, "resume is taken")
    }
    let finished = try await fixture.wait(resumed)
    require(finished["status"] == "done" && fixture.project.state.audioTracks.flatMap(\.clips).count == lines.count,
            "then generate_missing reads the missing parts and every line lands once")
}

@MainActor
private func settingsChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("standing-settings"))
    let standing = SkyStudioVoiceStanding.shared
    let services = standing.services
    defer { standing.services = services }
    standing.services = fixture.services
    AIAccessStore.shared.setMode(.ask)
    // 像刚开的 App 那样从「不知道」起（前面几组可能已经记上了）：不然回答里设置那一处拍早了也碰巧写 recorded，查不出来。
    standing.accountChanged()
    let asked = try await AISettingsTools.update(AIToolArguments(["ai_access_mode": "full_access"]))
    let question = asked.payload["question"]?.stringValue ?? ""
    require(asked.payload["status"] == "needs_confirmation" && question.contains("751.4") && question.contains("22.5")
            && question.contains("377.6") && question.contains("For every recording I later use") && question.contains(standingVersion),
            "set_settings asks to turn Full access on with the one-time voice fees and the standing consent it records")
    require(AIAccessStore.shared.mode == .ask && VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").isEmpty,
            "nothing changes before the answer")
    let on = try await AISettingsTools.update(AIToolArguments(["ai_access_mode": "full_access", "confirm_token": asked.payload["confirm_token"] ?? .null]))
    require(AIAccessStore.shared.mode == .full && on.payload["voice_standing_consent"]?["status"] == "recorded",
            "after the answer Full access is on and the standing consent is recorded")
    // 同一个回答里的设置（get_settings 读的那一处）也要说 recorded：2026-11-11 真实冒烟里它还写着打开之前的 unknown。
    require(on.payload["sections"]?["ai"]?["voice_standing_consent"] == on.payload["voice_standing_consent"],
            "the settings in the same answer show the consent just recorded, not the state before the change")
    require(VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").first?["statement_version"] == .string(standingVersion),
            "the recorded version is the one the question showed")

    let offAsked = try await AISettingsTools.update(AIToolArguments(["ai_access_mode": "ask_for_approval"]))
    require(offAsked.payload["status"] == "needs_confirmation" && offAsked.payload["question"]?.stringValue?.contains("For every recording") == false,
            "turning Full access off still asks, without the explanation")
    let off = try await AISettingsTools.update(AIToolArguments(["ai_access_mode": "ask_for_approval", "confirm_token": offAsked.payload["confirm_token"] ?? .null]))
    require(AIAccessStore.shared.mode == .ask && VoiceLibraryHTTP.calls("DELETE", "/voices/consent-grant").count == 1
            && off.payload["voice_standing_consent"]?["status"] == "revoked", "turning it off revokes the standing consent")
    // 撤掉之后同一个回答里的设置不能还写着 recorded（冒烟里顶层 revoked、设置里 recorded，AI 读哪一处都可能）。
    require(off.payload["sections"]?["ai"]?["voice_standing_consent"]?["status"] == "revoked",
            "the settings in the same answer say revoked too, not the consent that was just taken back")

    VoiceLibraryHTTP.grantUnavailable = true
    let again = try await AISettingsTools.update(AIToolArguments(["ai_access_mode": "full_access"]))
    let notRecorded = try await AISettingsTools.update(AIToolArguments(["ai_access_mode": "full_access", "confirm_token": again.payload["confirm_token"] ?? .null]))
    require(AIAccessStore.shared.mode == .full && notRecorded.payload["voice_standing_consent"]?["status"] == "not_recorded"
            && standing.status != .recorded(version: standingVersion),
            "a consent Sky Studio cannot record still turns Full access on, and says the first voice task will ask once")
    require(notRecorded.payload["sections"]?["ai"]?["voice_standing_consent"]?["status"] == "not_recorded",
            "and the settings in that answer say not_recorded too")
    VoiceLibraryHTTP.grantUnavailable = false
}

@MainActor
private func migrationChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("standing-migration"))
    let suite = "com.srtflow.standing-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let access = AIAccessStore(defaults: defaults)
    let standing = SkyStudioVoiceStanding(defaults: defaults, access: access)
    standing.services = fixture.services
    let key = "local-library-fixture"
    let migrated = { defaults.bool(forKey: SkyStudioVoiceStanding.migratedKey) }

    access.setMode(.ask)
    await standing.migrateIfNeeded(key: key)?.value
    require(VoiceLibraryHTTP.log.isEmpty && migrated(), "ask mode at the upgrade: nothing to record, and never checked again")

    defaults.removeObject(forKey: SkyStudioVoiceStanding.migratedKey)
    access.setMode(.full)
    VoiceLibraryHTTP.grantUnavailable = true
    await standing.migrateIfNeeded(key: key)?.value
    require(!migrated(), "a standing consent Sky Studio cannot record now is tried again next time")
    VoiceLibraryHTTP.grantUnavailable = false
    await standing.migrateIfNeeded(key: key)?.value
    require(VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").last?["statement_version"] == .string(standingVersion) && migrated()
            && standing.status == .recorded(version: standingVersion),
            "Full access on before the upgrade: the standing consent is recorded without asking")
    let posts = VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").count
    await standing.migrateIfNeeded(key: key)?.value
    require(VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").count == posts, "and only once on this Mac")

    defaults.removeObject(forKey: SkyStudioVoiceStanding.migratedKey)
    VoiceLibraryHTTP.reset()
    VoiceLibraryHTTP.standing = (standingVersion, true)
    await standing.migrateIfNeeded(key: key)?.value
    require(VoiceLibraryHTTP.calls("POST", "/voices/consent-grant").isEmpty && migrated(),
            "an account that already has an active standing consent is left alone")
}
