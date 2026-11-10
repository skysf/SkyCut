import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 旁白中途：备用要先花一次性费用（任务结束码 fallback_needs_one_time，SkyCut 声音方案 4.5；声音 PR 4 让那一批停下，问用户是声音 PR 6），
// 真 App 对象 + 假协议（VoiceRecoveryHTTP），用声音库的声音读（MiniMax 版是声音库的声音才有的）：
// - 任务结束时 get_job 带问句、价（one_time，结束码带的价、声音照恢复记录）和 confirm_token，next_step 说两条路；恢复记录记下这一笔；
// - 普通 resume 照旧只恢复已有的，这一笔留着等答复，get_job 再给一遍同一个问题（同一张令牌）；
// - resume + skip_one_time：清掉这一笔，用原来的选择重报价、重交没做成的几批，不建 MiniMax 版；
// - resume + 别的令牌：再问（同一件事回同一张）；resume + 那张令牌：按报价记账、起 voice_enroll（模型、声音、语言、max_credits），
//   这一笔清掉，之后 resume + generate_missing 把没做成的读完、全部落地一次。

@MainActor
func runVoiceFallbackFeeChecks(_ root: URL) async throws {
    let lines = ["Our story starts here.", "The ship leaves at dawn.", "Nobody knows the way.", "But the stars do."]
    try await skipChecks(root, lines)
    try await buildChecks(root, lines)
    try await repricedChecks(root, lines)
}

private let libraryVoice = "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"

@MainActor
private func failedNarration(_ root: URL, _ name: String, _ lines: [String], dailyLimit: Double? = nil) async throws -> (VoiceRecoveryFixture, JSONValue) {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent(name), cap: 30, audioSlots: 2)
    if let dailyLimit { SkyStudioSpendStore.shared.setDailyLimit(dailyLimit) }
    fixture.failSplitOnce = false
    VoiceRecoveryHTTP.promptIndex = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element, $0.offset) })
    VoiceRecoveryHTTP.oneTimeAt = 1
    let failed = try await fixture.wait(fixture.clone(lines, subtitles: false))
    VoiceRecoveryHTTP.oneTimeAt = nil
    return (fixture, failed)
}

@MainActor
private func resume(_ fixture: VoiceRecoveryFixture, _ args: JSONValue) async throws -> AIToolResult {
    guard let result = try await SkyStudioVoiceRecovery.resumeIfAsked(AIToolArguments(args), project: fixture.project, services: fixture.services) else {
        throw AIToolError("resume was not taken")
    }
    return result
}

@MainActor
private func skipChecks(_ root: URL, _ lines: [String]) async throws {
    let (fixture, failed) = try await failedNarration(root, "fallback-fee-skip", lines)
    let file = failed["recovery_file"]?.stringValue ?? ""
    require(failed["status"] == "failed" && failed["failure"]?["code"] == "fallback_needs_one_time", "the batch whose fallback needs a fee ends the job")
    require(failed["confirm_token"]?.stringValue?.isEmpty == false && failed["question"]?.stringValue?.contains("377.6") == true,
            "get_job asks about the fee with its price and a confirm_token")
    require(failed["one_time"]?.arrayValue?.first?["credits"] == 377.6 && failed["one_time"]?.arrayValue?.first?["voice"] == .string(libraryVoice),
            "the fee carries its price and the recovery's voice")
    let next = failed["next_step"]?.stringValue ?? ""
    require(next.contains("skip_one_time=true") && next.contains("confirm_token") && next.contains("generate_missing=true"),
            "next_step names both answers: build with the token, or retry with skip_one_time")
    require(try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file)).fallbackFee?.credits == 377.6, "the recovery record keeps the fee")

    let plain = try await fixture.wait(try await resume(fixture, ["resume": .string(file)]))
    let waiting = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file)).fallbackFee
    require(plain["status"] != "done" && VoiceRecoveryHTTP.enrolls.isEmpty && waiting != nil,
            "a plain resume only recovers what exists and keeps the question waiting")
    require(plain["confirm_token"] != nil && plain["confirm_token"] == failed["confirm_token"] && plain["one_time"] == failed["one_time"],
            "and its get_job asks the same question again, with the same confirm_token")

    let quotes = VoiceRecoveryHTTP.bodies("/quote").count
    let retried = try await fixture.wait(try await resume(fixture, ["resume": .string(file), "skip_one_time": true]))
    let requote = VoiceRecoveryHTTP.bodies("/quote").dropFirst(quotes).first
    require(retried["status"] == "done" && VoiceRecoveryHTTP.enrolls.isEmpty, "skip_one_time retries the missing parts without building anything")
    require(requote?["params"]?["plan"]?["model"] == "index-tts-2", "with the script's own selection")
    require(try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file)).fallbackFee == nil, "and the question is answered")
    require(fixture.project.state.audioTracks.flatMap(\.clips).count == lines.count, "every line lands once")
}

@MainActor
private func buildChecks(_ root: URL, _ lines: [String]) async throws {
    let (fixture, failed) = try await failedNarration(root, "fallback-fee-build", lines)
    let file = failed["recovery_file"]?.stringValue ?? ""
    let token = failed["confirm_token"]?.stringValue ?? ""
    let wrong = try await resume(fixture, ["resume": .string(file), "confirm_token": "zzzzzz"])
    require(wrong.payload["status"] == "needs_confirmation" && wrong.payload["confirm_token"] == .string(token)
            && wrong.payload["confirm_token_refused"] != nil, "a token for something else asks again (the same pending code)")
    require(VoiceRecoveryHTTP.enrolls.isEmpty, "nothing is built before the answer")

    let spent = SkyStudioSpendStore.shared.spentToday()
    let building = try await resume(fixture, ["resume": .string(file), "confirm_token": .string(token)])
    require(building.payload["kind"] == "voice_enroll" && building.payload["next_step"]?.stringValue?.contains("generate_missing=true") == true,
            "the answered fee builds the MiniMax version and says how to finish")
    let built = try await fixture.wait(building)
    let enroll = VoiceRecoveryHTTP.enrolls.first
    require(built["status"] == "done" && VoiceRecoveryHTTP.enrolls.count == 1 && enroll?["model"] == "minimax-voice-clone"
            && enroll?["params"]?["voice"] == .string(libraryVoice) && enroll?["params"]?["language"] == "en" && enroll?["max_credits"] == 377.6,
            "voice_enroll names the model, the voice, the language and the approved price")
    require(SkyStudioSpendStore.shared.spentToday() == spent + 377.6, "the fee is charged against the day at the quoted price")
    require(try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file)).fallbackFee == nil, "the question is answered")

    let finished = try await fixture.wait(try await resume(fixture, ["resume": .string(file), "generate_missing": true]))
    require(finished["status"] == "done" && fixture.project.state.audioTracks.flatMap(\.clips).count == lines.count,
            "after building, generate_missing reads the missing parts and every line lands once")
}

/// 建的那一单在 Sky Studio 受理之前就没做成（价变了）：这一笔的问题还在（以前记上账就清，之后只剩 generate_missing、又回到同一个失败），
/// 恢复记录记下新价，get_job 带新价和下一步；再 resume 按新价问、点过头按新价建成，这时才清。
@MainActor
private func repricedChecks(_ root: URL, _ lines: [String]) async throws {
    // 前面的场景已经花了不少（每日额度 1,000）：这一个场景放宽额度、做完把自己记的账退掉，后面的场景照旧。
    let start = SkyStudioSpendStore.shared.spentToday()
    defer {
        SkyStudioSpendStore.shared.refund(SkyStudioSpendStore.shared.spentToday() - start, on: Date())
        SkyStudioSpendStore.shared.setDailyLimit(1_000)
    }
    let (fixture, failed) = try await failedNarration(root, "fallback-fee-repriced", lines, dailyLimit: 100_000)
    let file = failed["recovery_file"]?.stringValue ?? ""
    let token = failed["confirm_token"]?.stringValue ?? ""
    let record = URL(fileURLWithPath: file)
    let spent = SkyStudioSpendStore.shared.spentToday()
    VoiceRecoveryHTTP.enrollPriceChange = 400
    let refused = try await fixture.wait(try await resume(fixture, ["resume": .string(file), "confirm_token": .string(token)]))
    require(refused["status"] == "failed" && refused["code"] == "price_changed" && refused["credits_now"] == 400 && refused["credits_approved"] == 377.6
            && refused["next_step"]?.stringValue?.contains("resume=") == true && refused["one_time"]?.arrayValue?.first?["credits"] == 400,
            "an enrolment refused for its price ends with the new price and how to be asked again: \(refused)")
    require(SkyStudioSpendStore.shared.spentToday() == spent, "nothing stays on the day's spend")
    require(try SkyStudioVoiceRecoveryStore.read(record).fallbackFee?.credits == 400,
            "the question is still open in the recovery record, at the new price")

    let plain = try await fixture.wait(try await resume(fixture, ["resume": .string(file)]))
    let again = plain["confirm_token"]?.stringValue ?? ""
    require(!again.isEmpty && again != token && plain["question"]?.stringValue?.contains("400") == true,
            "a plain resume asks the same fee again at the new price, with a new token: \(plain["question"] ?? .null)")
    let building = try await resume(fixture, ["resume": .string(file), "confirm_token": .string(again)])
    let built = try await fixture.wait(building)
    require(built["status"] == "done" && VoiceRecoveryHTTP.enrolls.last?["max_credits"] == 400, "the new approval builds it at the new price")
    require(SkyStudioSpendStore.shared.spentToday() == spent + 400, "which is what the day is charged")
    require(try SkyStudioVoiceRecoveryStore.read(record).fallbackFee == nil, "and only then is the question answered")
    let finished = try await fixture.wait(try await resume(fixture, ["resume": .string(file), "generate_missing": true]))
    require(finished["status"] == "done" && fixture.project.state.audioTracks.flatMap(\.clips).count == lines.count, "every line lands once")
}
