import Foundation
import SrtFlowMCPKit

// 声音库界面里的纯值（声音 PR 8，SkyCut 声音方案 5.1–5.3）：
// - 选择器列什么（VoicePickerRows）：三组的顺序（我的、设计的、预设排最后）、预设只列这种语言 listed 的且和 list_voices 同一个顺序、
//   性别和说明按这一排的语言取（Gacrux 中英文不是一个人）、说明按界面语言挑（中文界面 zh，英文和西语界面 en）、「其他语言」照英文那份、
//   默认的标出来、默认先看哪一排、我的声音试听哪种语言的那一段；
// - 「新建」为什么还灰着（NewVoiceGate）：一次只说最要紧的一样，顺序固定；加录音时不问名字、不数上限、已有的语言不让加；
// - 服务器的错误是哪一种（SkyStudioVoiceLibraryErrors.kind）：界面上的话和给 AI 的英文从同一份分法来。

@MainActor
func runVoiceLibraryUIChecks() {
    pickerChecks()
    gateChecks()
    errorKindChecks()
}

private func catalogFixture() -> SkyStudioVoiceCatalog? {
    let data = FileManager.default.contents(atPath: "checks/SkyStudio/Fixtures/models-voice-2026-11-10.json") ?? Data()
    return (try? JSONValue.decode(data)).flatMap(SkyStudioVoiceCatalog.init(json:))
}

private func voice(_ digit: String, _ name: String, _ languages: [String], source: String = "recording") -> SkyStudioVoice {
    let json: JSONValue = [
        "id": .string("voice_" + String(repeating: digit, count: 32)), "name": .string(name), "source": .string(source),
        "languages": .array(languages.map { ["language": .string($0), "kind": "recording", "minimax": false] })
    ]
    return try! SkyStudioVoice(json: json)
}

private func pickerChecks() {
    guard let catalog = catalogFixture() else { return check(false, "the voice catalog fixture reads") }
    let voices = [voice("1", "Sky", ["zh", "en"]), voice("2", "Designed one", ["en"], source: "design"), voice("3", "Guest", ["ja"])]
    let zh = VoicePickerRows.sections(catalog: catalog, voices: voices, tab: .chinese, uiLanguage: "zh-Hans")
    checkEqual(zh.map(\.kind), [.mine, .designed, .preset], "the picker lists my voices, designed voices, then presets last")
    checkEqual(zh[0].rows.map(\.name), ["Sky", "Guest"], "recorded voices are mine, in the library's order")
    checkEqual(zh[1].rows.map(\.name), ["Designed one"], "designed voices have their own group")
    checkEqual(zh[2].rows.map(\.id), catalog.listed(language: "zh").map(\.id), "presets are the language's listed ones, in list_voices' order")
    check(zh[2].rows.count == 23 && VoicePickerRows.presets(catalog, tab: .english, uiLanguage: "en").count == 28,
          "the snapshot lists 23 Chinese and 28 English presets")
    checkEqual(zh[2].rows.filter(\.isDefault).map(\.id), ["gemini:Charon"], "only the default preset is marked")
    check(zh[2].rows.allSatisfy { $0.sampleURL?.absoluteString.hasSuffix("-zh.wav") == true }, "Chinese rows play the Chinese samples")
    let en = VoicePickerRows.presets(catalog, tab: .english, uiLanguage: "en")
    check(en.allSatisfy { $0.sampleURL?.absoluteString.hasSuffix("-en.wav") == true }, "English rows play the English samples")
    let gacrux = { (rows: [VoicePickerRow]) in rows.first { $0.id == "gemini:Gacrux" } }
    if let a = gacrux(zh[2].rows), let b = gacrux(en) {
        check(a.gender != b.gender, "a preset's gender is the one for the tab's language (Gacrux differs between zh and en)")
    }
    let charon = { (rows: [VoicePickerRow]) in rows.first { $0.id == "gemini:Charon" }?.detail }
    let entry = catalog.preset("gemini:Charon")?.entry(for: "zh")
    checkEqual(charon(zh[2].rows), entry?.description["zh"], "a Chinese interface shows the zh description")
    checkEqual(charon(VoicePickerRows.presets(catalog, tab: .chinese, uiLanguage: "es")), entry?.description["en"],
               "a Spanish interface shows the en description")
    checkEqual(charon(VoicePickerRows.presets(catalog, tab: .chinese, uiLanguage: "en")), entry?.description["en"],
               "an English interface shows the en description")
    let other = VoicePickerRows.presets(catalog, tab: .other, uiLanguage: "en")
    checkEqual(other.map(\.id), en.map(\.id), "other languages use the English list")
    checkEqual(other.first?.sampleURL, en.first?.sampleURL, "and its English samples")
    check(VoicePickerRows.presets(nil, tab: .english, uiLanguage: "en").isEmpty, "no catalog, no presets")
    checkEqual(VoicePickerTab.initial(uiLanguage: "zh-Hans"), .chinese, "a Chinese interface starts on the Chinese tab")
    checkEqual(VoicePickerTab.initial(uiLanguage: "en"), .english, "an English interface starts on English")
    checkEqual(VoicePickerTab.initial(uiLanguage: "es"), .english, "a Spanish interface starts on English")
    checkEqual(zh[0].rows.map(\.previewLanguage), ["zh", "ja"], "my voice previews the tab's language when it has one, else its first")
    checkEqual(VoicePickerRows.sections(catalog: catalog, voices: voices, tab: .english, uiLanguage: "en")[0].rows.first?.previewLanguage, "en",
               "on the English tab the same voice previews its English recording")
    checkEqual(zh[0].rows.first?.languages, ["zh", "en"], "a library row says which languages it has")
    check(zh[0].rows.allSatisfy { $0.sampleURL == nil }, "library previews are fetched when played, never listed")
}

private func gateChecks() {
    func gate(available: Bool = true, name: String = "Sky", count: Int = 3, taken: [String]? = nil, sample: Bool = true,
              language: String? = "zh", agreed: Bool = true, busy: Bool = false) -> NewVoiceGate.Blocker? {
        NewVoiceGate.blocker(available: available, name: name, voiceCount: count, addingTo: taken, hasSample: sample, language: language,
                             agreed: agreed, busy: busy)
    }
    checkEqual(gate(), nil, "a named voice with a sample, a language and the consent can be created")
    checkEqual(gate(agreed: false), .consent, "without the consent box it cannot")
    checkEqual(gate(sample: false, agreed: false), .recording, "the recording is asked for before the consent")
    checkEqual(gate(language: nil), .language, "the language must be chosen")
    checkEqual(gate(language: "Chinese"), .language, "and be an ISO 639-1 code")
    checkEqual(gate(name: "  "), .name, "an empty name blocks creating")
    checkEqual(gate(name: String(repeating: "声", count: 81)), .name, "a name is at most 80 characters")
    checkEqual(gate(name: String(repeating: "声", count: 80)), nil, "80 characters is fine")
    checkEqual(gate(count: 50), .tooManyVoices(limit: 50), "a full library (50 voices) blocks creating")
    checkEqual(gate(count: 49), nil, "49 voices leaves room for one more")
    checkEqual(gate(available: false, count: 50), .unavailable, "an unavailable library comes first")
    checkEqual(gate(busy: true), .busy, "while sending, the button stays off")
    checkEqual(gate(name: "", count: 50, taken: ["en"]), nil, "adding a recording needs no name and is not counted against the limit")
    checkEqual(gate(taken: ["zh"]), .languageTaken("zh"), "a voice takes one recording per language")
    checkEqual(gate(taken: ["zh"], sample: false), .recording, "the recording still comes first when adding")
}

private func errorKindChecks() {
    func server(_ status: Int, _ code: String, _ fields: [String: JSONValue] = [:]) -> SkyStudioFailure {
        .server(SkyStudioServerError(status: status, code: code, message: "Sky Studio says \(code).", fields: fields))
    }
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(503, "voice_library_unavailable", ["reason": "not_configured"])), .unavailable,
               "an unconfigured voice bucket is the unavailable library")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(503, "voice_library_unavailable", ["reason": "storage_unavailable"])), .storageUnavailable,
               "a storage failure while deleting is its own kind")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(409, "voice_limit", ["limit": 50])), .voiceLimit(limit: "50"), "voice_limit carries the limit")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(409, "reference_exists", ["language": "zh"])), .referenceExists(language: "zh"),
               "reference_exists carries the language code")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(400, "invalid_request", ["reason": "too_little_speech", "limit": 10])),
               .tooLittleSpeech(limit: "10"), "too_little_speech carries the minimum")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(400, "invalid_request", ["reason": "consent_outdated"])), .consent,
               "the three consent reasons are one kind")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(400, "invalid_request", ["reason": "something_new"])), .refused("Sky Studio says invalid_request."),
               "another invalid_request keeps the server's words")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(server(402, "insufficient_credits")), nil, "codes outside the voice library are not classified")
    checkEqual(SkyStudioVoiceLibraryErrors.kind(SkyStudioVoiceRequestProblem(message: "x")), nil, "nor are local problems")
    // 给 AI 的英文仍从同一份分法来（原来的话一字没变）。
    check(SkyStudioVoiceLibraryErrors.message(server(409, "voice_limit", ["limit": 50])).contains("at most 50 voices"), "the AI message still names the limit")
    check(SkyStudioVoiceLibraryErrors.message(server(409, "reference_exists", ["language": "zh"])).contains("recording in Chinese"),
          "and the language by its English name")
}
