import Foundation
import SrtFlowMCPKit

// 声音 PR 1：建 MiniMax 版 / 设计 / 变声的请求和结果，声音任务做完时「实际怎么做的」，声音的错误码，429 的 `pool`，
// `/me` 的 `max_running_audio_jobs`，两个新上传用途（假协议，不碰真的网络）。样子照 Sky Studio 声音方案 5.3、5.6、第八节。

private let convertDone = """
{"job_id": "convert-1", "kind": "voice_convert", "status": "done", "poll_after_seconds": 5,
 "result": {"voice_url": "https://assets.example/originals/u/skycut/voice/convert-1/voice.wav",
            "background_url": "https://assets.example/originals/u/skycut/voice/convert-1/background.wav",
            "content_type": "audio/wav", "sample_rate": 48000, "channels": 1, "duration": 10.04, "source_duration": 10.005,
            "padded_seconds": 0, "model": "chatterbox-hd", "fallback_used": false, "expires_at": "2027-01-09T10:00:00Z"},
 "credits_charged": 17.5, "error": null}
"""

private func done(_ id: String, result: JSONValue) -> String {
    JSONValue.object(["job_id": .string(id), "status": "done", "result": result, "credits_charged": 10]).encodedString()
}

func runVoiceJobChecks() async {
    runVoiceRequestChecks()
    runVoiceResultChecks()
    await runVoiceJobRunChecks()
    await runVoicePoolChecks()
    await runVoiceUploadChecks()
    runVoiceMeChecks()
}

private func runVoiceRequestChecks() {
    let enroll = try? SkyStudioVoiceRequests.enroll(voice: sampleVoiceID, language: "en", model: "minimax-voice-clone", maxCredits: 377.3, idempotencyKey: "enroll-1")
    checkEqual(enroll?.jobBody, ["kind": "voice_enroll", "model": "minimax-voice-clone", "params": ["voice": .string(sampleVoiceID), "language": "en"],
                                 "inputs": [:], "max_credits": 377.3, "idempotency_key": "enroll-1"], "the whole voice_enroll /jobs body")
    checkEqual(enroll?.quoteBody, ["kind": "voice_enroll", "model": "minimax-voice-clone", "params": ["voice": .string(sampleVoiceID), "language": "en"]],
               "voice_enroll /quote leaves out max_credits and the key")
    check((try? SkyStudioVoiceRequests.enroll(voice: "gemini:Charon", language: "en", model: "minimax-voice-clone")) == nil, "only library voices get a MiniMax version")

    let design = try? SkyStudioVoiceRequests.design(description: " 温暖、沉稳的中年男声，适合纪录片旁白。 ", name: "纪录片男声", sampleText: "大家好。", maxCredits: 752)
    checkEqual(design?.kind, "voice_design", "kind voice_design")
    checkEqual(design?.model, "auto", "the server picks MiniMax or Qwen3 from the description")
    checkEqual(design?.prompt, "温暖、沉稳的中年男声，适合纪录片旁白。", "the description is the prompt")
    checkEqual(design?.params, ["name": "纪录片男声", "sample_text": "大家好。"], "name and the optional sample line")
    checkEqual((try? SkyStudioVoiceRequests.design(description: "A calm narrator.", name: "Calm", language: "en"))?.params["language"], "en", "an optional language hint")
    check((try? SkyStudioVoiceRequests.design(description: "  ", name: "x")) == nil, "a design needs a description")
    check((try? SkyStudioVoiceRequests.design(description: "A calm narrator.", name: "")) == nil, "a design needs a name")

    let quoted = try? SkyStudioVoiceRequests.convert(targetVoice: sampleVoiceID, sourceSeconds: 10.0049, targetLanguage: "en")
    checkEqual(quoted?.quoteBody, ["kind": "voice_convert", "model": "auto",
                                   "params": ["target_voice": .string(sampleVoiceID), "source": ["seconds": 10.005], "target_language": "en"]],
               "voice_convert is quoted by source seconds (to the millisecond), before uploading")
    var submitted = try? SkyStudioVoiceRequests.convert(targetVoice: "gemini:Charon", sourceSeconds: 10.005,
        sourceAudioURL: URL(string: "https://r2.example/uploads/u/clip.wav")!, maxCredits: 17.5, idempotencyKey: "convert-1")
    checkEqual(submitted?.jobBody["inputs"], ["source_audio_url": "https://r2.example/uploads/u/clip.wav"], "/jobs carries the uploaded source")
    check(submitted?.jobBody["params"]?["target_language"] == nil, "no target_language unless known")
    submitted?.maxCredits = nil
    check(submitted?.quoteBody["inputs"] == nil, "the source never goes to /quote")
    for (voice, seconds) in [("eleven:Daniel", 10.0), ("Voice123", 10.0), (sampleVoiceID, 0.0), (sampleVoiceID, .nan), (sampleVoiceID, .infinity)] {
        check((try? SkyStudioVoiceRequests.convert(targetVoice: voice, sourceSeconds: seconds)) == nil, "refused: \(voice) for \(seconds) s")
    }
    check((try? SkyStudioVoiceRequests.convert(targetVoice: sampleVoiceID, sourceSeconds: 5, targetLanguage: "English")) == nil, "target_language is ISO 639-1")
}

private func runVoiceResultChecks() {
    guard let json = try? JSONValue.decode(Data(convertDone.utf8)), let status = SkyStudioJobStatus(json: json) else {
        check(false, "the plan's voice_convert answer reads"); return
    }
    check(status.result == nil, "a conversion has no single url")
    guard case .conversion(let files)? = status.voiceResult else { check(false, "a voice_convert result reads as two files"); return }
    checkEqual(files.voiceURL.lastPathComponent, "voice.wav", "the new voice")
    checkEqual(files.backgroundURL.lastPathComponent, "background.wav", "the separated background")
    checkEqual(files.sampleRate, 48000, "48 kHz")
    checkEqual(files.channels, 1, "mono")
    checkEqual(files.sourceDuration, 10.005, "the source's length")
    checkEqual(files.paddedSeconds, 0, "padded seconds")
    check(files.expiresAt != nil, "60-day links carry an expiry")
    checkEqual(status.voiceOutcome?.model, "chatterbox-hd", "the model that actually ran")
    checkEqual(status.voiceOutcome?.fallbackUsed, false, "no fallback")

    let half = done("convert-2", result: ["voice_url": "https://assets.example/voice.wav", "model": "chatterbox-hd"])
    let halfStatus = (try? JSONValue.decode(Data(half.utf8))).flatMap(SkyStudioJobStatus.init(json:))
    check(halfStatus != nil && halfStatus?.voiceResult == nil && halfStatus?.result == nil, "a conversion missing its background is no result")

    var enrolled = sampleVoice
    if case .object(var object) = enrolled, case .array(var languages)? = object["languages"], case .object(var english) = languages[1] {
        english["minimax"] = true; languages[1] = .object(english); object["languages"] = .array(languages); enrolled = .object(object)
    }
    let enrollStatus = (try? JSONValue.decode(Data(done("enroll-1", result: ["voice": enrolled]).utf8))).flatMap(SkyStudioJobStatus.init(json:))
    if case .voice(let voice, let sample)? = enrollStatus?.voiceResult {
        checkEqual(voice.language("en")?.minimax, true, "voice_enroll: English now has a MiniMax version")
        checkEqual(sample, nil, "no sample for an enrolment")
    } else { check(false, "a voice_enroll result reads as the updated voice") }
    let designed: JSONValue = ["voice": ["id": .string(sampleVoiceID), "name": "纪录片男声", "source": "design",
                                         "languages": [["language": "zh", "kind": "design_sample", "minimax": true]]],
                               "sample_url": "https://r2.example/voices/u/v/sample-zh.mp3?sig=3"]
    let designStatus = (try? JSONValue.decode(Data(done("design-1", result: designed).utf8))).flatMap(SkyStudioJobStatus.init(json:))
    if case .voice(let voice, let sample)? = designStatus?.voiceResult {
        checkEqual(voice.source, "design", "voice_design: a designed voice")
        checkEqual(sample?.query, "sig=3", "with its temporary sample link")
    } else { check(false, "a voice_design result reads as the new voice") }
    let foreign = done("design-2", result: ["voice": ["id": "Voice123", "name": "x"]])
    check((try? JSONValue.decode(Data(foreign.utf8))).flatMap(SkyStudioJobStatus.init(json:))?.voiceResult == nil, "a voice whose id is not Sky Studio's is no result")

    let reading: JSONValue = ["url": "https://assets.example/originals/u/skycut/voice/clone-1/1.wav", "content_type": "audio/wav", "duration": 17.79,
                              "words": .null, "model": "minimax-speech-2.8-hd", "fallback_used": true,
                              "voice_plan": ["selection": ["model": "index-tts-2", "reference_language": "zh"], "rule": "zh_80"]]
    let readingStatus = (try? JSONValue.decode(Data(done("clone-1", result: reading).utf8))).flatMap(SkyStudioJobStatus.init(json:))
    check(readingStatus?.result != nil && readingStatus?.voiceResult == nil, "reading results keep their url as before")
    checkEqual(readingStatus?.voiceOutcome?.model, "minimax-speech-2.8-hd", "reading: the model that actually ran")
    checkEqual(readingStatus?.voiceOutcome?.fallbackUsed, true, "reading: the fallback was used")
    checkEqual(readingStatus?.voicePlan?.model, "index-tts-2", "the result's voice_plan shows what was planned")
    let upscale = (try? JSONValue.decode(Data(sampleDoneJob.utf8))).flatMap(SkyStudioJobStatus.init(json:))
    check(upscale?.voiceOutcome == nil && upscale?.voiceResult == nil && upscale?.voicePlan == nil, "other kinds carry nothing voice-related")
    let modelOnly = done("image-1", result: ["url": "https://assets.example/image.png", "model": "seedream5-flash"])
    let image = (try? JSONValue.decode(Data(modelOnly.utf8))).flatMap(SkyStudioJobStatus.init(json:))
    check(image?.result != nil && image?.voiceOutcome == nil, "a result with only a model is not a voice outcome")

    let failed = """
    {"job_id": "clone-2", "status": "failed", "billing": {"status": "refunded", "credits_charged": 0, "credits_refunded": 25.5},
     "error": {"code": "fallback_needs_one_time", "message": "The fallback needs a MiniMax version first.", "refunded": true,
               "one_time": [{"kind": "voice_enroll", "model": "minimax-voice-clone", "language": "zh", "credits": 377.3}]}}
    """
    let failure = (try? JSONValue.decode(Data(failed.utf8))).flatMap(SkyStudioJobStatus.init(json:))?.failure
    checkEqual(failure?.code, SkyStudioVoiceCodes.fallbackNeedsOneTime, "fallback_needs_one_time is the end code")
    checkEqual(failure?.refunded, true, "the default's attempt was refunded")
    checkEqual(failure?.oneTime.map(\.credits), [377.3], "the one-time cost to build the fallback")
    checkEqual(failure?.json["one_time"]?.arrayValue?.first?["kind"], "voice_enroll", "get_job would report the one-time cost")
    check(SkyStudioJobFailure(message: "plain").json["one_time"] == nil, "no one-time cost: nothing added")
}

private func runVoiceJobRunChecks() async {
    var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
    run.sleep = SleepLog().sleep
    guard let request = try? SkyStudioVoiceRequests.convert(targetVoice: sampleVoiceID, sourceSeconds: 10.005,
        sourceAudioURL: URL(string: "https://r2.example/uploads/u/clip.wav")!, maxCredits: 17.5) else { check(false, "a conversion request builds"); return }
    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, #"{"job_id": "convert-1", "status": "queued"}"#) : .http(200, convertDone) }
    let finished = try? await run.run(request)
    if case .conversion? = finished?.voiceResult { check(true, "a conversion job runs to its two files") } else { check(false, "a conversion job finishes") }
    checkEqual(SkyStudioStub.log.map(\.method), ["POST", "GET"], "submitted once, asked once")

    SkyStudioStub.reset { seen in
        seen.method == "POST" ? .http(202, #"{"job_id": "convert-2", "status": "queued"}"#)
            : .http(200, done("convert-2", result: ["voice_url": "https://assets.example/voice.wav"]))
    }
    if case .badAnswer? = await jobFailure({ _ = try await run.run(request) }) {} else {
        check(false, "a conversion done without both files is a finished job without a result")
    }

    // 409 one_time_required：交的时候被拒、一分不扣 —— 本机记的那笔能退，一次性费用读得出来。
    guard let enroll = try? SkyStudioVoiceRequests.enroll(voice: sampleVoiceID, language: "en", model: "minimax-voice-clone", maxCredits: 377.3),
          let batch = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice_clone", model: "minimax-speech-2.8-hd", voice: sampleVoiceID,
                                                               batches: ["Hello."], lines: ["Hello."]) else { check(false, "requests build"); return }
    let oneTime = #"{"error":{"code":"one_time_required","message":"Build the MiniMax English version first.","one_time":[{"kind":"voice_enroll","model":"minimax-voice-clone","language":"en","credits":377.3}]}}"#
    SkyStudioStub.reset { _ in .http(409, oneTime) }
    let refused = await jobFailure { _ = try await run.run(batch) }
    checkEqual(SkyStudioStub.log.map(\.method), ["POST"], "one_time_required is not retried")
    checkEqual(refused?.rejectedBeforeAdmissionCode, SkyStudioVoiceCodes.oneTimeRequired, "one_time_required is a known non-admission")
    check(refused?.canRefund(beforeAccepted: true) == true, "the local reservation can be returned")
    checkEqual(refused?.failure?.oneTime.map(\.kind), ["voice_enroll"], "the needed one-time cost comes along")
    if case .request(.server(let error))? = refused { checkEqual(error.voiceOneTime.first?.credits, 377.3, "readable from the server error too") }
    SkyStudioStub.reset { _ in .http(409, #"{"error":{"code":"minimax_voice_exists","message":"English already has a MiniMax version.","language":"en"}}"#) }
    let exists = await jobFailure { _ = try await run.run(enroll) }
    checkEqual(exists?.rejectedBeforeAdmissionCode, SkyStudioVoiceCodes.minimaxVoiceExists, "minimax_voice_exists charges nothing")
    SkyStudioStub.reset { _ in .http(409, #"{"error":{"code":"one_time_required","message":"x","charged":true}}"#) }
    let contradictory = await jobFailure { _ = try await run.run(batch) }
    check(contradictory?.canRefund(beforeAccepted: true) == false, "charge evidence still beats a non-admission code")
}

private func runVoicePoolChecks() async {
    let request = SkyStudioJobRequest(kind: "voice", model: "auto", prompt: "Hello.", params: ["voice": "gemini:Charon"], idempotencyKey: "pool-key")
    var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
    run.sleep = SleepLog().sleep
    for pool in ["audio", "default"] {
        let posts = NameLog()
        let full = #"{"error":{"code":"too_many_jobs","message":"Full","limit":8,"running":8,"pool":"\#(pool)"}}"#
        SkyStudioStub.reset { seen in
            if seen.method == "POST" { posts.add("post"); return posts.items.count == 1 ? .http(429, full) : .http(202, #"{"job_id":"job-1","status":"queued"}"#) }
            return .http(200, sampleDoneJobFor("job-1"))
        }
        checkEqual(try? await run.run(request).state, .done, "429 from the \(pool) pool: wait and submit again")
        let keys = SkyStudioStub.log.filter { $0.method == "POST" }.compactMap { $0.body.flatMap { try? JSONValue.decode($0) }?["idempotency_key"]?.stringValue }
        checkEqual(keys, ["pool-key", "pool-key"], "the \(pool) pool retry uses the same idempotency key")
    }
    for pool: JSONValue in ["video", 3, .null] {
        let body = JSONValue.object(["error": ["code": "too_many_jobs", "message": "Full", "limit": 3, "running": 3, "pool": pool]]).encodedString()
        SkyStudioStub.reset { _ in .http(429, body) }
        let failure = await jobFailure { _ = try await run.run(request) }
        checkEqual(SkyStudioStub.log.count, 1, "an unknown pool \(pool.encodedString()) is not a capacity refusal: no second POST")
        check(failure?.canRefund(beforeAccepted: true) == false, "an unknown pool cannot prove non-admission")
    }
    let shape = SkyStudioServerError(status: 429, code: "too_many_jobs", message: "Full", fields: ["limit": 8, "running": 8, "pool": "audio"])
    check(SkyStudioJobAdmission.slotRefusal(shape), "limit + running + a known pool is the capacity shape")
    check(SkyStudioJobError.request(.server(shape)).canRefund(beforeAccepted: true), "a pooled capacity refusal still returns the reservation")
}

private func runVoiceUploadChecks() async {
    checkEqual(SkyStudioVoiceUpload.referencePurpose, "voice_reference", "the reference recording's purpose")
    checkEqual(SkyStudioVoiceUpload.conversionSourcePurpose, "voice_convert_source", "the voice-change source's purpose")
    check(SkyStudioVoiceUpload.fits(bytes: 35_000_000), "35,000,000 bytes fits (decimal 35 MB)")
    check(!SkyStudioVoiceUpload.fits(bytes: 35_000_001) && !SkyStudioVoiceUpload.fits(bytes: 0), "one byte over, or empty, does not")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-voice-upload-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("reference.wav")
    try? Data(repeating: 7, count: 2048).write(to: file)
    SkyStudioStub.reset { seen in
        seen.url.hasSuffix("/uploads")
            ? .http(200, #"{"upload_url": "https://r2.example/put/1", "method": "PUT", "headers": {"Content-Type": "audio/wav"}, "file_url": "https://r2.example/uploads/u/1.wav"}"#)
            : .http(200, "")
    }
    let link = try? await jobAPI().upload(fileURL: file, contentType: "audio/wav", purpose: SkyStudioVoiceUpload.referencePurpose, key: jobKey)
    checkEqual(link?.absoluteString, "https://r2.example/uploads/u/1.wav", "the uploaded reference's file_url")
    let ticket = SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(ticket, ["filename": "reference.wav", "content_type": "audio/wav", "bytes": 2048, "purpose": "voice_reference"], "the /uploads ticket body")
    check(SkyStudioStub.log.last?.headers["Authorization"] == nil, "the PUT to storage carries no key")
}

private func runVoiceMeChecks() {
    let decoder = SkyStudioJSON.decoder()
    let pooled = sampleMe.replacingOccurrences(of: "\"max_running_jobs\": 3,", with: "\"max_running_jobs\": 3, \"max_running_audio_jobs\": 8,")
    let me = try? decoder.decode(SkyStudioMe.self, from: Data(pooled.utf8))
    checkEqual(me?.skycut.maxRunningAudioJobs, 8, "max_running_audio_jobs: the voice pool")
    checkEqual(me?.skycut.maxRunningJobs, 3, "max_running_jobs: the shared pool")
    let older = try? decoder.decode(SkyStudioMe.self, from: Data(sampleMe.utf8))
    check(older != nil && older?.skycut.maxRunningAudioJobs == nil, "an older server: no voice pool, the answer still reads")
    if let me {
        let stored = SkyStudioStoredAnswer(me: me, receivedAt: moment())
        let round = (try? SkyStudioJSON.encoder().encode(stored)).flatMap { try? decoder.decode(SkyStudioStoredAnswer.self, from: $0) }
        checkEqual(round?.me.skycut.maxRunningAudioJobs, 8, "the voice pool survives the stored answer")
    }
}
