import Foundation
import SrtFlowMCPKit

// 声音 PR 1（SkyCut 声音方案 9.1 第 2 项）：读稿整段报一次价、每批照报价交（假协议，不碰真的网络）。
// 钉住：`/quote` 带 `params.batches`（没有 prompt）、`model` 是 auto 或点名的；读回 voice_plan 的各项、credits / credits_expected /
// settlement、每批的积分、一次性费用；和钱有关的读不出来整份不算回答；每批 `/jobs` 带同一个 `params.plan`、这一批的 credits 当
// `max_credits`；拉丁字母的西语稿带 `params.language: "es"`，英文、中文、日文稿不带。
// 报价的样子照 Sky Studio 声音方案 5.4（Sky Studio 还没上线，正式回答以它的契约测试为准）。

let sampleCloneQuote = """
{"credits": 46.5, "credits_expected": 30, "settlement": "actual_output", "typical_seconds": 120,
 "voice_plan": {"selection": {"model": "index-tts-2", "reference_language": "zh"}, "requested_model": "auto", "rule": "zh_80",
   "languages": [{"language": "zh", "share": 0.93, "seconds": 55.6}, {"language": "en", "share": 0.07, "seconds": 4.2}],
   "reason": "Chinese is 93% of the reading time, so IndexTTS2 reads it with the Chinese reference.",
   "cross_language": false, "warnings": [],
   "fallback": {"selection": {"model": "minimax-speech-2.8-hd", "reference_language": "zh"}, "available": true, "auto": true}},
 "batches": [{"credits": 25.5, "credits_expected": 16.5, "characters": 290}, {"credits": 21, "credits_expected": 13.5, "characters": 240}],
 "one_time": []}
"""

let sampleOneTimeQuote = """
{"credits": 43.5, "credits_expected": 28, "settlement": "actual_output",
 "voice_plan": {"selection": {"model": "index-tts-2", "reference_language": "en"}, "requested_model": "auto", "rule": "default_needs_one_time",
   "languages": [{"language": "en", "share": 1, "seconds": 58}], "reason": "The default MiniMax English voice is not built yet.",
   "cross_language": false, "warnings": ["model_not_tested_for_language"],
   "fallback": {"selection": {"model": "minimax-speech-2.8-hd", "reference_language": "en"}, "available": false, "auto": false,
                "one_time": [{"kind": "voice_enroll", "model": "minimax-voice-clone", "language": "en", "credits": 377.3}]}},
 "batches": [{"credits": 43.5, "credits_expected": 28, "characters": 760}],
 "one_time": [{"kind": "voice_enroll", "model": "minimax-voice-clone", "voice": "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d", "language": "en",
               "credits": 377.3, "why": "Build the MiniMax English version once; English then reads with it.",
               "then": {"model": "minimax-speech-2.8-hd", "credits_expected": 21.8}}]}
"""

func runVoicePlanChecks() async {
    runLanguageHintChecks()
    runSegmentQuoteChecks()
    await runQuoteReadingChecks()
    await runBatchChecks()
}

private func runLanguageHintChecks() {
    let spanish = ["Hola a todos, bienvenidos a esta clase.", "Hoy vamos a aprender a editar un vídeo desde cero."]
    let german = ["Willkommen zu diesem Kurs über Videoschnitt.", "Heute lernen wir, wie man Untertitel erstellt."]
    let english = ["Welcome to this lesson.", "Today we will learn how to edit a video from scratch."]
    let chinese = ["大家好，欢迎来到这节课。", "今天我们从零开始学剪辑。"]
    let japanese = ["皆さん、こんにちは。", "今日は動画の編集を一から学びます。"]
    let korean = ["안녕하세요, 이번 수업에 오신 것을 환영합니다.", "오늘은 영상 편집을 배웁니다."]
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: spanish), "es", "a Spanish script is hinted es")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: german), "de", "a German script is hinted de")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: english), nil, "English is the server's default: no hint")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: chinese), nil, "Chinese: the server tells by itself")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: japanese), nil, "Japanese: no hint")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: korean), nil, "Korean: no hint")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: chinese + spanish), "es", "only the Latin-script lines decide the hint")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: chinese + english), nil, "Chinese with English lines: no hint")
    checkEqual(SkyStudioVoiceLanguageHint.hint(for: []), nil, "no lines: no hint")
    for (line, latin) in [("Hola, ¿cómo estás?", true), ("1.º de mayo", true), ("Tiếng Việt rất hay", true), ("我用 iPhone 拍的", false),
                          ("iPhone で撮りました", false), ("2026", false), ("Привет, как дела?", false), ("", false)] {
        checkEqual(SkyStudioVoiceLanguageHint.isLatin(line), latin, "Latin-script line? \(line)")
    }
}

private func runSegmentQuoteChecks() {
    let batches = ["大家好，欢迎来到这节课。今天我们从零开始学剪辑。", "先把素材拖进时间线。"]
    guard let narration = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: "gemini:Charon", batches: batches,
                                                                   lines: ["大家好，欢迎来到这节课。", "今天我们从零开始学剪辑。", "先把素材拖进时间线。"]) else {
        check(false, "a Chinese narration segment builds"); return
    }
    let body = narration.quoteBody
    checkEqual(body["kind"], "voice", "kind voice")
    checkEqual(body["model"], "auto", "model auto by default")
    checkEqual(body["params"]?["voice"], "gemini:Charon", "the preset goes as params.voice")
    checkEqual(body["params"]?["batches"], .array(batches.map(JSONValue.string)), "params.batches carries every batch in order")
    check(body["prompt"] == nil, "the whole-segment quote has no prompt")
    check(body["params"]?["language"] == nil, "a Chinese script carries no language hint")
    check(body["inputs"] == nil && body["max_credits"] == nil && body["idempotency_key"] == nil, "/quote leaves out inputs, max_credits, key")
    let spanish = ["Hola a todos, bienvenidos a esta clase.", "Hoy vamos a aprender a editar un vídeo desde cero."]
    let hinted = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: "gemini:Charon", batches: [spanish.joined(separator: " ")], lines: spanish)
    checkEqual(hinted?.quoteBody["params"]?["language"], "es", "a Spanish script carries params.language es")
    let english = ["Welcome to this lesson.", "Today we will learn how to edit a video from scratch."]
    let plain = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: "gemini:Charon", batches: [english.joined(separator: " ")], lines: english)
    check(plain != nil && plain?.quoteBody["params"]?["language"] == nil, "an English script carries no language hint")
    let named = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice", model: "eleven-v4", voice: "eleven:Daniel", batches: ["Hi."], lines: ["Hi."])
    checkEqual(named?.quoteBody["model"], "eleven-v4", "a named model is quoted by name")
    let clone = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice_clone", voice: sampleVoiceID, batches: ["你好。"], lines: ["你好。"])
    checkEqual(clone?.quoteBody["params"]?["voice"], .string(sampleVoiceID), "cloned reading sends the library voice id")

    let refused: [(String, () throws -> SkyStudioJobRequest)] = [
        ("a clone with a preset", { try SkyStudioVoiceRequests.segmentQuote(kind: "voice_clone", voice: "gemini:Charon", batches: ["x"], lines: ["x"]) }),
        ("narration with a library voice", { try SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: sampleVoiceID, batches: ["x"], lines: ["x"]) }),
        ("a bare old Eleven name", { try SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: "Rachel", batches: ["x"], lines: ["x"]) }),
        ("no batches", { try SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: "gemini:Charon", batches: [], lines: []) }),
        ("an empty batch", { try SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: "gemini:Charon", batches: ["ok", "  "], lines: ["ok"]) }),
        ("a model with spaces", { try SkyStudioVoiceRequests.segmentQuote(kind: "voice", model: "auto please", voice: "gemini:Charon", batches: ["x"], lines: ["x"]) }),
        ("design is not a reading kind", { try SkyStudioVoiceRequests.segmentQuote(kind: "voice_design", voice: "gemini:Charon", batches: ["x"], lines: ["x"]) })
    ]
    for (name, build) in refused { check((try? build()) == nil, "refused before sending: \(name)") }
}

private func runQuoteReadingChecks() async {
    let api = jobAPI()
    guard let segment = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice_clone", voice: sampleVoiceID, batches: ["第一批。", "第二批。"],
                                                                 lines: ["第一批。", "第二批。"]) else { check(false, "a clone segment builds"); return }
    SkyStudioStub.reset { _ in .http(200, sampleCloneQuote) }
    guard let quote = try? await api.quote(segment, key: jobKey) else { check(false, "the plan's clone quote reads"); return }
    checkEqual(SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }?["params"]?["batches"], ["第一批。", "第二批。"], "batches go to /quote")
    checkEqual(quote.credits, 46.5, "credits (the most, kept as max_credits)")
    checkEqual(quote.creditsExpected, 30, "credits_expected")
    checkEqual(quote.settlement, "actual_output", "settlement")
    let plan = quote.voice?.plan
    checkEqual(plan?.model, "index-tts-2", "the server chose IndexTTS2")
    checkEqual(plan?.referenceLanguage, "zh", "with the Chinese reference")
    checkEqual(plan?.selection, ["model": "index-tts-2", "reference_language": "zh"], "selection kept verbatim")
    checkEqual(plan?.requestedModel, "auto", "requested auto")
    checkEqual(plan?.rule, "zh_80", "rule")
    checkEqual(plan?.languages.map(\.language), ["zh", "en"], "language shares")
    checkEqual(plan?.languages.first?.share, 0.93, "Chinese share")
    check(plan?.reason?.hasPrefix("Chinese is 93%") == true, "the English reason is kept for the AI")
    checkEqual(plan?.crossLanguage, false, "not cross-language")
    checkEqual(plan?.fallback?.selection?["model"], "minimax-speech-2.8-hd", "the fallback's selection")
    checkEqual(plan?.fallback?.auto, true, "the fallback is automatic")
    checkEqual(quote.voice?.batches.map(\.credits), [25.5, 21], "each batch's credits")
    checkEqual(quote.voice?.batches.map(\.characters), [290, 240], "each batch's characters")
    checkEqual(quote.voice?.oneTime, [], "no one-time cost")
    checkEqual(plan?.json["reason"], .string(plan?.reason ?? ""), "the raw voice_plan is kept to report")

    SkyStudioStub.reset { _ in .http(200, sampleOneTimeQuote) }
    let single = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice_clone", voice: sampleVoiceID, batches: ["Hello."], lines: ["Hello."])
    let enroll = try? await api.quote(single!, key: jobKey)
    checkEqual(enroll?.voice?.plan?.needsOneTime, true, "default_needs_one_time is recognised")
    checkEqual(enroll?.voice?.plan?.warnings, [SkyStudioVoiceModelPlan.modelNotTestedForLanguage], "warnings kept")
    checkEqual(enroll?.voice?.oneTime.map(\.kind), ["voice_enroll"], "the one-time cost is listed")
    checkEqual(enroll?.voice?.oneTime.first?.credits, 377.3, "its credits")
    checkEqual(enroll?.voice?.oneTime.first?.then?["model"], "minimax-speech-2.8-hd", "what it changes to afterwards")
    checkEqual(enroll?.voice?.plan?.fallback?.oneTime.first?.credits, 377.3, "the fallback's one-time cost")
    checkEqual(enroll?.voice?.plan?.fallback?.available, false, "the fallback is not available without it")
    checkEqual(enroll?.voice?.oneTime.first.flatMap { SkyStudioVoiceOneTime(json: $0.json) }, enroll?.voice?.oneTime.first, "one-time items round-trip")

    // 和钱有关的读不出来：整份不算回答（不能悄悄丢掉一笔一次性费用、一批的价）。
    let unreadable: [(String, String, String)] = [
        ("a one-time cost without credits", sampleOneTimeQuote, #""credits": 377.3, "why""#),
        ("one_time that is not a list", sampleCloneQuote, #""one_time": []"#),
        ("a batch without credits", sampleCloneQuote, #"{"credits": 21, "#),
        ("a voice_plan without a selection", sampleCloneQuote, #""selection": {"model": "index-tts-2", "reference_language": "zh"}, "#),
        ("a fallback with an unreadable one-time cost", sampleOneTimeQuote, #""language": "en", "credits": 377.3}]}},"#)
    ]
    let replacements = [#""why""#, #""one_time": {"kind": "voice_enroll"}"#, "{", "", #""language": "en"}]}},"#]
    for ((name, sample, part), replacement) in zip(unreadable, replacements) {
        let broken = sample.replacingOccurrences(of: part, with: replacement)
        check(broken != sample, "the broken sample really differs: \(name)")
        check((try? JSONValue.decode(Data(broken.utf8))) != nil, "the broken sample is still JSON: \(name)")
        check((try? JSONValue.decode(Data(broken.utf8))).flatMap(SkyStudioQuote.init(json:)) == nil, "not an answer: \(name)")
    }
    // 整段报价：少一批的价、没有 voice_plan，也不算回答（每批交的时候要拿它们）。
    for (name, answer) in [
        ("fewer batches than asked", sampleCloneQuote.replacingOccurrences(of: #", {"credits": 21, "credits_expected": 13.5, "characters": 240}"#, with: "")),
        ("no voice_plan for a batched quote", sampleCloneQuote.replacingOccurrences(of: #""voice_plan""#, with: #""voice_plan_v0""#))
    ] {
        check(answer != sampleCloneQuote, "the broken sample really differs: \(name)")
        check((try? JSONValue.decode(Data(answer.utf8))).flatMap(SkyStudioQuote.init(json:)) != nil, "on its own it still reads: \(name)")
        SkyStudioStub.reset { _ in .http(200, answer) }
        if case .badAnswer? = await expectFailure(name, { _ = try await api.quote(segment, key: jobKey) }) {} else {
            check(false, "not an answer for a batched quote: \(name)")
        }
    }
    // 不带 batches 的报价（upscale、生成）照旧：没有声音的那几样也读得出来。
    SkyStudioStub.reset { _ in .http(200, #"{"credits": 18, "typical_seconds": 300}"#) }
    let plain = try? await api.quote(SkyStudioJobRequest(kind: "upscale", model: "topaz-starlight"), key: jobKey)
    check(plain != nil && plain?.voice == nil && plain?.creditsExpected == nil, "a quote without voice fields is unchanged")
}

private func runBatchChecks() async {
    let texts = ["第一批。第一批的第二句。", "第二批。"]
    guard let segment = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice_clone", voice: sampleVoiceID, batches: texts, lines: texts),
          let json = try? JSONValue.decode(Data(sampleCloneQuote.utf8)), let quote = SkyStudioQuote(json: json),
          let selection = quote.voice?.plan?.selection else { check(false, "the batch fixtures build"); return }
    let batches = (0..<texts.count).compactMap { try? SkyStudioVoiceRequests.batch($0, of: segment, quote: quote) }
    checkEqual(batches.count, 2, "both batches build")
    for (index, batch) in batches.enumerated() {
        let body = batch.jobBody
        checkEqual(body["kind"], "voice_clone", "batch \(index): kind")
        checkEqual(body["model"], "auto", "batch \(index): model stays auto")
        checkEqual(body["prompt"], .string(texts[index]), "batch \(index): the batch's own words")
        checkEqual(body["params"]?["plan"], .object(selection), "batch \(index) carries the segment's voice_plan.selection verbatim")
        checkEqual(body["params"]?["voice"], .string(sampleVoiceID), "batch \(index): the same voice")
        check(body["params"]?["batches"] == nil, "batch \(index): no batches list on /jobs")
        checkEqual(body["max_credits"], .number([25.5, 21][index]), "batch \(index): max_credits is that batch's quoted credits")
        check(body["idempotency_key"]?.stringValue?.isEmpty == false, "batch \(index): an idempotency key")
    }
    checkEqual(Set(batches.map(\.idempotencyKey)).count, 2, "each batch is its own purchase")
    checkEqual(batches.map { $0.jobBody["params"]?["plan"] }, [batches.first?.jobBody["params"]?["plan"], batches.first?.jobBody["params"]?["plan"]],
               "every batch carries the same params.plan")

    let fallback = quote.voice?.plan?.fallback?.selection
    let after = try? SkyStudioVoiceRequests.batch(1, of: segment, quote: quote, plan: fallback)
    checkEqual(after?.jobBody["params"]?["plan"]?["model"], "minimax-speech-2.8-hd", "after a fallback, later batches carry the fallback's selection")
    var named = segment
    named.model = "index-tts-2"
    checkEqual((try? SkyStudioVoiceRequests.batch(0, of: named, quote: quote))?.model, "index-tts-2", "a named model stays named on each batch")
    let spanish = ["Hola a todos.", "Bienvenidos a esta clase de edición de vídeo."]
    if let hinted = try? SkyStudioVoiceRequests.segmentQuote(kind: "voice", voice: "gemini:Charon", batches: spanish, lines: spanish) {
        checkEqual((try? SkyStudioVoiceRequests.batch(1, of: hinted, quote: quote))?.params["language"], "es", "the language hint rides on every batch")
    } else { check(false, "a hinted Spanish segment builds") }
    check((try? SkyStudioVoiceRequests.batch(2, of: segment, quote: quote)) == nil, "a batch outside the segment is refused")
    var short = quote
    short.voice?.batches.removeLast()
    check((try? SkyStudioVoiceRequests.batch(0, of: segment, quote: short)) == nil, "a quote with other batches is refused")
    var planless = quote
    planless.voice?.plan = nil
    check((try? SkyStudioVoiceRequests.batch(0, of: segment, quote: planless)) == nil, "no voice_plan to reuse: refused")

    // 交一批：202 和 GET 顶层带的 voice_plan 读得出来。
    SkyStudioStub.reset { _ in
        .http(202, #"{"job_id": "voice-job-1", "status": "queued", "credits_reserved": 25.5, "voice_plan": {"selection": {"model": "index-tts-2", "reference_language": "zh"}, "rule": "zh_80"}}"#)
    }
    let submitted = try? await jobAPI().submit(batches[0], key: jobKey)
    checkEqual(submitted?.voicePlan?.model, "index-tts-2", "the 202 answer's voice_plan")
    checkEqual(SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }?["params"]?["plan"], .object(selection), "the plan reaches /jobs")
}
