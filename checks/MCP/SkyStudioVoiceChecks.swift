import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 云端选声、词时间和参考 WAV；服务合同和任务测试在 check-sky-studio。

func runSkyStudioVoiceChecks() {
    let tingting = AIVoiceChoice.Voice(identifier: "com.apple.voice.1.zh-CN.Tingting", name: "Tingting", language: "zh-CN", gender: .female, quality: 1)
    let daniel = AIVoiceChoice.Voice(identifier: "com.apple.voice.1.en-GB.Daniel", name: "Daniel", language: "en-GB", gender: .male, quality: 1)
    let installed = [tingting, daniel]

    func chosen(_ requested: String?, language: String, fal: Bool, kokoro: [String]? = nil) -> AIVoiceChoice.Engine? {
        (try? AIVoiceChoice.choose(requested, textLanguage: language, kokoroVoices: kokoro, installed: installed, skyStudioAvailable: fal))?.engine
    }

    // fal 可用：没点名按文字的语言取温和的角色、点名角色换成对应音色、点名 ElevenLabs 的音色照用（大小写不敏感）
    checkEqual(chosen(nil, language: "en", fal: true), .skyStudio(voice: "Rachel"), "no voice named, English: the warm English role's voice")
    checkEqual(chosen(nil, language: "zh", fal: true), .skyStudio(voice: "Sarah"), "no voice named, Chinese: the warm Chinese role's voice")
    checkEqual(chosen(nil, language: "ja", fal: true), .skyStudio(voice: "Rachel"), "a language without a role: the default voice")
    checkEqual(chosen("en_male", language: "en", fal: true), .skyStudio(voice: "Brian"), "a role becomes its Sky Studio voice")
    checkEqual(chosen("ZH_MALE", language: "zh", fal: true), .skyStudio(voice: "Eric"), "roles are case-insensitive")
    checkEqual(chosen("brian", language: "en", fal: true), .skyStudio(voice: "Brian"), "an ElevenLabs premade voice is used as named, in its own spelling")
    // 点名 Kokoro 的、这台 Mac 的：仍照点名（fal 不抢）
    checkEqual(chosen("af_heart", language: "en", fal: true, kokoro: ["af_heart"]), .kokoro(voice: "af_heart", language: "en"), "a named SrtFlow voice is still used")
    if case .system(let voice)? = chosen("Tingting", language: "zh", fal: true) {
        checkEqual(voice.name, "Tingting", "a named Mac voice is still used")
    } else {
        check(false, "a named Mac voice should stay a Mac voice")
    }
    // 名字撞了（Daniel 既是 ElevenLabs 的音色也是 Mac 的英式男声）：fal 可用时按 fal —— fal > 本机 > macOS
    checkEqual(chosen("Daniel", language: "en", fal: true), .skyStudio(voice: "Daniel"), "a name both fal.ai and this Mac have goes to fal.ai when it is available")
    // fal 不可用：和以前一模一样
    if case .system(let voice)? = chosen("Daniel", language: "en", fal: false) {
        checkEqual(voice.name, "Daniel", "without fal.ai, Daniel is the Mac's voice")
    } else {
        check(false, "without fal.ai a name is looked up on this Mac")
    }
    checkEqual(chosen("en_male", language: "en", fal: false, kokoro: ["am_fenrir"]), .kokoro(voice: "am_fenrir", language: "en"), "without fal.ai a role uses SrtFlow's voice when it is downloaded")
    let plain = try? AIVoiceChoice.choose(nil, textLanguage: "zh", kokoroVoices: nil, installed: installed)
    checkEqual(plain?.name, "Tingting", "the default parameter keeps the old behaviour")
    let cloudChoice = try? AIVoiceChoice.choose("en_male", textLanguage: "en", kokoroVoices: nil, installed: installed, skyStudioAvailable: true)
    checkEqual(cloudChoice?.name, "Brian", "the choice's name is the voice")
    checkEqual(cloudChoice?.qualityName, "Sky Studio voice", "and its quality says where it comes from")

    checkEqual(chosen("Rachel", language: "en", fal: false, kokoro: ["af_heart"]), .kokoro(voice: "af_heart", language: "en"), "a cloud preset without a key falls back to local narration")

    // 角色表和 AIVoiceRole 对账：每个角色都有音色、没有多出来的、音色都是 ElevenLabs 的预制音色
    checkEqual(Set(SkyStudioVoices.byRole.keys), Set(AIVoiceRole.all.map(\.name)), "every voice role has a Sky Studio voice, and no extra")
    check(SkyStudioVoices.byRole.values.allSatisfy { SkyStudioVoices.premade.contains($0) }, "every mapped voice is a premade voice fal.ai lists")
    checkEqual(SkyStudioVoices.premade.count, Set(SkyStudioVoices.premade).count, "no voice is listed twice")
    check(SkyStudioVoices.named("nobody") == nil && SkyStudioVoices.named("") == nil, "an unknown name is not a premade voice")
    checkEqual(SkyStudioVoices.named(" rachel "), "Rachel", "spaces around a name are ignored")

    // ---- 词时间
    let hello = [SpeechWordTime(text: "Hello", start: 0.1, end: 0.5), SpeechWordTime(text: "world.", start: 0.6, end: 1.0)]
    let words = SpeechWordTimes.timedWords(hello, text: "Hello world.", duration: 1.2)
    checkEqual(words.map(\.text), ["Hello", " world."], "English words keep the recogniser's spelling: a leading space after the first")
    checkEqual(words.map(\.start), [0.1, 0.6], "starts are kept")
    checkEqual(words.map(\.end), [0.5, 1.0], "ends are kept")
    let clamped = SpeechWordTimes.timedWords([SpeechWordTime(text: "a", start: 0.4, end: 9), SpeechWordTime(text: "b", start: 5, end: 6)], text: "a b", duration: 1)
    checkEqual(clamped.map(\.end), [1.0], "ends are clamped to audio and words starting past it are discarded")
    check(clamped.allSatisfy { $0.end <= 1.0 }, "no subtitle word extends past the audio")
    let chinese = SpeechWordTimes.timedWords(
        [SpeechWordTime(text: "你", start: 0, end: 0.2), SpeechWordTime(text: "好", start: 0.2, end: 0.4)], text: "你好", duration: 0.5
    )
    checkEqual(chinese.map(\.text), ["你", "好"], "Chinese characters get no spaces between them")
    check(SpeechWordTimes.timedWords(hello, text: "A completely different and much longer sentence.", duration: 1.2).isEmpty, "words that do not match the text are not trusted")
    check(SpeechWordTimes.timedWords(hello, text: "Hi", duration: 1.2).isEmpty, "words much longer than the text are not trusted either")
    check(SpeechWordTimes.timedWords([], text: "Hello", duration: 1).isEmpty && SpeechWordTimes.timedWords(hello, text: "Hello world.", duration: 0).isEmpty, "nothing to convert")
    check(SpeechWordTimes.timedWords(hello, text: "...", duration: 1).isEmpty, "a text without letters has nothing to match")

    // ---- 参考音频的 WAV
    let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
    let wav = VoiceReferenceSample.wavData(samples: samples, sampleRate: 16_000)
    checkEqual(wav.count, 44 + samples.count * 2, "a 44-byte header and the samples")
    checkEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF", "RIFF")
    checkEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ", "WAVE fmt")
    checkEqual(String(decoding: wav[36..<40], as: UTF8.self), "data", "data chunk")
    func le32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(wav[wav.startIndex + offset + $1]) << (8 * UInt32($1)) } }
    func le16(_ offset: Int) -> UInt16 { UInt16(wav[wav.startIndex + offset]) | UInt16(wav[wav.startIndex + offset + 1]) << 8 }
    checkEqual(le32(4), UInt32(36 + samples.count * 2), "the RIFF size")
    checkEqual(le16(20), 1, "PCM")
    checkEqual(le16(22), 1, "mono")
    checkEqual(le32(24), 16_000, "the sample rate")
    checkEqual(le32(28), 32_000, "bytes per second")
    checkEqual(le16(34), 16, "16 bits")
    checkEqual(le32(40), UInt32(samples.count * 2), "the data size")
    let back = (0..<samples.count).map { Int16(bitPattern: le16(44 + $0 * 2)) }
    checkEqual(back, samples, "the samples come back unchanged, including the extremes")
    checkEqual(VoiceReferenceSample.wavData(samples: [], sampleRate: 16_000).count, 44, "an empty sample is just a header")
}

func runSpeechParserChecks() {
    func raw(_ source: String) -> JSONValue {
        let json = try! JSONValue.decode(Data(source.utf8))
        return json["timestamps"] ?? .null
    }
    // ---- 词时间：三种写法
    let objects = SpeechWordTimes.parse(raw(#"{"timestamps":[{"word":"Hello","start":0.1,"end":0.5},{"word":"world.","start":0.6,"end":1.0}]}"#))
    checkEqual(objects, [SpeechWordTime(text: "Hello", start: 0.1, end: 0.5), SpeechWordTime(text: "world.", start: 0.6, end: 1.0)], "objects with word / start / end")
    let named = SpeechWordTimes.parse(raw(#"{"timestamps":[{"text":"你好","start_time":0.0,"end_time":0.4}]}"#))
    checkEqual(named, [SpeechWordTime(text: "你好", start: 0, end: 0.4)], "objects with text / start_time / end_time")
    let triples = SpeechWordTimes.parse(raw(#"{"timestamps":[["a",0,0.2],["b",0.3,0.5]]}"#))
    checkEqual(triples.map(\.text), ["a", "b"], "triples [text, start, end]")
    let alignment = SpeechWordTimes.parse(raw(
        #"{"timestamps":[{"characters":["H","i"," ","y","o"],"character_start_times_seconds":[0,0.1,0.2,0.3,0.4],"character_end_times_seconds":[0.1,0.2,0.3,0.4,0.5]}]}"#
    ))
    checkEqual(alignment, [SpeechWordTime(text: "Hi", start: 0, end: 0.2), SpeechWordTime(text: "yo", start: 0.3, end: 0.5)], "ElevenLabs' character alignment is grouped into words")
    let nested = SpeechWordTimes.parse(raw(
        #"{"timestamps":{"alignment":{"characters":["o","k"],"character_start_times_seconds":[0,0.1],"character_end_times_seconds":[0.1,0.2]}}}"#
    ))
    checkEqual(nested.map(\.text), ["ok"], "alignment nested in an object")
    let perCharacter = SpeechWordTimes.parse(raw(#"{"timestamps":[{"text":"o","start":0,"end":0.1},{"text":"k","start":0.1,"end":0.2},{"text":" ","start":0.2,"end":0.25},{"text":"y","start":0.25,"end":0.3}]}"#))
    checkEqual(perCharacter.map(\.text), ["ok", "y"], "one character per entry is grouped by spaces")

    let chinese = SpeechWordTimes.parse(raw(#"{"timestamps":[{"characters":["你","好"],"character_start_times_seconds":[0,0.2],"character_end_times_seconds":[0.2,0.4]}]}"#))
    checkEqual(chinese.map(\.text), ["你", "好"], "Chinese without spaces: one character per word")
    let single = SpeechWordTimes.parse(raw(#"{"timestamps":[{"characters":["H","e","l","l","o"],"character_start_times_seconds":[0,0.1,0.2,0.3,0.4],"character_end_times_seconds":[0.1,0.2,0.3,0.4,0.5]}]}"#))
    checkEqual(single.map(\.text), ["Hello"], "one Latin word reported by letter stays one word")
    let letters = SpeechWordTimes.parse(raw(#"{"timestamps":[{"word":"I","start":0,"end":0.1},{"word":"a","start":0.2,"end":0.3}]}"#))
    checkEqual(letters.map(\.text), ["I", "a"], "single-letter words are not glued together")

    // ---- 不像样的词时间一律当没有
    check(SpeechWordTimes.parse(raw(#"{"audio":{"url":"https://x.test/a.mp3"}}"#)).isEmpty, "no timestamps")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":null}"#)).isEmpty, "null timestamps")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":[]}"#)).isEmpty, "an empty list")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":[{"word":"a","start":1,"end":0.5}]}"#)).isEmpty, "a word that ends before it starts")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":[{"word":"a","start":1,"end":2},{"word":"b","start":0.5,"end":0.9}]}"#)).isEmpty, "words going backwards in time")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":[{"word":"a","start":-1,"end":2}]}"#)).isEmpty, "a negative start")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":[{"speaker":1}]}"#)).isEmpty, "entries in a shape SrtFlow does not know")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":"00:00:01"}"#)).isEmpty, "a string instead of a list")
    check(SpeechWordTimes.parse(raw(#"{"timestamps":[{"characters":["a"],"character_start_times_seconds":[0,1],"character_end_times_seconds":[1]}]}"#)).isEmpty, "alignment arrays of different lengths")
}
