import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// add_voiceover 的名片和说明书主题该写的话、参数名、本机这一档挑谁、词时间；参考录音（挑段、44.1 kHz 的 WAV）在 VoiceReferenceChecks。
// 名片的上限、按性质的固定说法、参数说明的长度和范围、主题的分节 / 例子 / 只提真有的名字，和试点的五个工具一起在 GuidePilotChecks。
// Sky Studio 那一档认声音（SkyStudioVoicePick：默认 gemini:Charon、角色只认 voice_roles……）对着目录快照在 check-sky-studio 的
// VoicePickChecks；整段报价、预留、退本机、起任务在 check-voice-recovery（真 App 对象）。

func runSkyStudioVoiceChecks() {
    voiceoverGuideChecks()
    check(MCPArgumentCheck.problem(tool: .addVoiceover, arguments: ["resume": "/voiceover/recovery.json", "generate_missing": true]) == nil,
          "the existing voiceover tool accepts recovery arguments without original lines")
    check(MCPArgumentCheck.problem(tool: .addVoiceover, arguments: ["resume": "/voiceover/recovery.json", "regenerate_all": true]) != nil,
          "recovery does not weaken unknown-argument rejection")
    // 读别处的恢复文件会回 needs_confirmation：点过头之后带着 confirm_token 再调，参数核对不能把它挡掉（2026-11-10 案例）。
    check(MCPArgumentCheck.problem(tool: .addVoiceover, arguments: ["resume": "/voiceover/recovery.json", "confirm_token": "t"]) == nil,
          "an answered needs_confirmation comes back with confirm_token and is accepted")
    check(MCPArgumentCheck.problem(tool: .addVoiceover, arguments: ["lines": [["text": "Hi."]], "voice": "gemini:Charon", "model": "auto"]) == nil,
          "model is a parameter of add_voiceover")
    // 克隆一律先进声音库（决定第七节第 8 条）：clone_from 那三个当成说明上没有的参数名，整个调用不做。
    for removed in ["clone_from", "clone_start", "clone_seconds"] {
        check(MCPArgumentCheck.problem(tool: .addVoiceover, arguments: ["lines": [["text": "Hi."]], removed: "x"]) != nil,
              "\(removed) is no longer accepted")
    }
    let tingting = AIVoiceChoice.Voice(identifier: "com.apple.voice.1.zh-CN.Tingting", name: "Tingting", language: "zh-CN", gender: .female, quality: 1)
    let daniel = AIVoiceChoice.Voice(identifier: "com.apple.voice.1.en-GB.Daniel", name: "Daniel", language: "en-GB", gender: .male, quality: 1)
    let installed = [tingting, daniel]

    func chosen(_ requested: String?, language: String, kokoro: [String]? = nil) -> AIVoiceChoice.Engine? {
        (try? AIVoiceChoice.choose(requested, textLanguage: language, kokoroVoices: kokoro, installed: installed))?.engine
    }

    // 本机这一档：点名 Kokoro 的、这台 Mac 的照点名；角色用它的声音；不点名用旁白角色（中英文男声，和 Sky Studio 的默认同一个人设）。
    checkEqual(chosen("af_heart", language: "en", kokoro: ["af_heart"]), .kokoro(voice: "af_heart", language: "en"), "a named SkyCut voice is used")
    if case .system(let voice)? = chosen("Tingting", language: "zh") {
        checkEqual(voice.name, "Tingting", "a named Mac voice is used")
    } else {
        check(false, "a named Mac voice should stay a Mac voice")
    }
    if case .system(let voice)? = chosen("Daniel", language: "en") {
        checkEqual(voice.name, "Daniel", "Daniel is this Mac's voice (the old Eleven name is gone)")
    } else {
        check(false, "a name is looked up on this Mac")
    }
    checkEqual(chosen("en_male", language: "en", kokoro: ["am_fenrir"]), .kokoro(voice: "am_fenrir", language: "en"), "a role uses SkyCut's voice when it is downloaded")
    let plain = try? AIVoiceChoice.choose(nil, textLanguage: "zh", kokoroVoices: nil, installed: installed)
    checkEqual(plain?.name, "Tingting", "no voice named in Chinese: the narrator is male, and only a female Chinese voice is installed")
    check(plain?.note?.contains("No male Chinese voice") == true, "so the note says the male narrator was not available")
    checkEqual((try? AIVoiceChoice.choose(nil, textLanguage: "en", kokoroVoices: nil, installed: installed))?.name, "Daniel",
               "no voice named in English: the male narrator")
    check(chosen("Rachel", language: "en", kokoro: ["af_heart"]) == nil, "an old bare Eleven name is not a voice any more")
    check(AIVoiceChoice.isInstalled("daniel", in: installed) && !AIVoiceChoice.isInstalled("Charon", in: installed),
          "a bare name is looked up among this Mac's voices, any case")

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

/// add_voiceover 的「名片必含」和「说明书必含」（MCP 按需说明方案 5.2；声音方案 4.10、2.6：不知道就会调错、花错钱的留在名片）。
private func voiceoverGuideChecks() {
    let definition = MCPToolName.addVoiceover.definition
    let card = definition.description
    for phrase in ["recordings: add_clips", "default gemini:Charon", "Returns job_id; wait with get_job", "relay voice.note",
                   "The daily credit limit always applies", "resume=recovery_file, never resend lines",
                   "Read skycut_guide topic=add_voiceover before the first call."] {
        check(card.contains(phrase), "the add_voiceover card says \"\(phrase)\"")
    }
    check(!card.contains("Rachel") && !card.contains("clone_from"), "the card no longer offers old Eleven names or clone_from")
    // Codex 不显示范围：语速只对本机的声音有效，范围要写成数字（GuidePilotChecks 只查有没有数字，「1 = normal」也算）。
    let speed = definition.inputSchema["properties"]?["speed"]?["description"]?.stringValue ?? ""
    check(speed.contains("0.5 to 2"), "speed spells out its range: \(speed)")
    check(guideMapText().contains("add_voiceover (Sky Studio voices; SkyCut and Mac voices are free)"),
          "the guide map's paid line names add_voiceover's Sky Studio voices")
    let topic = MCPGuideTopics.topic(for: .addVoiceover)
    checkEqual(topic.sections.map(\.name),
               ["overview", "voices", "models_languages", "paid_confirmation", "subtitles", "batches_recovery", "local_voices", "pitfalls", "fields"],
               "the add_voiceover topic has the sections of voice plan 4.10, fields last")
    let text = topic.sections.map(\.text).joined(separator: "\n")
    for phrase in ["gemini:Charon", "eleven:Name", "en_male_british", "voice_plan", "cross_language", "daily_budget_exceeded",
                   "recharge_url", "confirm_token", "recovery_file", "generate_missing", "eleven-v4", "download_voices=true",
                   "Rachel are not voices", "sync_voiceover",
                   // 声音 PR 4：几批同时交、中途换备用（声音方案 8.2、8.4）。
                   "several at once", "batches_waiting", "line_models", "batches sent after that use the fallback too",
                   "fallback_needs_one_time"] {
        check(text.contains(phrase), "the add_voiceover topic says \"\(phrase)\"")
    }
}
