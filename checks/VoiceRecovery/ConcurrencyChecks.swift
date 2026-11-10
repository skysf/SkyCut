import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 几批同时交（声音 PR 4，SkyCut 声音方案 8.2–8.4、9.1 第 4、6 项），真 App 对象 + 假协议（deferred：先回排队、问的时候才回结局）：
// - 四句普通旁白四批、声音池 2 个：同时开着的最多 2 单、后交的先回、切句和落地照原来的顺序、一步撤销 / 重做；
// - 第二批在服务器上换了备用（fallback_used）：之后才交的批带 voice_plan.fallback.selection，已经交出去的不改；结果的 line_models 说
//   哪句是哪个模型读的、voice.note 提醒前后可能听得出差别、next_step 叫 AI 先转告；恢复记录里还没交的批照备用的那份；
// - 第二批「默认失败、备用要先花一次性费用」（fallback_needs_one_time，钱退了）：后面没交的不再交、先交的照样收好，任务以可恢复的 failed
//   结束、next_step 说怎么办；resume + generate_missing 照原来的选择补齐（不重新选模型）；
// - 一句太长拆成两批、后半先回来：切句照原来的顺序拼（词的先后和原文一样）。

@MainActor
func runVoiceConcurrencyChecks(_ root: URL) async throws {
    try await fallbackChecks(root)
    try await oneTimeChecks(root)
    try await longLineChecks(root)
}

private let primary: JSONValue = ["model": "gemini-3.8-flash-tts", "voice": "gemini:Charon",
                                  "fallback": ["model": "eleven-v4", "voice": "gemini:Charon"]]
private let backup: JSONValue = ["model": "eleven-v4", "voice": "gemini:Charon"]

/// 声音池 2 个、几批同时交：假协议按读的字认是第几批（`batches` 是每批读的字，一句一批时就是那几句）。
@MainActor
private func concurrent(_ root: URL, _ name: String, lines batches: [String], cap: Int = 800) throws -> VoiceRecoveryFixture {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent(name), cap: cap, audioSlots: 2)
    fixture.failSplitOnce = false
    VoiceRecoveryHTTP.deferred = true
    VoiceRecoveryHTTP.offerFallback = true
    VoiceRecoveryHTTP.promptIndex = Dictionary(uniqueKeysWithValues: batches.enumerated().map { ($0.element, $0.offset) })
    // 第一批要等第二批回过结局才做完：后交的先回。
    VoiceRecoveryHTTP.holdUntil = [0: 1]
    return fixture
}

/// `/jobs` 里第 `batch` 批（按读的字认）带的 plan。
private func sentPlan(_ text: String) -> JSONValue? {
    VoiceRecoveryHTTP.bodies("/jobs").last { $0["prompt"]?.stringValue == text }?["params"]?["plan"]
}

@MainActor
private func fallbackChecks(_ root: URL) async throws {
    let lines = ["Welcome to the course.", "First, open the project.", "Then add a clip.", "Finally, export the film."]
    let fixture = try concurrent(root, "concurrent", lines: lines)
    VoiceRecoveryHTTP.fallbackAt = 1
    let spent = SkyStudioSpendStore.shared.spentToday()
    let done = try await fixture.wait(fixture.started(fixture.narrate(lines)))
    require(done["status"] == "done", "four batches read together and land (got \(done["message"] ?? .null))")
    require(VoiceRecoveryHTTP.peak == 2, "never more batches open on Sky Studio than the two audio slots (peak \(VoiceRecoveryHTTP.peak))")
    require(Array(VoiceRecoveryHTTP.finishOrder.prefix(2)) == [1, 0], "the second batch came back before the first (\(VoiceRecoveryHTTP.finishOrder))")
    require(VoiceRecoveryHTTP.posts == 4 && SkyStudioSpendStore.shared.spentToday() == spent + 10, "each batch sent and charged once")

    // 第二批换了备用：先交的两批带整段的选择，之后才交的两批带备用的那份。
    require(sentPlan(lines[0]) == primary && sentPlan(lines[1]) == primary, "batches sent before the switch keep the script's selection")
    require(sentPlan(lines[2]) == backup && sentPlan(lines[3]) == backup,
            "batches sent after a batch fell back carry voice_plan.fallback.selection (got \(sentPlan(lines[2]) ?? .null), \(sentPlan(lines[3]) ?? .null))")
    let record = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: done["recovery_file"]?.stringValue ?? ""))
    require(record.batches[1].fallbackUsed == true && record.pendingSelection == backup.objectValue,
            "the recovery record keeps the switch: later batches would also use the fallback")
    let expected: JSONValue = [["line_index": 0, "model": "gemini-3.8-flash-tts", "fallback_used": false],
                               ["line_index": 1, "model": "eleven-v4", "fallback_used": true],
                               ["line_index": 2, "model": "eleven-v4", "fallback_used": false],
                               ["line_index": 3, "model": "eleven-v4", "fallback_used": false]]
    require(done["line_models"] == expected, "line_models says which model read each line (got \(done["line_models"] ?? .null))")
    require(done["voice"]?["note"]?.stringValue?.contains(SkyStudioVoiceoverRun.mixedModelsNote) == true,
            "voice.note warns that the lines may sound different and how to make them match")
    require(done["next_step"]?.stringValue?.contains("tell them what voice.note says") == true, "next_step asks the AI to relay voice.note")
    require(done["batches_done"] == 4 && done["batches_running"] == 0 && done["batches_waiting"] == 0, "get_job's batch counts end at 4 done")

    // 回来的顺序不管：切句、落地照原来的顺序，一步撤销 / 重做。
    let added = done["added"]?.arrayValue ?? []
    let starts = added.compactMap { $0["start"]?.doubleValue }
    require(added.compactMap { $0["text"]?.stringValue } == lines && starts == starts.sorted() && Set(starts).count == 4,
            "the clips land in the original order (got \(added.compactMap { $0["text"]?.stringValue }))")
    let state = fixture.project.state
    require(state.audioTracks.flatMap(\.clips).count == 4 && state.subtitleCues(of: .original).count >= 4, "four clips with their subtitles")
    fixture.project.effectiveUndoManager!.undo()
    require(fixture.project.state.audioTracks.flatMap(\.clips).isEmpty && fixture.project.state.subtitleCues(of: .original).isEmpty,
            "one undo removes the whole narration")
    fixture.project.effectiveUndoManager!.redo()
    require(fixture.project.state == state, "one redo brings it back")
}

@MainActor
private func oneTimeChecks(_ root: URL) async throws {
    let lines = ["Our story starts here.", "The ship leaves at dawn.", "Nobody knows the way.", "But the stars do."]
    let fixture = try concurrent(root, "one-time", lines: lines)
    VoiceRecoveryHTTP.oneTimeAt = 1
    let spent = SkyStudioSpendStore.shared.spentToday()
    let failed = try await fixture.wait(fixture.started(fixture.narrate(lines)))
    require(failed["status"] == "failed" && failed["failure"]?["code"] == "fallback_needs_one_time",
            "a batch whose fallback needs a one-time fee ends the job as a recoverable failure")
    require(failed["failure"]?["one_time"]?.arrayValue?.first?["kind"] == "voice_enroll", "and get_job carries the one-time fee it asked for")
    require(failed["next_step"]?.stringValue?.contains("generate_missing=true") == true
            && failed["next_step"]?.stringValue?.contains("one-time") == true, "next_step says what the fee is about and how to retry")
    require(VoiceRecoveryHTTP.posts == 2, "after that batch failed, the batches still waiting for a slot were never sent")
    let file = failed["recovery_file"]?.stringValue ?? ""
    let progress = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
    require(progress.batches[0].generated && progress.missing == [1, 2, 3], "the first batch is kept; the refunded one and the unsent ones are missing")
    require(SkyStudioSpendStore.shared.spentToday() == spent + 2.5, "only the finished batch is charged; the rest of the reservation is returned")
    require(fixture.project.state.audioTracks.allSatisfy { $0.clips.isEmpty }, "nothing is inserted while lines are missing")

    // 用户不建 MiniMax 版：照原来的模型重试没做成的几批（不重新选模型、不重读做好的那一批）。
    VoiceRecoveryHTTP.oneTimeAt = nil
    let quotes = VoiceRecoveryHTTP.bodies("/quote").count
    let retried = try await fixture.resume(file, generate: true)
    require(retried["status"] == "done", "resume with generate_missing finishes the narration")
    let requote = VoiceRecoveryHTTP.bodies("/quote").dropFirst(quotes).first
    require(requote?["params"]?["plan"] == primary && requote?["params"]?["batches"] == .array(lines.dropFirst().map(JSONValue.string)),
            "only the three missing batches are quoted again, with the script's own selection")
    require(VoiceRecoveryHTTP.posts == 5 && lines.dropFirst().allSatisfy { sentPlan($0) == primary }, "and sent with it")
    require(fixture.project.state.audioTracks.flatMap(\.clips).count == 4, "all four lines land once")
}

/// 一句太长、拆成两批（普通旁白先在句末、再在空格处切）：后半先回来，本机切句照样按原来的顺序拼，词的先后和原文一样。
@MainActor
private func longLineChecks(_ root: URL) async throws {
    let line = "One two three four five six seven eight nine ten eleven twelve."
    let parts = try SkyStudioVoiceBatch.make(lines: [line], limit: 40, pack: false).map(\.prompt)
    let fixture = try concurrent(root, "long-line", lines: parts, cap: 40)
    let done = try await fixture.wait(fixture.started(fixture.narrate([line])))
    require(parts.count == 2 && done["status"] == "done", "a long line read in two batches lands (got \(parts.count) parts, \(done["message"] ?? .null))")
    require(Array(VoiceRecoveryHTTP.finishOrder.prefix(2)) == [1, 0], "the second half came back first (\(VoiceRecoveryHTTP.finishOrder))")
    let record = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: done["recovery_file"]?.stringValue ?? ""))
    let words = record.outputs[0]?.words ?? []
    require(words.map(\.text).joined() == line && words.map(\.start) == words.map(\.start).sorted(),
            "the halves are joined in their original order (got \(words.map(\.text).joined()))")
}
