import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 动态 code-point 上限、全球词时间、克隆句界及整批配额；均使用生产类型，不碰外网。
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
        check(separate.count == 2, "narration remains one request per line")
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
        let cloneModel = SkyStudioModel(id: "server-clone-model", kind: "voice_clone", title: "Clone",
                                       params: ["language": ["cmn", "en_us"]],
                                       limits: ["max_characters_by_language": ["cmn": 12, "en_us": 40]])
        let plan = try SkyStudioVoicePlan.make(lines: ["第一句。", "第二句。"], model: cloneModel, voice: "cloned voice", language: "zh")
        check(plan.batches.count == 1, "the server cap combines Chinese lines")
        check(plan.batches[0].request.model == "server-clone-model", "model id comes from the server")
        check(plan.batches[0].request.params["language"] == "cmn", "Chinese maps to the contract language")
        check(plan.batches[0].request.quoteBody["inputs"] == nil, "quote does not upload a reference")
        check(plan.batches[0].request.maxCredits == nil, "agreed price is added after quoting")
        do {
            _ = try SkyStudioVoicePlan.make(lines: ["Здравствуйте"], model: cloneModel, voice: "", language: "ru")
            check(false, "unsupported language refused before charging")
        } catch { check(true, "unsupported language refused before charging") }
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
    let quotes = [SkyStudioQuote(credits: 2, typicalSeconds: nil), SkyStudioQuote(credits: 2, typicalSeconds: nil), SkyStudioQuote(credits: 1, typicalSeconds: nil)]
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
