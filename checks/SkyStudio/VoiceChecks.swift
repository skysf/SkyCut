import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 动态 code-point 上限、全球词时间、克隆句界及整批配额；整段报价之前怎么分批、报价之后每批怎么交（SkyStudioVoicePlan，
// 声音 PR 3，SkyCut 声音方案 4.2、8.1、8.4）；普通旁白也合批、批只在两句之间分、一句超长先在句末分、切不开的一句一单、
// Eleven 读的按字符时间切（声音 PR 5，方案 8.1、9.1 第 5 项）；均使用生产类型，不碰外网。
func runVoiceChecks() {
    func chunk(_ text: String, at start: Double) -> JSONValue {
        let chars = Array(text).map(String.init)
        return ["characters": .array(chars.map(JSONValue.string)),
                "character_start_times_seconds": .array(chars.indices.map { .number(start + Double($0) * 0.1) }),
                "character_end_times_seconds": .array(chars.indices.map { .number(start + Double($0 + 1) * 0.1) })]
    }
    do {
        let packed = try SkyStudioVoiceBatch.make(lines: ["First line.", "Second line."], limit: 80, pack: true)
        check(packed.count == 1 && packed[0].parts.count == 2, "several clone lines share one request")
        let separate = try SkyStudioVoiceBatch.make(lines: ["First line.", "Second line."], limit: 80, pack: false)
        check(separate.count == 2, "lines this Mac cannot split apart stay one request per line")
        let long = try SkyStudioVoiceBatch.make(lines: [String(repeating: "你好", count: 300), "Next."], limit: 220, pack: true)
        check(long.count == 3, "long Chinese lines fit three requests, not one request per short sentence")
        check(long.allSatisfy { $0.prompt.unicodeScalars.count <= 220 }, "all code point caps hold")
        let emoji = try SkyStudioVoiceBatch.make(lines: [String(repeating: "👩🏽‍💻", count: 30)], limit: 40, pack: true)
        check(emoji.allSatisfy { $0.prompt.unicodeScalars.count <= 40 }, "emoji counted as code points")
        check(emoji.flatMap(\.parts).map(\.text).joined() == String(repeating: "👩🏽‍💻", count: 30), "no grapheme cut or text lost")
        let words = SpeechWordTimes.parse(.array([chunk("Hel", at: 0), chunk("lo ", at: 0.3), chunk("world", at: 0.6)]))
        check(words.map(\.text) == ["Hello", "world"], "all chunks, including one word spanning two chunks")
        check(abs((words.last?.start ?? -1) - 0.6) < 1e-9, "global times are not accumulated again")
        check(SpeechWordTimes.parse(.array([chunk("ab", at: 1), chunk("cd", at: 0)])).isEmpty, "backward chunks refused")
        check(SpeechWordTimes.parse(.array([chunk("ab", at: 0), ["characters": ["c"]]])).isEmpty, "malformed later chunk refused")
        check(SpeechWordTimes.parse(chunk("你好世界", at: 0)).count == 4, "Chinese characters remain separately timed")
        runVoiceDraftChecks()
        runVoiceBatchSentenceChecks()
        let capped = SpeechWordTimes.timedWords([.init(text: "hello", start: 0, end: 1.05), .init(text: "world", start: 1.1, end: 2)], text: "hello world", duration: 1)
        checkEqual(capped.map(\.end), [1], "no word extends beyond the decoded duration")
        let batch = try SkyStudioVoiceBatch.make(lines: ["Hello world", "Next line"], limit: 40, pack: true)[0]
        let timed = [TimedWord(text: "Hello", start: 0.1, end: 0.3), TimedWord(text: " world", start: 0.4, end: 0.7),
                     TimedWord(text: " Next", start: 1.1, end: 1.4), TimedWord(text: " line", start: 1.5, end: 1.9)]
        let samples = [Float](repeating: 0, count: 200)
        let slices = try SkyStudioVoiceSplit.slices(batch, words: timed, samples: samples, sampleRate: 100)
        checkEqual(slices.count, 2, "one request returns two original lines")
        check(slices[0].end >= 0.7 && slices[0].end <= 1.1, "cut is between actual words")
        checkEqual(slices[0].end, slices[1].start, "no lost or duplicated samples at the seam")
        checkEqual(slices.last?.end, 2, "last line retains the complete audio tail")
        for bad in [Array(timed.prefix(2)), [TimedWord(text: "Totally unrelated words", start: 0.1, end: 1.9)],
                    [TimedWord(text: "Hello world Next line", start: 0.1, end: 1.9)]] {
            do { _ = try SkyStudioVoiceSplit.slices(batch, words: bad, samples: samples, sampleRate: 100)
                check(false, "missing, unrelated or inseparable speech must retain the complete file")
            } catch { check(true, "unreliable split refused") }
        }
    } catch { check(false, "voice pure checks: \(error)") }
}

@MainActor
func runVoiceBudgetChecks() {
    let suite = "com.srtflow.voice-budget-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkyStudioSpendStore(defaults: defaults)
    store.setDailyLimit(5)
    let quotes: [Double] = [2, 2, 1]
    guard var budget = SkyStudioVoiceBudget.reserve(quotes, store: store) else { return check(false, "whole voice budget reserved") }
    checkEqual(store.spentToday(), 5, "reserve all batches atomically")
    check(SkyStudioVoiceBudget.reserve(quotes, store: store) == nil, "another job cannot reuse the reserved allowance")
    budget.settled(0, charged: 1.5)
    checkEqual(store.spentToday(), 4.5, "completed batch settles to actual cost")
    budget.unknown(1)
    budget.refundUnused()
    budget.refundUnused()
    checkEqual(store.spentToday(), 3.5, "unstarted batches refund once, uncertain batch stays reserved")
    checkEqual(budget.charged, 1.5, "known charge reported separately")
    checkEqual(budget.uncertain, 2, "uncertain charge reported separately")
    store.setDailyLimit(0)
    check(SkyStudioVoiceBudget.reserve(quotes, store: store) == nil, "zero daily limit never reserves voice credits")
}

/// 报价之前分批（上限读 `/models`、同一个 kind 里最小的那个）、整段报价的请求；报价之后每批照报价交、要不要本机转写。
private func runVoiceDraftChecks() {
    guard let catalog = loadVoiceFixture()?.catalog else { return check(false, "the voice catalog snapshot loads for the plan checks") }
    do {
        let lines = ["第一句。", "第二句。"]
        let packing = SkyStudioVoiceReading.decide(kind: "voice", voice: "gemini:Charon", model: nil, subtitles: true, language: "zh",
                                                   transcribes: true, catalog: catalog)
        let packed = try SkyStudioVoicePlan.draft(lines: lines, kind: "voice", voice: "gemini:Charon", reading: packing, language: "zh", catalog: catalog)
        checkEqual(packed.speech.map(\.prompt), [lines.joined(separator: "\n")],
                   "narration packs whole lines into one batch when this Mac can split them (voice PR 5)")
        let perLine = SkyStudioVoiceReading.decide(kind: "voice", voice: "gemini:Charon", model: nil, subtitles: false,
                                                   language: "zh", transcribes: false, catalog: catalog)
        let narration = try SkyStudioVoicePlan.draft(lines: lines, kind: "voice", voice: "gemini:Charon", reading: perLine, language: "zh", catalog: catalog)
        checkEqual(narration.speech.map(\.prompt), lines, "lines this Mac cannot split apart (and a model with no word timing): one request per line")
        let body = narration.segment.quoteBody
        checkEqual(body["params"]?["batches"], .array(lines.map(JSONValue.string)), "the whole script is quoted once, as params.batches")
        checkEqual(body["params"]?["voice"], "gemini:Charon", "the resolved preset goes as params.voice")
        checkEqual(body["model"], "auto", "model auto unless one is named")
        check(body["prompt"] == nil && body["params"]?["language"] == nil && body["params"]?["language_code"] == nil,
              "a Chinese script: no prompt, no language hint, no old language_code")
        let cloning = SkyStudioVoiceReading.decide(kind: "voice_clone", voice: sampleVoiceID, model: nil, subtitles: true, language: "zh",
                                                   transcribes: true, catalog: catalog)
        let clone = try SkyStudioVoicePlan.draft(lines: lines, kind: "voice_clone", voice: sampleVoiceID, reading: cloning, language: "zh", catalog: catalog)
        check(clone.speech.count == 1 && clone.speech[0].parts.count == 2, "cloned reading packs lines within the server's cap")
        let chinese = try SkyStudioVoicePlan.draft(lines: [String(repeating: "你", count: 301)], kind: "voice", voice: "gemini:Charon",
                                                   reading: packing, language: "zh", catalog: catalog)
        checkEqual(chinese.speech.count, 2, "the Chinese cap (300 code points) comes from /models")
        let english = try SkyStudioVoicePlan.draft(lines: [String(repeating: "word ", count: 170)], kind: "voice", voice: "gemini:Charon",
                                                   reading: packing, language: "en", catalog: catalog)
        checkEqual(english.speech.count, 2, "other languages use the `other` cap (800)")
        check((try? SkyStudioVoicePlan.draft(lines: lines, kind: "voice", voice: "gemini:Charon", reading: packing, language: "zh",
                                             catalog: SkyStudioCatalog(models: []))) == nil, "no character limit from Sky Studio: no plan")

        let selection: JSONValue = ["model": "gemini-3.8-flash-tts", "voice": "gemini:Charon"]
        let answer: JSONValue = ["credits": 5, "credits_expected": 3.2, "settlement": "actual_output",
            "voice_plan": ["selection": selection, "requested_model": "auto", "rule": "preset", "reason": "A preset voice reads this text.",
                           "languages": [["language": "zh", "share": 1, "seconds": 1.8]], "cross_language": false, "warnings": []],
            "batches": [["credits": 2.5, "credits_expected": 1.6, "characters": 4], ["credits": 2.5, "credits_expected": 1.6, "characters": 4]],
            "one_time": []]
        guard let quote = SkyStudioQuote(json: answer) else { return check(false, "the whole-segment quote reads") }
        let plan = try SkyStudioVoicePlan.quoted(narration, quote: quote)
        checkEqual(plan.batches.map(\.request.prompt), lines, "each batch is sent with its own words")
        check(plan.batches.allSatisfy { $0.request.params["plan"] == selection }, "every batch carries the same voice_plan selection")
        check(plan.batches.allSatisfy { $0.request.params["batches"] == nil && $0.request.params["voice"] == "gemini:Charon" },
              "batches carry the voice, not the whole script")
        checkEqual(plan.batchCredits, [2.5, 2.5], "each batch's max_credits is its own quoted credits")
        checkEqual(Set(plan.batches.map(\.request.idempotencyKey)).count, 2, "one idempotency key per batch")
        checkEqual(plan.voicePlan.selection, selection.objectValue ?? [:], "the server's selection is kept for recovery and get_job")
        check(!plan.needsTranscription(subtitles: true, catalog: catalog),
              "one line per batch and this Mac cannot transcribe (subtitles estimated): nothing to transcribe")
        check(!plan.needsTranscription(subtitles: false, catalog: catalog), "one line per batch and no subtitles: nothing to transcribe")
        var aligned = plan
        aligned.reading = packing
        check(aligned.needsTranscription(subtitles: true, catalog: catalog), "Gemini gives no word times: aligned subtitles need this Mac's transcription")
        var single = answer.objectValue ?? [:]
        single["batches"] = [["credits": 5, "credits_expected": 3.2, "characters": 9]]
        if let one = SkyStudioQuote(json: .object(single)), let together = try? SkyStudioVoicePlan.quoted(packed, quote: one) {
            check(together.needsTranscription(subtitles: false, catalog: catalog), "two lines in one Gemini batch: splitting them needs transcription")
        } else { check(false, "a one-batch quote reads") }

        var eleven = answer.objectValue ?? [:]
        eleven["voice_plan"] = ["selection": ["model": "eleven-v4", "voice": "eleven:Daniel"], "rule": "named_model"]
        if let quoted = SkyStudioQuote(json: .object(eleven)), let named = try? SkyStudioVoicePlan.quoted(narration, quote: quoted) {
            check(!named.needsTranscription(subtitles: true, catalog: catalog), "Eleven v4 reports word times: no transcription needed")
        } else { check(false, "an Eleven v4 quote reads") }

        var short = answer.objectValue ?? [:]
        short["batches"] = [["credits": 5, "credits_expected": 3.2]]
        if let mismatched = SkyStudioQuote(json: .object(short)) {
            check((try? SkyStudioVoicePlan.quoted(narration, quote: mismatched)) == nil, "a quote that does not cover every batch is refused")
        }
        var fee = answer.objectValue ?? [:]
        fee["one_time"] = [["kind": "voice_enroll", "model": "minimax-voice-clone", "language": "en", "credits": 377.6]]
        if let withFee = SkyStudioQuote(json: .object(fee)) {
            do { _ = try SkyStudioVoicePlan.quoted(narration, quote: withFee); check(false, "a quote asking for a one-time fee is not sent (voice PR 6 asks first)") }
            catch { check("\(error)".contains("one-time"), "a quote asking for a one-time fee is not sent (voice PR 6 asks first)") }
        }
    } catch { check(false, "voice draft checks: \(error)") }
}
