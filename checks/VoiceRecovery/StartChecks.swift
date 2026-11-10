import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 云端配旁白回任务号之前的那几步（SkyStudioVoiceoverStart，SkyCut 声音方案 4.2 第 1–4 步、4.3、4.4、9.1 第 2、6 项），真 App 对象 + 假协议：
// - 不点名：gemini:Charon；整段 `/quote` 一次（kind voice、model auto、params.batches、英文稿不带语言提示），回 job_id 时带 voice_plan；
//   每批 `/jobs` 带同一个 params.plan、这一批的 max_credits、各自的幂等 key；恢复记录记下选择和每批的模型；服务器在某一批换了备用也记下；
// - 花钱之前就停下的：每日额度不够（daily_budget_exceeded，不换声音）、服务器拒（4xx，原话、不换声音）、要一次性费用、没有这个预设 / 模型；
//   服务器不答（5xx）当场退本机（要字幕却转写不了不再拒：声音 PR 5 换 eleven-v4 / 按字数估，见 TimingChecks.swift）；
// - 英式男声读中文改用中文的旁白角色、服务器的 warnings 进 voice.note、next_step 叫 AI 先转告。

@MainActor
func runVoiceStartChecks(_ root: URL) async throws {
    try await happyPathChecks(root)
    try await refusalChecks(root)
    try await noteChecks(root)
}

private let geminiCharon: JSONValue = ["model": "gemini-3.8-flash-tts", "voice": "gemini:Charon"]

@MainActor
private func happyPathChecks(_ root: URL) async throws {
    // 上限 30：三句各自一批（看每批自己的价和 key）；几句合一批在 TimingChecks.swift。
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("narrate"), cap: 30)
    fixture.failSplitOnce = false
    let spent = SkyStudioSpendStore.shared.spentToday()
    let lines = ["Welcome to the course.", "First, open the project.", "Then add a clip."]
    let started = try fixture.started(try await fixture.narrate(lines))
    require(started.payload["voice"]?["name"] == "gemini:Charon", "no voice named: gemini:Charon reads it")
    require(started.payload["voice_plan"]?["selection"] == geminiCharon, "job_id comes back with the server's voice_plan")
    require(started.payload["credits"] == 7.5 && started.payload["credits_expected"] == 6, "and the quote's most / expected credits")
    let quotes = VoiceRecoveryHTTP.bodies("/quote")
    require(quotes.count == 1, "the whole script is quoted once, before job_id")
    require(quotes.first?["kind"] == "voice" && quotes.first?["model"] == "auto" && quotes.first?["params"]?["voice"] == "gemini:Charon"
            && quotes.first?["params"]?["batches"] == .array(lines.map(JSONValue.string)) && quotes.first?["params"]?["language"] == nil
            && quotes.first?["params"]?["language_code"] == nil && quotes.first?["prompt"] == nil,
            "the quote names the voice, model auto, every batch, and no language hint for English")
    let done = try await fixture.wait(started)
    require(done["status"] == "done", "the narration finishes")
    let jobs = VoiceRecoveryHTTP.bodies("/jobs")
    require(jobs.count == 3 && jobs.allSatisfy { $0["params"]?["plan"] == geminiCharon && $0["params"]?["voice"] == "gemini:Charon"
            && $0["model"] == "auto" && $0["max_credits"] == 2.5 && $0["params"]?["batches"] == nil },
            "every batch carries the same selection and its own quoted credits")
    require(jobs.map { $0["prompt"]?.stringValue ?? "" } == lines, "each batch reads its own line")
    require(Set(jobs.compactMap { $0["idempotency_key"]?.stringValue }).count == 3, "one idempotency key per batch")
    require(SkyStudioSpendStore.shared.spentToday() == spent + 7.5, "the reservation settles at what was charged")
    let saved = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: done["recovery_file"]?.stringValue ?? ""))
    require(saved.version == 2 && saved.plan.voicePlan.selection == geminiCharon.objectValue
            && saved.batches.allSatisfy { $0.model == "gemini-3.8-flash-tts" && $0.fallbackUsed == false },
            "the recovery record keeps the selection and each batch's actual model")
    let clips = fixture.project.state.audioTracks.flatMap(\.clips)
    let cues = fixture.project.state.subtitleCues(of: .original)
    require(clips.count == 3 && clips.allSatisfy { clip in cues.contains { $0.start >= clip.timelineStart - 0.01 && $0.start < clip.timelineEnd } },
            "three clips land in one step, each with its subtitles (got \(clips.count) clips, \(cues.count) subtitles)")

    // 服务器在第二批里自己换了备用：做好的不重做，记录和 get_job 都说哪一批用了哪个模型（之后的批改带备用是声音 PR 4）。
    let fallback = try VoiceRecoveryFixture(folder: root.appendingPathComponent("fallback"), cap: 12)
    VoiceRecoveryHTTP.fallbackAt = 1
    let switched = try await fallback.wait(fallback.started(fallback.narrate(["Hello world.", "Good night."], subtitles: false)))
    let record = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: switched["recovery_file"]?.stringValue ?? ""))
    require(switched["status"] == "done" && record.batches[1].model == "eleven-v4" && record.batches[1].fallbackUsed == true
            && record.batches[0].fallbackUsed == false, "a batch Sky Studio finished on its fallback is recorded as such")
    require(switched["batches"]?.arrayValue?.last?["fallback_used"] == true, "get_job reports which batch used the fallback")
}

@MainActor
private func refusalChecks(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("refusals"), cap: 800)
    let spent = SkyStudioSpendStore.shared.spentToday()
    func nothingPaid(_ what: String) {
        require(VoiceRecoveryHTTP.bodies("/jobs").isEmpty && SkyStudioSpendStore.shared.spentToday() == spent, "\(what): nothing was sent or reserved")
    }
    func refused(_ what: String, _ expected: [String], _ run: () async throws -> SkyStudioVoiceoverStart.Outcome) async {
        do {
            _ = try await run()
            require(false, "\(what) is refused")
        } catch let error as AIToolError {
            require(expected.allSatisfy(error.message.contains), "\(what) is refused, saying \(expected) (got: \(error.message))")
        } catch { require(false, "\(what): unexpected error \(error)") }
        nothingPaid(what)
    }

    SkyStudioSpendStore.shared.setDailyLimit(0)
    if case .result(let blocked) = try await fixture.narrate(["Hello world."]) {
        require(blocked.payload["code"] == "daily_budget_exceeded" && blocked.payload["job_id"] == nil,
                "over the daily credit limit: daily_budget_exceeded, nothing starts (no local voice instead)")
    } else { require(false, "over the daily credit limit the narration does not switch to a local voice") }
    nothingPaid("over the daily credit limit")
    SkyStudioSpendStore.shared.setDailyLimit(1_000)

    VoiceRecoveryHTTP.quoteFailure = (400, ["error": ["code": "invalid_request", "message": "eleven-v4 does not read this language.",
                                                      "reason": "unsupported_language", "language": "xh"]])
    await refused("a request Sky Studio refuses", ["eleven-v4 does not read this language.", "Nothing was charged"]) {
        try await fixture.narrate(["Hello world."], model: "eleven-v4")
    }
    VoiceRecoveryHTTP.quoteFailure = (503, ["error": ["code": "unavailable", "message": "Down for maintenance."]])
    if case .local(let note, let catalog) = try await fixture.narrate(["Hello world."]) {
        require(note.contains("could not be used") && note.contains("Down for maintenance") && catalog != nil,
                "Sky Studio not answering while quoting: a local voice reads it, and voice.note says why")
    } else { require(false, "Sky Studio not answering while quoting falls back to a local voice") }
    nothingPaid("Sky Studio not answering")
    VoiceRecoveryHTTP.quoteFailure = nil

    await refused("an unknown preset", ["gemini:Nobody", "gemini:Charon", "Nothing was charged"]) {
        try await fixture.narrate(["Hello world."], ask: .preset("gemini:Nobody"))
    }
    await refused("an unknown model", ["no-such-model", "gemini-3.8-flash-tts", "Nothing was charged"]) {
        try await fixture.narrate(["Hello world."], model: "no-such-model")
    }
    fixture.transcribes = false
    VoiceRecoveryHTTP.quoteOneTime = [["kind": "voice_enroll", "model": "minimax-voice-clone", "language": "en", "credits": 377.6]]
    await refused("a quote asking for a one-time fee", ["one-time"]) { try await fixture.narrate(["Hello world."], subtitles: false) }
    VoiceRecoveryHTTP.quoteOneTime = []
    // 不要字幕、一批一句：不用转写，转写不了也照样配。
    let plain = try await fixture.wait(fixture.started(fixture.narrate(["Hello world."], subtitles: false)))
    require(plain["status"] == "done", "without subtitles a Gemini narration needs no transcription")
    fixture.transcribes = true
}

@MainActor
private func noteChecks(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("notes"), cap: 800)
    let british = try fixture.started(await fixture.narrate(["大家好，欢迎来到这节课。"], ask: .role(AIVoiceRole.named("en_male_british")!), subtitles: false))
    require(VoiceRecoveryHTTP.bodies("/quote").last?["params"]?["voice"] == "gemini:Charon",
            "en_male_british reading Chinese is read by the Chinese male role's preset")
    require(british.payload["voice"]?["note"]?.stringValue?.contains("en_male_british only reads English") == true,
            "and voice.note says so")
    require(british.payload["next_step"]?.stringValue?.hasPrefix("Before the user listens, tell them what voice.note says.") == true,
            "next_step tells the AI to relay voice.note first")
    _ = try await fixture.wait(british)

    VoiceRecoveryHTTP.quoteWarnings = ["not_listed_for_language"]
    let aoede = try fixture.started(await fixture.narrate(["大家好，今天我们从零开始学剪辑。"], ask: .name("Aoede"), subtitles: false))
    require(VoiceRecoveryHTTP.bodies("/quote").last?["params"]?["voice"] == "gemini:Aoede", "a bare preset name is sent as its id")
    require(aoede.payload["voice"]?["note"]?.stringValue?.contains("not one of Sky Studio's recommended Chinese voices") == true,
            "a preset not listed for the language reads anyway, with a note (got: \(aoede.payload["voice"]?["note"] ?? .null))")
    _ = try await fixture.wait(aoede)
    VoiceRecoveryHTTP.quoteWarnings = []
}
