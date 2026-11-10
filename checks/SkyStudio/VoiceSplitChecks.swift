import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 2026-11-10 声音 PR 3–5 审查的纯值（docs/bugfixes/2026-11-10-*.md 那三个，真 App 上的场景在 checks/VoiceRecovery/PaidAudioChecks.swift）：
// - 切句对字不计较繁简：稿子是繁体、词写成简体（或反过来）照样切开；真的对不上的照旧拒绝；
// - 转写用哪种语言：繁体稿是 zh-Hant，简体、两种写法一样的、别的语言原样；
// - 没有词可对时按字数估句界（SkyStudioVoiceSplitEstimate）：切在估的位置附近最长的安静窗里、没有安静就切在估的位置、
//   一刀比一刀晚、短到分不出来就拒绝；
// - 一批的字数上限按这一批里出现的文字（服务器按每一批自己的语言卡）：英文稿夹一行长中文照中文的上限分。

func runVoiceSplitChecks() {
    scriptFoldingChecks()
    estimatedSplitChecks()
    batchLimitChecks()
}

private func scriptFoldingChecks() {
    do {
        let lines = ["歡迎來到這門課程。", "今天我們學習剪輯影片。", "請記得訂閱頻道。"]
        let batch = try SkyStudioVoiceBatch.make(lines: lines, limit: 800, pack: true)[0]
        checkEqual(batch.parts.count, 3, "three Traditional Chinese lines pack into one batch")
        // 简体模型的转写：一个字一个词，均匀铺在 0.1–5.9 秒。
        let simplified = lines.map { $0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? $0 }
        let characters = simplified.joined().filter { $0.isLetter }.map(String.init)
        let step = 5.8 / Double(characters.count)
        let heard = characters.enumerated().map { TimedWord(text: $0.element, start: 0.1 + Double($0.offset) * step, end: 0.1 + Double($0.offset + 1) * step) }
        for (index, line) in lines.enumerated() {
            let same = SubtitleCueWords.matchingCharacterCount(simplified[index], to: line)
            check(Double(same) < Double(line.filter(\.isLetter).count) * 0.65, "line \(index): fewer than 65% of its characters are written the same in both scripts")
        }
        let samples = [Float](repeating: 0, count: 600)
        let slices = try SkyStudioVoiceSplit.slices(batch, words: heard, samples: samples, sampleRate: 100)
        checkEqual(slices.map(\.part.text), lines, "a Traditional script heard in Simplified characters is split into its lines")
        let firstEnd = 0.1 + 8 * step, secondEnd = 0.1 + 18 * step
        check(abs(slices[0].end - firstEnd) < step && abs(slices[1].end - secondEnd) < step, "each cut falls between the two lines' characters")
        // 反过来：稿子是简体、词写成繁体。
        let reverse = try SkyStudioVoiceBatch.make(lines: simplified, limit: 800, pack: true)[0]
        let traditional = lines.joined().filter { $0.isLetter }.map(String.init)
        let heardTraditional = traditional.enumerated().map { TimedWord(text: $0.element, start: 0.1 + Double($0.offset) * step, end: 0.1 + Double($0.offset + 1) * step) }
        checkEqual(try SkyStudioVoiceSplit.slices(reverse, words: heardTraditional, samples: samples, sampleRate: 100).count, 3,
                   "a Simplified script heard in Traditional characters is split too")
        do {
            _ = try SkyStudioVoiceSplit.slices(batch, words: [TimedWord(text: "完全不相干的另外一段話而且很長很長很長", start: 0.1, end: 5.9)], samples: samples, sampleRate: 100)
            check(false, "unrelated Chinese speech must still be refused")
        } catch { check(true, "unrelated Chinese speech refused") }
    } catch { check(false, "script folding checks: \(error)") }

    checkEqual(AITextLanguage.speechLanguage("zh", texts: ["歡迎來到這門課程。", "今天我們學習剪輯影片。"]), "zh-Hant", "a Traditional script is transcribed as zh-Hant")
    checkEqual(AITextLanguage.speechLanguage("zh", texts: ["欢迎来到这门课程。", "今天我们学习剪辑视频。"]), "zh", "a Simplified script stays zh")
    checkEqual(AITextLanguage.speechLanguage("zh", texts: ["你好", "今天好"]), "zh", "characters written the same in both scripts stay zh")
    checkEqual(AITextLanguage.speechLanguage("zh", texts: ["SkyCut 讓剪輯變簡單"]), "zh-Hant", "Latin letters do not hide the script")
    checkEqual(AITextLanguage.speechLanguage("ja", texts: ["歡迎"]), "ja", "only Chinese is split by script")
    checkEqual(AITextLanguage.speechLanguage("en", texts: ["Hello"]), "en", "other languages unchanged")
}

/// 100 Hz 的假声音：`sound` 里的那几段有声音（0.5），别处是静音。
private func audio(seconds: Double, sound: [ClosedRange<Double>]) -> [Float] {
    (0..<Int(seconds * 100)).map { index in sound.contains { $0.contains(Double(index) / 100) } ? 0.5 : 0 }
}

private func estimatedSplitChecks() {
    do {
        // 两句一样长：按字数估的句界在正中（3 秒前后）；真的停顿在 3.3–3.7 秒（估的位置晚了一点也找得到）。
        let two = try SkyStudioVoiceBatch.make(lines: ["One two three four.", "Five six seven eight."], limit: 800, pack: true)[0]
        let paused = audio(seconds: 6, sound: [0.2...3.3, 3.7...5.8])
        let cut = try SkyStudioVoiceSplitEstimate.slices(two, samples: paused, sampleRate: 100)
        checkEqual(cut.map(\.part.text), two.parts.map(\.text), "an estimated split keeps the lines in order")
        check(abs(cut[0].end - 3.5) < 0.03, "the cut snaps to the middle of the pause near the estimate (got \(cut[0].end))")
        check(cut[0].start == 0 && cut[0].end == cut[1].start && cut[1].end == 6, "no audio is lost or repeated")
        // 一点安静都没有：切在估的位置（两句的字一样多，正中附近）。
        let steady = audio(seconds: 6, sound: [0...6])
        let plain = try SkyStudioVoiceSplitEstimate.slices(two, samples: steady, sampleRate: 100)
        check(abs(plain[0].end - 3) < 0.4, "without any pause the cut is where the character counts put it (got \(plain[0].end))")
        // 句子里的短停顿（逗号）比句间的短：挑最长的那个安静窗。
        let comma = audio(seconds: 6, sound: [0.2...2.6, 2.7...3.2, 3.8...5.8])
        let longest = try SkyStudioVoiceSplitEstimate.slices(two, samples: comma, sampleRate: 100)
        check(abs(longest[0].end - 3.5) < 0.03, "the longest pause in reach wins over a shorter one (got \(longest[0].end))")
        // 很远的停顿不算：只在估的位置附近找。
        let far = audio(seconds: 6, sound: [0.2...0.8, 1.6...5.8])
        let near = try SkyStudioVoiceSplitEstimate.slices(two, samples: far, sampleRate: 100)
        check(near[0].end > 2, "a pause far from the estimate is not taken for the line break (got \(near[0].end))")
        // 一长一短：句界跟着字数走。
        let uneven = try SkyStudioVoiceBatch.make(lines: ["One two three four five six seven eight nine ten.", "Go."], limit: 800, pack: true)[0]
        let unevenCut = try SkyStudioVoiceSplitEstimate.slices(uneven, samples: steady, sampleRate: 100)
        check(unevenCut[0].end > 4.5, "the long line gets most of the audio (got \(unevenCut[0].end))")
        // 四句：一刀比一刀晚，每句都有声音。
        let four = try SkyStudioVoiceBatch.make(lines: ["你好。", "今天天气很好。", "我们开始吧。", "再见。"], limit: 800, pack: true)[0]
        let fourCut = try SkyStudioVoiceSplitEstimate.slices(four, samples: steady, sampleRate: 100)
        check(fourCut.count == 4 && fourCut.allSatisfy { $0.end - $0.start >= SkyStudioVoiceSplitEstimate.minimumPiece }
              && zip(fourCut, fourCut.dropFirst()).allSatisfy { $0.end == $1.start } && fourCut.last?.end == 6,
              "four lines: increasing cuts, every line keeps some audio")
        // 只有标点的一句也有自己的一小段，不让别的句子错位。
        let dots = try SkyStudioVoiceBatch.make(lines: ["Hello there.", "……", "Good night."], limit: 800, pack: true)[0]
        checkEqual(try SkyStudioVoiceSplitEstimate.slices(dots, samples: steady, sampleRate: 100).count, 3, "a punctuation-only line still gets a slice")
        let single = try SkyStudioVoiceBatch.make(lines: ["Only line."], limit: 800, pack: true)[0]
        let whole = try SkyStudioVoiceSplitEstimate.slices(single, samples: steady, sampleRate: 100)
        check(whole.count == 1 && whole[0].start == 0 && whole[0].end == 6, "a one-line batch is the whole file")
        do {
            _ = try SkyStudioVoiceSplitEstimate.slices(four, samples: [Float](repeating: 0.5, count: 10), sampleRate: 100)
            check(false, "audio too short to give every line a piece must be refused")
        } catch { check(true, "audio too short for its lines refused") }
    } catch { check(false, "estimated split checks: \(error)") }
}

private func batchLimitChecks() {
    guard let catalog = loadVoiceFixture()?.catalog else { return check(false, "the voice catalog fixture loads") }
    for kind in ["voice", "voice_clone"] {
        checkEqual(catalog.voiceCharacterLimit(kind: kind, text: "Hello world."), 800, "\(kind): Latin text takes the other-languages limit")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, text: "今天天气很好。"), 300, "\(kind): Han text takes the Chinese limit")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, text: "こんにちは"), 330, "\(kind): kana takes the Japanese limit")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, text: "今日は天気がいい"), 300, "\(kind): kana with Han takes the smaller of the two")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, text: "안녕하세요"), 300, "\(kind): Hangul takes the Korean limit")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, text: "Welcome to 上海."), 300, "\(kind): mixed text takes the smallest limit present")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, text: "2026!"), 800, "\(kind): no letters at all takes the other-languages limit")
    }
    checkEqual(catalog.voiceCharacterLimit(kind: "voice_convert", text: "你好"), nil, "no limit written: nil")
    do {
        // 英文为主、夹一行 350 字的中文：整稿的主要语言是英文（上限 800），服务器却按那一批自己的语言卡（中文 300）。
        let chinese = String(repeating: "今天我们学习剪辑视频，", count: 31) + "好的。"
        let english = "This is the first line of an English script that is clearly the main language of the whole text."
        let reading = SkyStudioVoiceReading(model: "auto", packs: true, timing: nil, transcribes: true, switchedForTiming: false)
        let draft = try SkyStudioVoicePlan.draft(lines: [english, chinese, english, english], kind: "voice", voice: "gemini:Charon",
                                                 reading: reading, language: "en", catalog: catalog)
        check(chinese.unicodeScalars.count > 300 && chinese.unicodeScalars.count <= 800, "the Chinese line is over the Chinese limit, under the English one")
        check(draft.speech.allSatisfy { batch in
            batch.prompt.unicodeScalars.count <= (catalog.voiceCharacterLimit(kind: "voice", text: batch.prompt) ?? 0)
        }, "every batch fits the limit of the scripts it contains (got \(draft.speech.map { $0.prompt.unicodeScalars.count }))")
        check(draft.speech.flatMap(\.parts).filter { $0.line == 1 }.count == 2, "the long Chinese line is split at a sentence end into two parts")
        checkEqual(draft.speech.flatMap(\.parts).filter { $0.line == 1 }.map(\.text).joined(), chinese, "nothing of the line is lost")
        // 纯英文的稿子照旧 800 一批。
        let plain = try SkyStudioVoicePlan.draft(lines: [String](repeating: english, count: 8), kind: "voice", voice: "gemini:Charon",
                                                 reading: reading, language: "en", catalog: catalog)
        checkEqual(plain.speech.count, 1, "an all-English script still packs up to 800 characters")
        // 一批里装了中文之后，后面的英文也照这一批里最小的上限装。
        let mixed = try SkyStudioVoiceBatch.make(lines: [String(repeating: "好", count: 200), String(repeating: "a", count: 150)], pack: true) {
            catalog.voiceCharacterLimit(kind: "voice", text: $0) ?? 0
        }
        checkEqual(mixed.count, 2, "a batch that holds Chinese keeps the Chinese limit for the lines packed after it")
    } catch { check(false, "batch limit checks: \(error)") }
}
