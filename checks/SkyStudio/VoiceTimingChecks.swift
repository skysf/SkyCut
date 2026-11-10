import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 声音 PR 5（SkyCut 声音方案第七节、8.1、9.1 第 5 项）的纯值：
// - 分批：一句超过上限先在句末分、再在逗号类 / 空白分；批只在两句之间分（runVoiceBatchSentenceChecks，跟着 runVoiceChecks 跑）；
// - 报价之前怎么读（SkyStudioVoiceReading）：转写得了合批对齐、转写不了的预设要字幕整段换 eleven-v4、Eleven 不读的语言 / 点名的模型 /
//   声音库的声音按字数估且一句一单；对着目录快照；
// - 原文切成词（SpeechWordTokens）、识别出来的词对到原文上（SpeechWordAlignment：字幕显示稿子的字）、按字数估（SpeechWordEstimate）；
// - Eleven 报的字符时间直接切开一批里的几句（SkyStudioVoiceSplit，不用转写）。

/// 一句超过上限：先在句末分、再在逗号类 / 空白分，不切在句子中间；批只在两句之间分。
func runVoiceBatchSentenceChecks() {
    do {
        let lines = ["A one.", "B two.", "C three.", "D four."]
        let packed = try SkyStudioVoiceBatch.make(lines: lines, limit: 14, pack: true)
        checkEqual(packed.map { $0.parts.map(\.line) }, [[0, 1], [2], [3]], "whole lines pack until the cap; a batch only breaks between lines")
        check(packed.flatMap(\.parts).map(\.text) == lines, "no line is cut when it fits")
        let english = "First sentence here. Second one, with a comma. Third."
        let pieces = try SkyStudioVoiceBatch.make(lines: [english], limit: 30, pack: true).flatMap(\.parts).map(\.text)
        checkEqual(pieces, ["First sentence here.", "Second one, with a comma.", "Third."], "an over-long line breaks at sentence ends first")
        let chinese = "第一句话很长。第二句话也很长！第三句？"
        checkEqual(try SkyStudioVoiceBatch.make(lines: [chinese], limit: 8, pack: true).flatMap(\.parts).map(\.text),
                   ["第一句话很长。", "第二句话也很长！", "第三句？"], "Chinese sentence ends (。！？) break a long line")
        checkEqual(try SkyStudioVoiceBatch.make(lines: [chinese], limit: 16, pack: true).flatMap(\.parts).map(\.text),
                   ["第一句话很长。第二句话也很长！", "第三句？"], "sentences that fit together stay in one piece (no newline inserted)")
        checkEqual(try SkyStudioVoiceBatch.make(lines: ["One, two, three, four, five."], limit: 12, pack: true).flatMap(\.parts).map(\.text),
                   ["One, two,", "three, four,", "five."], "a single sentence over the cap breaks at commas next")
        checkEqual(try SkyStudioVoiceBatch.make(lines: ["alpha beta gamma delta"], limit: 11, pack: true).flatMap(\.parts).map(\.text),
                   ["alpha beta", "gamma delta"], "then at spaces")
        checkEqual(try SkyStudioVoiceBatch.make(lines: ["It rose 3.5 percent. Then it fell."], limit: 21, pack: true).flatMap(\.parts).map(\.text),
                   ["It rose 3.5 percent.", "Then it fell."], "a decimal point is not a sentence end")
        let long = try SkyStudioVoiceBatch.make(lines: ["Short.", english, "Tail."], limit: 30, pack: true)
        check(long.allSatisfy { $0.prompt.unicodeScalars.count <= 30 }, "every batch stays within the cap")
        checkEqual(long.flatMap(\.parts).filter { $0.line == 1 }.map(\.text).joined(separator: " "), english,
                   "the pieces of a long line put back together are the line")
    } catch { check(false, "sentence-first batching: \(error)") }
}

func runVoiceTimingChecks() {
    tokenChecks()
    alignmentChecks()
    estimateChecks()
    readingChecks()
    elevenSplitChecks()
}

private func tokenChecks() {
    let hello = SpeechWordTokens.tokens("Hello, world.")
    checkEqual(hello.map(\.text), ["Hello,", " world."], "Latin words keep their punctuation and a leading space")
    checkEqual(hello.map(\.range), [0 ..< 6, 7 ..< 13], "each word knows where it is in the line (UTF-16)")
    checkEqual(hello.map(\.pause), [SpeechWordTokens.clausePause, SpeechWordTokens.sentencePause], "a comma pauses less than a full stop")
    checkEqual(SpeechWordTokens.tokens("你好，世界。").map(\.text), ["你", "好，", "世", "界。"], "Chinese: one character per word, punctuation attached")
    checkEqual(SpeechWordTokens.tokens("“你好”").map(\.text), ["“你", "好”"], "an opening quote goes with the next word")
    let mixed = SpeechWordTokens.tokens("SkyCut 2026年")
    checkEqual(mixed.map(\.text), ["SkyCut", " 2026", "年"], "mixed scripts split where the script changes")
    check(close(mixed.map(\.units), [6 * SpeechWordTokens.letterUnit, 4 * SpeechWordTokens.digitUnit, SpeechWordTokens.fullWidthUnit]),
          "letters weigh less than digits and Chinese characters: \(mixed.map(\.units))")
    checkEqual(SpeechWordTokens.tokens("안녕 하세요").map(\.text), ["안", "녕", " 하", "세", "요"], "Korean keeps the space between its words")
    checkEqual(SpeechWordTokens.tokens("U.S. economy.").map(\.pause), [0, SpeechWordTokens.sentencePause], "an acronym's dots are not a pause")
    check(SpeechWordTokens.tokens("……").isEmpty, "punctuation alone has no words")
}

private func alignmentChecks() {
    let heard = [TimedWord(text: "Sky", start: 0.1, end: 0.3), TimedWord(text: " cut", start: 0.3, end: 0.5),
                 TimedWord(text: " costs", start: 0.6, end: 0.9), TimedWord(text: " twenty", start: 1.0, end: 1.4),
                 TimedWord(text: " dollars.", start: 1.5, end: 2.0)]
    guard let words = SpeechWordAlignment.aligned(heard, to: "SkyCut costs 20 dollars.", duration: 2.2) else {
        return check(false, "a transcription close to the script aligns")
    }
    checkEqual(words.map(\.text), ["SkyCut", " costs", " 20", " dollars."], "subtitles show the script's words, not what the recogniser heard")
    checkEqual(words.map(\.start), [0.1, 0.6, 0.9, 1.5], "times come from the matched letters; an unmatched word fills the gap")
    checkEqual(words.map(\.end), [0.5, 0.9, 1.5, 2.0], "a word heard as two takes both times; the gap is shared by the unmatched word")
    let chinese = SpeechWordAlignment.aligned([TimedWord(text: "我们", start: 0, end: 0.4), TimedWord(text: "剪辑。", start: 0.5, end: 0.9)],
                                              to: "我们剪辑。", duration: 1)
    checkEqual(chinese?.map(\.text), ["我", "们", "剪", "辑。"], "Chinese words are split per character")
    checkEqual(chinese?.map(\.start), [0, 0.2, 0.5, 0.7], "a recognised word's time is shared by its characters")
    let lead = SpeechWordAlignment.aligned([TimedWord(text: " hello", start: 0.5, end: 0.8), TimedWord(text: " there.", start: 0.9, end: 1.3)],
                                           to: "Well, hello there.", duration: 1.5)
    if let first = lead?.first {
        checkEqual(first.text, "Well,", "a word the recogniser missed at the start is kept")
        check(first.start >= 0 && first.start < 0.5 && first.end <= 0.5, "and placed just before the first matched word")
    } else { check(false, "a missing first word still aligns") }
    check(SpeechWordAlignment.aligned([TimedWord(text: "Totally unrelated words", start: 0, end: 1)], to: "Hello world", duration: 1) == nil,
          "a transcription that does not match the script is not trusted (the line is estimated instead)")
    check(SpeechWordAlignment.aligned([], to: "Hello world", duration: 1) == nil, "no words, no alignment")
    let traditional = SpeechWordAlignment.aligned([TimedWord(text: "说话", start: 0, end: 0.6)], to: "說話", duration: 1)
    checkEqual(traditional?.map(\.text), ["說", "話"], "a simplified transcription aligns to a traditional script, shown as written")
    if let monotonic = SpeechWordAlignment.aligned(heard.reversed(), to: "SkyCut costs 20 dollars.", duration: 2.2) {
        check(zip(monotonic, monotonic.dropFirst()).allSatisfy { $0.start <= $1.start } && monotonic.allSatisfy { $0.end <= 2.2 && $0.end > $0.start },
              "words never go back in time and stay inside the line's audio")
    }
}

private func estimateChecks() {
    let rate = 1_000.0
    let tone = (0 ..< 2_000).map { Float(sin(Double($0) * 0.5) * 0.3) }
    let samples = [Float](repeating: 0, count: 500) + tone + [Float](repeating: 0, count: 500)
    let english = SpeechWordEstimate.estimated("One two.", samples: samples, sampleRate: rate)
    checkEqual(english.map(\.text), ["One", " two."], "estimated words are the script's words")
    checkEqual(english.map(\.start), [0.5, 1.5], "speech starts where the sound starts, then spreads by character count")
    checkEqual(english.last?.end, 2.5, "and ends where the sound ends")
    let chinese = SpeechWordEstimate.estimated("你好，世界。", samples: samples, sampleRate: rate)
    check(close(chinese.map(\.start), [0.5, 0.9, 1.7, 2.1]), "a comma leaves a pause the size of one Chinese character: \(chinese.map(\.start))")
    let silent = SpeechWordEstimate.estimated("Hi there.", samples: [Float](repeating: 0, count: 1_000), sampleRate: rate)
    checkEqual(silent.first?.start, 0, "no sound found: the whole audio is used")
    check(close([silent.last?.end ?? -1], [1]), "to its end")
    check(SpeechWordEstimate.estimated("……", samples: samples, sampleRate: rate).isEmpty, "punctuation alone has nothing to time")
}

/// 报价之前怎么读：对着 Sky Studio 导出的目录快照。
private func readingChecks() {
    guard let catalog = loadVoiceFixture()?.catalog else { return check(false, "the voice catalog snapshot loads for the reading checks") }
    func decide(_ voice: String, kind: String = "voice", model: String? = nil, subtitles: Bool = true, language: String = "ja",
                transcribes: Bool) -> SkyStudioVoiceReading {
        SkyStudioVoiceReading.decide(kind: kind, voice: voice, model: model, subtitles: subtitles, language: language,
                                     transcribes: transcribes, catalog: catalog)
    }
    let aligned = decide("gemini:Charon", transcribes: true)
    check(aligned == .init(model: "auto", packs: true, timing: .aligned, transcribes: true, switchedForTiming: false),
          "this Mac transcribes the language: pack the lines, align the subtitles locally (got \(aligned))")
    let switched = decide("gemini:Charon", transcribes: false)
    check(switched == .init(model: "eleven-v4", packs: true, timing: .provider, transcribes: false, switchedForTiming: true),
          "a preset, subtitles, and this Mac cannot transcribe: the whole script names the preset's eleven-v4 fallback (got \(switched))")
    let unsupported = decide("gemini:Charon", language: "km", transcribes: false)
    check(unsupported.model == "auto" && !unsupported.packs && unsupported.timing == .estimated,
          "eleven-v4 does not read the language either: estimated, one line per request (got \(unsupported))")
    let silent = decide("gemini:Charon", subtitles: false, transcribes: false)
    check(silent.model == "auto" && !silent.packs && silent.timing == nil,
          "no subtitles and this Mac cannot split batches: one line per request, no model switch (got \(silent))")
    let named = decide("gemini:Charon", model: "gemini-3.8-flash-tts", transcribes: false)
    check(named.model == "gemini-3.8-flash-tts" && !named.packs && named.timing == .estimated && !named.switchedForTiming,
          "a named model is kept: estimated, one line per request (got \(named))")
    let eleven = decide("eleven:Daniel", transcribes: false)
    check(eleven.model == "auto" && eleven.packs && eleven.timing == .provider, "an Eleven voice reports word timing: pack, provider (got \(eleven))")
    check(decide("gemini:Charon", model: "eleven-v4", transcribes: false).timing == .provider, "naming eleven-v4 gives provider timing")
    let library = decide(sampleVoiceID, kind: "voice_clone", transcribes: false)
    check(library.model == "auto" && !library.packs && library.timing == .estimated && !library.switchedForTiming,
          "a library voice is never swapped for Eleven: estimated, one line per request (got \(library))")
    check(decide(sampleVoiceID, kind: "voice_clone", transcribes: true) == .init(model: "auto", packs: true, timing: .aligned,
                                                                               transcribes: true, switchedForTiming: false),
          "a library voice this Mac can transcribe: pack and align")
    checkEqual(AIVoiceoverTiming.summary([.aligned, .aligned]), "aligned", "one kind of timing is reported as itself")
    checkEqual(AIVoiceoverTiming.summary([.aligned, .estimated]), "mixed", "lines that differ are mixed")
    check(AIVoiceoverTiming.summary([]) == nil, "no subtitled lines, no subtitle_timing")
    checkEqual(AIVoiceoverTiming.weakest([.provider, .aligned]), .aligned, "a line made of two batches is as reliable as its weaker part")
}

/// Eleven v4 报的字符时间（原文的字）直接切开一批里的两句，不用转写。
private func elevenSplitChecks() {
    let prompt = "Hello world.\nGood night."
    let characters = Array(prompt).map(String.init)
    var starts: [JSONValue] = []
    var ends: [JSONValue] = []
    for index in characters.indices {
        let start = index < 13 ? Double(index) * 0.08 : 1.6 + Double(index - 13) * 0.08
        starts.append(.number(start))
        ends.append(.number(start + 0.08))
    }
    let raw: JSONValue = [["characters": .array(characters.map(JSONValue.string)),
                           "character_start_times_seconds": .array(starts), "character_end_times_seconds": .array(ends)]]
    let words = SpeechWordTimes.timedWords(SpeechWordTimes.parse(raw), text: prompt, duration: 2.6)
    let batch = SkyStudioVoiceBatch(parts: [.init(line: 0, text: "Hello world."), .init(line: 1, text: "Good night.")])
    do {
        let slices = try SkyStudioVoiceSplit.slices(batch, words: words, samples: [Float](repeating: 0, count: 260), sampleRate: 100)
        checkEqual(slices.count, 2, "Eleven's character times split a batch back into its lines")
        check(slices[0].end > 0.95 && slices[0].end < 1.6, "the cut falls between the two lines' words (got \(slices[0].end))")
    } catch { check(false, "Eleven character times split a batch: \(error)") }
}

/// 浮点算出来的秒：差不到一微秒算一样。
private func close(_ actual: [Double], _ expected: [Double]) -> Bool {
    actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 1e-6 }
}
