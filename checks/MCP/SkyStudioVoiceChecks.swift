import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// add_voiceover 的名片和说明书主题该写的话、参数名、本机这一档挑谁、词时间；参考录音（挑段、44.1 kHz 的 WAV）在 VoiceReferenceChecks。
// 名片的上限、按性质的固定说法、参数说明的长度和范围、主题的分节 / 例子 / 只提真有的名字，和试点的五个工具一起在 GuidePilotChecks。
// Sky Studio 那一档认声音（SkyStudioVoicePick：默认 gemini:Charon、角色只认 voice_roles……）对着目录快照在 check-sky-studio 的
// VoicePickChecks；整段报价、预留、退本机、起任务在 check-voice-recovery（真 App 对象）。

func runSkyStudioVoiceChecks() {
    voiceoverGuideChecks()
    voiceLibraryGuideChecks()
    voiceChangeGuideChecks()
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
    for phrase in ["recordings: add_clips", "default gemini:Charon", "voice_… (list_voices)", "Returns job_id; wait with get_job", "relay voice.note",
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
                   "Rachel are not voices", "sync_voiceover", "voice_…", "skip_one_time=true", "voice_enroll", "voice_library_unavailable",
                   "index-tts-2",
                   // 声音 PR 4：几批同时交、中途换备用（声音方案 8.2、8.4）。
                   "several at once", "batches_waiting", "line_models", "batches sent after that use the fallback too",
                   "fallback_needs_one_time",
                   // 声音 PR 7：全部权限下有长期授权就不问、直接建，结果带 full_access；没有就问一次、点过头记上。
                   "standing voice consent on record", "builds it without asking", "enroll_job_id", "agreeing records the consent"] {
        check(text.contains(phrase), "the add_voiceover topic says \"\(phrase)\"")
    }
    // 字幕时间（声音 PR 5，声音方案第七节）：四种 subtitle_timing、估出来的要转告、模型没装先装、转写不了的预设整段换 eleven-v4、
    // 估出来的那几句列在哪；合批只在两句之间分（8.1）。
    let subtitles = topic.sections.first { $0.name == "subtitles" }?.text ?? ""
    for phrase in ["subtitle_timing", "provider", "aligned", "estimated", "mixed", "half a second", "tell the user", "local_step",
                   "before anything is paid", "eleven-v4", "estimated_line_indices", "script's own words"] {
        check(subtitles.contains(phrase), "the add_voiceover subtitles section says \"\(phrase)\"")
    }
    let batches = topic.sections.first { $0.name == "batches_recovery" }?.text ?? ""
    check(batches.contains("only breaks between lines") && batches.contains("sentence ends"),
          "the batches section says batches break only between lines, long lines at sentence ends")
    let subtitlesField = definition.inputSchema["properties"]?["subtitles"]?["description"]?.stringValue ?? ""
    check(subtitlesField.contains("subtitle_timing"), "the subtitles parameter points at subtitle_timing: \(subtitlesField)")
}

/// 声音库的两个工具（声音 PR 6，SkyCut 声音方案 4.6、4.10）：参数名、名片必含、说明书必含、地图；动作词表就是 App 分派的那几样。
private func voiceLibraryGuideChecks() {
    check(MCPArgumentCheck.problem(tool: .listVoices, arguments: ["language": "en", "include": "presets"]) == nil, "list_voices takes language and include")
    check(MCPArgumentCheck.problem(tool: .manageVoices, arguments: [
        "action": "create", "file": "a.m4a", "start": 0, "end": 30, "language": "zh", "name": "Sky", "confirm_token": "t"
    ]) == nil, "manage_voices create takes file, start, end, language, name and confirm_token")
    check(MCPArgumentCheck.problem(tool: .manageVoices, arguments: ["action": "design", "description": "calm", "name": "Calm", "sample_text": "Hi."]) == nil,
          "manage_voices design takes description, name and sample_text")
    check(MCPArgumentCheck.problem(tool: .manageVoices, arguments: ["action": "delete", "voice": "voice_x", "model": "auto"]) != nil,
          "manage_voices does not take model")
    check(MCPArgumentCheck.problem(tool: .addVoiceover, arguments: ["lines": [["text": "Hi."]], "voice": "voice_x", "skip_one_time": true]) == nil,
          "add_voiceover takes skip_one_time")
    checkEqual(MCPToolName.manageVoices.definition.inputSchema["properties"]?["action"]?["enum"],
               .array(["create", "add_reference", "design", "rename", "delete"]), "manage_voices actions are the five the App handles")
    checkEqual(MCPToolName.listVoices.definition.inputSchema["properties"]?["include"]?["enum"], .array(["mine", "presets", "all"]),
               "list_voices include is mine, presets or all")
    check(MCPToolName.listVoices.definition.readOnly && !MCPToolName.manageVoices.definition.readOnly && MCPToolName.manageVoices.definition.destructive,
          "list_voices is read-only; manage_voices writes and can delete")

    let list = MCPToolName.listVoices.definition.description
    for phrase in ["Read-only, free", "voice_…", "gemini:Name", "Pass language", "presets still come back"] {
        check(list.contains(phrase), "the list_voices card says \"\(phrase)\"")
    }
    let manage = MCPToolName.manageVoices.definition.description
    for phrase in ["no timeline change, no undo", "create from a recording", "add_reference", "design: Paid (Sky Studio credits), one-time",
                   "Returns job_id; wait with get_job", "The daily credit limit always applies",
                   "Ask mode: create, add_reference, design and delete return needs_confirmation first", "full access proceeds",
                   "Read skycut_guide topic=manage_voices before the first call."] {
        check(manage.contains(phrase), "the manage_voices card says \"\(phrase)\"")
    }
    let listTopic = MCPGuideTopics.topic(for: .listVoices)
    checkEqual(listTopic.sections.map(\.name), ["overview", "mine", "presets", "pitfalls", "fields"], "the list_voices topic has its sections, fields last")
    let listText = listTopic.sections.map(\.text).joined(separator: "\n")
    for phrase in ["at most 50 voices", "minimax", "gemini:Charon", "returns the English one", "voice_library_unavailable", "Never invent a voice_… id"] {
        check(listText.contains(phrase), "the list_voices topic says \"\(phrase)\"")
    }
    let manageTopic = MCPGuideTopics.topic(for: .manageVoices)
    checkEqual(manageTopic.sections.map(\.name), ["overview", "create", "design", "rename_delete", "permission_modes", "pitfalls", "fields"],
               "the manage_voices topic has the sections of voice plan 4.10, fields last")
    let manageText = manageTopic.sections.map(\.text).joined(separator: "\n")
    for phrase in ["consent statement", "confirm_token", "at least 10 seconds", "3 minutes", "reference_exists", "voice_limit", "voice_design",
                   "sample_url", "cannot be reversed", "delete happens directly", "voice_library_unavailable",
                   // 声音 PR 7：全部权限 + 长期授权什么都不问、结果带 full_access；没有长期授权第一次照请求批准模式问一次、点过头记上。
                   "standing voice consent on record", "nothing asks", "full_access", "asks once like ask mode", "agreeing records it"] {
        check(manageText.contains(phrase), "the manage_voices topic says \"\(phrase)\"")
    }
    check(!manageText.contains("750") && !manageText.contains("22.5"), "the design section names no prices: they come from Sky Studio's quote")
    let map = guideMapText()
    check(map.contains("Voices: list_voices (presets, my voices), manage_voices ("), "the guide map has a Voices line with both tools")
    check(map.contains("manage_voices (design;") && map.contains("list_voices"), "the paid line names manage_voices' design and lists list_voices as free")
}

/// 变声（声音 PR 9，SkyCut 声音方案 4.8、4.10）：参数名、名片必含、说明书必含、地图。只判每日硬预算：不收 confirm_token。
private func voiceChangeGuideChecks() {
    let definition = MCPToolName.changeVoice.definition
    check(MCPArgumentCheck.problem(tool: .changeVoice, arguments: ["clip_id": "c1", "voice": "voice_x", "language": "en", "project": "p1"]) == nil,
          "change_voice takes clip_id, voice, language and project")
    check(MCPArgumentCheck.problem(tool: .changeVoice, arguments: ["clip_id": "c1", "voice": "voice_x", "confirm_token": "t"]) != nil,
          "change_voice never asks, so it takes no confirm_token")
    check(MCPArgumentCheck.problem(tool: .changeVoice, arguments: ["clip": "c1", "voice": "voice_x"]) != nil,
          "the clip parameter is clip_id, like every other tool")
    checkEqual(definition.inputSchema["required"], .array(["clip_id", "voice"]), "change_voice requires the clip and the voice")
    check(!definition.readOnly && !definition.destructive && definition.openWorld, "change_voice writes, deletes nothing and reaches Sky Studio")
    check(MCPToolName.changeVoice.takesProject, "change_voice lands on a project, so it takes project")
    checkEqual(MCPToolName.changeVoice.provider, .skystudio, "change_voice belongs to Sky Studio")
    let card = definition.description
    for phrase in ["Paid (Sky Studio credits)", "Returns job_id; wait with get_job", "two new linked audio tracks", "original clip is muted",
                   "One undo step", "The daily credit limit always applies", "Read skycut_guide topic=change_voice before the first call."] {
        check(card.contains(phrase), "the change_voice card says \"\(phrase)\"")
    }
    check(!card.contains("needs_confirmation"), "the change_voice card promises no question: the daily limit is the only gate")
    let topic = MCPGuideTopics.topic(for: .changeVoice)
    checkEqual(topic.sections.map(\.name), ["overview", "cost_and_limits", "result", "language", "pitfalls", "fields"],
               "the change_voice topic has its sections, fields last")
    let text = topic.sections.map(\.text).joined(separator: "\n")
    for phrase in ["list_voices mine", "untested", "daily_budget_exceeded", "split_clip", "muted, not deleted", "one undo step",
                   "voice_clip_id", "background_clip_id", "landed is false", "ISO 639-1", "target_language", "check get_job first",
                   "voice_library_unavailable"] {
        check(text.contains(phrase), "the change_voice topic says \"\(phrase)\"")
    }
    check(!text.contains("5 minutes") && !text.contains("300"), "the topic names no source limit: it comes from Sky Studio's catalog")
    let map = guideMapText()
    check(map.contains("change_voice (re-voice a clip, dub it in my voice)"), "the guide map's Voices line lists change_voice")
    check(map.contains("change_voice (re-voice a clip);"), "the paid line names change_voice")
    let paid = MCPGuideTopics.topic(named: "paid")?.sections.map(\.text).joined(separator: "\n") ?? ""
    check(paid.contains("change_voice"), "the paid topic lists change_voice")
}
