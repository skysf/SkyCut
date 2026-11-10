import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 声音库（声音 PR 6，SkyCut 声音方案 4.2–4.6、9.1 第 8、9 项）走真 App 对象 + 假协议（VoiceLibraryHTTP）：
// - list_voices：预设按语言 + 我的声音；声音库用不了（503 voice_library_unavailable）照回预设，`mine` 说暂时用不了；只要预设就不问声音库。
// - create：先问授权（问句带服务器那句英文和版本），没点头之前什么都不传；点过头才传 voice_reference、建声音（consent: true + 版本、
//   idempotency_key、用了哪一段）；换一段录音的令牌不认。
// - delete：请求批准模式问一句、点过头才发 DELETE；全部权限直接删；存储一时不可用再发一次。
// - design：先报价、问一次性费用（带价），没点头不起任务；点过头记账、起 voice_design 任务、get_job 报新声音和样音；本机账按实收。
// - add_voiceover 用声音库的声音：报价要建 MiniMax 版时先问（不交任何一批）；skip_one_time 照不花钱的那个读（voice_clone、params.voice、
//   每批带同一个 plan）；点头起 voice_enroll；声音库用不了时报错、不退本机。

@MainActor
func runVoiceLibraryChecks(_ root: URL) async throws {
    try await listChecks(root)
    try await createChecks(root)
    try await deleteChecks(root)
    try await designChecks(root)
    try await narrationChecks(root)
}

@MainActor
private func listChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("library-list"))
    let all = try await fixture.list(["language": "en"])
    require(all.payload["mine"]?.arrayValue?.first?["id"] == .string(VoiceLibraryHTTP.voiceID), "list_voices returns the user's voices")
    require(all.payload["presets"]?.arrayValue?.first?["language"] == "en"
            && all.payload["presets"]?.arrayValue?.first?["voices"]?.arrayValue?.contains { $0["id"] == "gemini:Charon" && $0["default"] == true } == true,
            "and the English presets with the default marked")
    VoiceLibraryHTTP.reset()
    _ = try await fixture.list(["include": "presets"])
    require(VoiceLibraryHTTP.calls("GET", "/voices").isEmpty, "include=presets does not ask the voice library")
    VoiceLibraryHTTP.listFailure = (503, ["error": ["code": "voice_library_unavailable", "message": "Not configured.", "reason": "not_configured"]])
    let unavailable = try await fixture.list([:])
    require(unavailable.payload["mine"]?["unavailable"] == true && unavailable.payload["presets"]?.arrayValue?.count == 2,
            "an unavailable library still returns the zh and en presets, and mine says why")
}

@MainActor
private func createChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("library-create"))
    let file = try fixture.recording()
    let args: JSONValue = ["action": "create", "file": .string(file.path), "name": "Sky Two", "language": "zh"]
    let asked = try await fixture.manage(args)
    let token = asked.payload["confirm_token"]?.stringValue
    let question = asked.payload["question"]?.stringValue ?? ""
    require(token != nil && question.contains("voice-consent-v1") && question.contains("I am the person in this recording"),
            "create asks for consent with Sky Studio's statement and its version")
    require(VoiceLibraryHTTP.calls("POST", "/uploads").isEmpty && VoiceLibraryHTTP.calls("POST", "/voices").isEmpty,
            "nothing is uploaded or created before the user agrees")
    var other = args.objectValue ?? [:]
    other["start"] = 2
    other["confirm_token"] = .string(token ?? "")
    let refused = try await fixture.manage(.object(other))
    require(refused.payload["confirm_token_refused"] != nil, "another part of the recording needs its own consent")
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = .string(token ?? "")
    let created = try await fixture.manage(.object(confirmed))
    require(created.payload["status"] == "created" && created.payload["voice"]?["id"]?.stringValue?.hasPrefix("voice_") == true,
            "after consent the voice is created")
    let ticket = VoiceLibraryHTTP.calls("POST", "/uploads").first
    require(ticket?["purpose"] == "voice_reference" && ticket?["content_type"] == "audio/wav" && VoiceLibraryHTTP.uploads.count == 1,
            "the sample is uploaded once as voice_reference WAV")
    let creation = VoiceLibraryHTTP.calls("POST", "/voices").first
    require(creation?["consent"] == true && creation?["consent_statement_version"] == "voice-consent-v1"
            && creation?["language"] == "zh" && creation?["name"] == "Sky Two"
            && creation?["reference_url"] == "skystudio-private://voice/uploads/u/1.wav"
            && creation?["source"]?["file_name"] == "my-voice.wav" && creation?["idempotency_key"]?.stringValue?.count == 32,
            "POST /voices carries this recording's consent, its version, the private upload name, the part used and a stable key")
}

@MainActor
private func deleteChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("library-delete"))
    let access = AIAccessStore.shared
    let mode = access.mode
    defer { access.setMode(mode) }
    access.setMode(.ask)
    let args: JSONValue = ["action": "delete", "voice": .string(VoiceLibraryHTTP.voiceID)]
    let asked = try await fixture.manage(args)
    require(asked.payload["question"]?.stringValue?.contains("\"Sky\"") == true && VoiceLibraryHTTP.calls("DELETE", "/voices").isEmpty
            && VoiceLibraryHTTP.calls("DELETE", containing: "/voices/") == 0, "ask mode names the voice and asks before deleting")
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = asked.payload["confirm_token"] ?? .null
    let deleted = try await fixture.manage(.object(confirmed))
    require(deleted.payload["status"] == "deleted" && VoiceLibraryHTTP.calls("DELETE", containing: "/voices/") == 1, "after the answer it is deleted")

    VoiceLibraryHTTP.reset()
    access.setMode(.full)
    VoiceLibraryHTTP.deleteStorageFailures = 1
    let direct = try await fixture.manage(args)
    require(direct.payload["status"] == "deleted" && VoiceLibraryHTTP.calls("DELETE", containing: "/voices/") == 2,
            "full access deletes without asking and sends DELETE again after a storage failure")
}

@MainActor
private func designChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("library-design"))
    let spent = SkyStudioSpendStore.shared.spentToday()
    let args: JSONValue = ["action": "design", "description": "A calm, warm narrator", "name": "Calm"]
    let asked = try await fixture.manage(args)
    require(asked.payload["status"] == "needs_confirmation" && asked.payload["credits"] == 22.5
            && asked.payload["question"]?.stringValue?.contains("22.5") == true, "design asks first, with the quoted price")
    require(VoiceLibraryHTTP.calls("POST", "/jobs").isEmpty && SkyStudioSpendStore.shared.spentToday() == spent,
            "nothing starts and nothing is reserved before the answer")
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = asked.payload["confirm_token"] ?? .null
    let started = try await fixture.manage(.object(confirmed))
    require(started.payload["kind"] == "voice_design", "after the answer a voice_design job starts")
    let done = try await fixture.wait(started)
    let job = VoiceLibraryHTTP.calls("POST", "/jobs").first
    require(job?["kind"] == "voice_design" && job?["prompt"] == "A calm, warm narrator" && job?["params"]?["name"] == "Calm"
            && job?["max_credits"] == 22.5, "the job carries the description, the name and the approved price as max_credits")
    require(done["status"] == "done" && done["voice"]?["name"] == "Calm" && done["sample_url"] != nil && done["credits_charged"] == 22.5,
            "get_job reports the new voice, its sample and what was charged")
    require(SkyStudioSpendStore.shared.spentToday() == spent + 22.5, "the day's spend settles at what Sky Studio charged")

    // Qwen3 按描述 + 试读句每开始 1,000 字收一次（Sky Studio #247）：长一点的描述照报价走，任务的 max_credits 就是报价，不是写死的 22.5。
    let long: JSONValue = ["action": "design", "description": .string(String(repeating: "A calm, warm narrator with a soft voice. ", count: 30)),
                           "name": "Long", "sample_text": "Hello there."]
    let longAsked = try await fixture.manage(long)
    require(longAsked.payload["credits"] == 45 && longAsked.payload["question"]?.stringValue?.contains("45") == true,
            "a description and sample over 1,000 characters is asked at its quote (two blocks)")
    var longConfirmed = long.objectValue ?? [:]
    longConfirmed["confirm_token"] = longAsked.payload["confirm_token"] ?? .null
    let longDone = try await fixture.wait(try await fixture.manage(.object(longConfirmed)))
    require(longDone["status"] == "done" && VoiceLibraryHTTP.calls("POST", "/jobs").last?["max_credits"] == 45,
            "and the job's max_credits is that quote")
}

@MainActor
private func narrationChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("library-narrate"))
    let lines = ["Hello there.", "This is my own voice."]
    VoiceLibraryHTTP.needsEnroll = true
    guard case .result(let asked) = try await fixture.narrate(lines) else { return require(false, "a library voice never falls back to a local one") }
    require(asked.payload["status"] == "needs_confirmation" && asked.payload["one_time"]?.arrayValue?.first?["kind"] == "voice_enroll"
            && asked.payload["voice_plan"]?["rule"] == "default_needs_one_time"
            && asked.payload["next_step"]?.stringValue?.contains("skip_one_time=true") == true,
            "a needed MiniMax version is asked first, with the no-fee option")
    let quote = VoiceLibraryHTTP.calls("POST", "/quote").first
    require(quote?["kind"] == "voice_clone" && quote?["params"]?["voice"] == .string(VoiceLibraryHTTP.voiceID), "the script is quoted as cloned reading")
    require(VoiceLibraryHTTP.calls("POST", "/jobs").isEmpty, "no batch is sent before the user decides")

    guard case .result(let skipped) = try await fixture.narrate(lines, skipOneTime: true) else { return require(false, "skip_one_time reads in the cloud") }
    let read = try await fixture.wait(skipped)
    let batches = VoiceLibraryHTTP.calls("POST", "/jobs")
    require(read["status"] == "done" && !batches.isEmpty && batches.allSatisfy { $0["kind"] == "voice_clone"
            && $0["params"]?["voice"] == .string(VoiceLibraryHTTP.voiceID) && $0["params"]?["plan"]?["model"] == "index-tts-2" },
            "skip_one_time reads now with the no-fee selection, every batch with the same plan")

    VoiceLibraryHTTP.reset()
    VoiceLibraryHTTP.needsEnroll = true
    guard case .result(let again) = try await fixture.narrate(lines), let token = again.payload["confirm_token"]?.stringValue else {
        return require(false, "the fee question comes back")
    }
    guard case .result(let enrolling) = try await fixture.narrate(lines, token: token) else { return require(false, "the approved fee starts a job") }
    require(enrolling.payload["kind"] == "voice_enroll" && enrolling.payload["next_step"]?.stringValue?.contains("call add_voiceover again") == true,
            "the approved fee builds the MiniMax version first and says to narrate again")
    let built = try await fixture.wait(enrolling)
    let enroll = VoiceLibraryHTTP.calls("POST", "/jobs").first
    require(built["status"] == "done" && enroll?["kind"] == "voice_enroll" && enroll?["model"] == "minimax-voice-clone"
            && enroll?["params"]?["voice"] == .string(VoiceLibraryHTTP.voiceID) && enroll?["params"]?["language"] == "en" && enroll?["max_credits"] == 377.6,
            "voice_enroll names the model, voice, language and the approved price")

    VoiceLibraryHTTP.reset()
    VoiceLibraryHTTP.quoteFailure = (503, ["error": ["code": "voice_library_unavailable", "message": "Not configured.", "reason": "not_configured"]])
    do {
        _ = try await fixture.narrate(lines)
        require(false, "an unavailable library must not fall back to a local voice")
    } catch let error as AIToolError {
        require(error.message.contains("not available right now") && error.message.contains("nothing was charged"),
                "an unavailable library is reported, nothing charged, no local voice: \(error.message)")
    }
}
