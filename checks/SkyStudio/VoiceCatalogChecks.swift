import Foundation
import SrtFlowMCPKit

// 声音 PR 1（SkyCut 声音方案 9.1 第 1 项）：`/models` 里声音的那一部分，对着目录快照读。
// 快照：checks/SkyStudio/Fixtures/ 下最新的 models-voice-*.json。现在这一份（-draft-）是 SkyCut 按两份方案手写的临时样子，
// Sky Studio 导出正式快照（tests/fixtures/skycut/models-voice-*.json）后换成它，再对着它跑。
// 钉住：预设按语言分开（Gacrux 中文男 / 英文女）、名单只收 listed、中文 21 / 英文 27 / 藏 3、样音和 Eleven 备用、唯一的默认是 Charon；
// 8 个角色都在、都指向那种语言名单里的声音（Iapetus 只在英文名单）；一次性费用的价目、Eleven 支持的语言、分批的字数上限；
// DTO 和快照里没有服务商的 id。

let voiceFixturePath = "checks/SkyStudio/Fixtures/models-voice-draft-2026-11-10.json"

func loadVoiceFixture() -> (text: String, catalog: SkyStudioCatalog)? {
    guard let data = FileManager.default.contents(atPath: voiceFixturePath), let text = String(data: data, encoding: .utf8),
          let json = try? JSONValue.decode(data), let catalog = SkyStudioCatalog(json: json) else { return nil }
    return (text, catalog)
}

func runVoiceCatalogChecks() {
    guard let loaded = loadVoiceFixture(), let voices = loaded.catalog.voices else {
        check(false, "the voice catalog snapshot loads and has voice_presets")
        return
    }
    runPresetChecks(voices)
    runRoleChecks(voices)
    runVoiceModelChecks(loaded.catalog)
    runProviderIDChecks(loaded.text)
    check(SkyStudioCatalog(json: ["models": []])?.voices == nil, "a server without voices: no voice catalog, models still read")
}

private func runPresetChecks(_ voices: SkyStudioVoiceCatalog) {
    checkEqual(voices.presets.count, 30, "30 preset voices")
    checkEqual(voices.listed(language: "zh").count, 21, "21 on the Chinese list")
    checkEqual(voices.listed(language: "en").count, 27, "27 on the English list")
    let hidden = voices.presets.filter { $0.languages.values.allSatisfy { !$0.listed } }.map(\.name).sorted()
    checkEqual(hidden, ["Despina", "Enceladus", "Sadaltager"], "three hidden in both languages")
    checkEqual(voices.listed(language: "ja").map(\.id), voices.listed(language: "en").map(\.id), "other languages use the English list (other_languages)")

    let gacrux = voices.preset("gemini:Gacrux")
    checkEqual(gacrux?.entry(for: "zh")?.gender, "male", "Gacrux reads Chinese as a man")
    checkEqual(gacrux?.entry(for: "en")?.gender, "female", "Gacrux reads English as a woman")
    checkEqual(gacrux?.entry(for: "zh")?.listed, false, "Gacrux is not on the Chinese list")
    checkEqual(gacrux?.entry(for: "en")?.listed, true, "Gacrux is on the English list")
    check(gacrux?.entry(for: "zh")?.description != gacrux?.entry(for: "en")?.description, "descriptions are per language")
    checkEqual(gacrux?.entry(for: "es")?.gender, "female", "Spanish uses the English attributes")

    checkEqual(voices.presets.filter(\.isDefault).map(\.id), ["gemini:Charon"], "Charon is the only default")
    checkEqual(voices.defaultPreset?.id, "gemini:Charon", "the default preset")
    for preset in voices.presets {
        check(preset.id == "gemini:" + preset.name, "\(preset.name): the id is gemini:<name>")
        for language in ["zh", "en"] {
            let entry = preset.entry(for: language)
            check(entry?.sampleURL?.scheme == "https", "\(preset.name) has a \(language) sample")
            check(entry?.description["zh"]?.isEmpty == false && entry?.description["en"]?.isEmpty == false,
                  "\(preset.name) has zh and en descriptions in \(language)")
            if let rating = entry?.rating { check((1...5).contains(rating), "\(preset.name) rating 1–5") }
        }
        checkEqual(preset.fallback?.model, "eleven-v4", "\(preset.name) falls back to Eleven v4")
        check(preset.fallback?.voice.hasPrefix("eleven:") == true, "\(preset.name)'s fallback is an eleven: voice")
    }

    let chinese = voices.listed(language: "zh")
    let ratings = chinese.map { $0.entry(for: "zh")?.rating ?? 0 }
    checkEqual(ratings, ratings.sorted(by: >), "the Chinese list goes from the highest rating down")
    checkEqual(chinese.last?.name, "Alnilam", "an unrated voice comes after the rated ones")
    let fives = chinese.filter { $0.entry(for: "zh")?.rating == 5 }.map(\.name)
    checkEqual(fives, fives.sorted(), "same rating: by name")
    check(voices.listed(language: "zh").allSatisfy { $0.entry(for: "zh")?.listed == true }, "only listed voices are on a list")

    checkEqual(voices.perRecordingConsent?.version, "voice-consent-v1", "this-recording consent version")
    checkEqual(voices.standingConsent?.version, "voice-standing-consent-v1", "standing consent version")
    check(voices.standingConsent?.statement.contains("every recording I later use") == true, "the standing statement is the English original")

    // 读得宽：少了 id 的预设跳过；语言里没有 listed 的那一项不算；不认识的字段不管。
    let loose = SkyStudioVoiceCatalog(json: ["voice_presets": [["name": "no id"], ["id": "gemini:Odd", "languages": ["zh": ["gender": "male"]], "future": true]]])
    checkEqual(loose?.presets.map(\.id), ["gemini:Odd"], "a preset without an id is skipped")
    check(loose?.preset("gemini:Odd")?.entry(for: "zh") == nil, "a language entry without listed is not read")
    checkEqual(loose?.preset("gemini:Odd")?.name, "Odd", "name defaults to the id's bare part")
}

private func runRoleChecks(_ voices: SkyStudioVoiceCatalog) {
    checkEqual(Set(voices.roles.keys), Set(MCPVocabulary.voiceRoles), "voice_roles covers SkyCut's 8 AI roles, no more")
    for role in MCPVocabulary.voiceRoles {
        let language = String(role.prefix { $0 != "_" })
        let preset = voices.rolePreset(role)
        check(preset != nil, "\(role) points to a preset that exists")
        checkEqual(preset?.entry(for: language)?.listed, true, "\(role) points to a voice on the \(language) list")
    }
    checkEqual(voices.roles["zh_male"], "gemini:Charon", "the male roles use Charon")
    checkEqual(voices.roles["en_male_british"], "gemini:Iapetus", "the British male role is Iapetus")
    checkEqual(voices.preset("gemini:Iapetus")?.entry(for: "zh")?.listed, false, "Iapetus is English-only")
    checkEqual(voices.rolePreset("not_a_role"), nil, "an unknown role has no preset")
}

private func runVoiceModelChecks(_ catalog: SkyStudioCatalog) {
    checkEqual(Set(catalog.models.map(\.kind)), ["voice", "voice_clone", "voice_enroll", "voice_design", "voice_convert"], "voice kinds only")
    checkEqual(catalog.models(kind: "voice").map(\.id).sorted(), ["eleven-v4", "gemini-3.8-flash-tts"], "narration models")
    checkEqual(catalog.models(kind: "voice_clone").map(\.id).sorted(), ["heygen-voice-turbo", "index-tts-2", "minimax-speech-2.8-hd"], "clone models")
    check(!catalog.models.contains { $0.id == "zonos2" }, "zonos2 is gone")
    checkEqual(catalog.model("minimax-voice-clone", kind: "voice_enroll")?.typicalCredits, 377, "a MiniMax version costs about 377")
    checkEqual(catalog.model("minimax-voice-design", kind: "voice_design")?.typicalCredits, 752, "MiniMax design costs about 752")
    checkEqual(catalog.model("qwen3-voice-design", kind: "voice_design")?.typicalCredits, 22.5, "Qwen3 design costs 22.5")

    let eleven = catalog.model("eleven-v4", kind: "voice")?.supportedLanguages ?? []
    checkEqual(eleven.count, 94, "Eleven v4 lists its 94 languages")
    checkEqual(Set(eleven.filter { $0.count != 2 }), ["yue", "fil", "ceb", "ast", "kam", "ckb"], "six ISO 639-3 codes")
    check(["zh", "en", "ja", "es"].allSatisfy(eleven.contains), "Eleven covers zh, en, ja, es")
    checkEqual(catalog.model("gemini-3.8-flash-tts", kind: "voice")?.supportedLanguages, nil, "no languages listed: unknown, not none")

    for kind in ["voice", "voice_clone"] {
        checkEqual(catalog.voiceCharacterLimit(kind: kind, language: "zh"), 300, "\(kind): Chinese batches up to 300")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, language: "ja"), 330, "\(kind): Japanese batches up to 330")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, language: "ko"), 300, "\(kind): Korean batches up to 300")
        checkEqual(catalog.voiceCharacterLimit(kind: kind, language: "es"), 800, "\(kind): other languages up to 800")
    }
    var lower = catalog
    lower.models.append(SkyStudioModel(id: "future-tts", kind: "voice", title: "Future", limits: ["max_characters_by_language": ["zh": 250]]))
    checkEqual(lower.voiceCharacterLimit(kind: "voice", language: "zh"), 250, "auto batches by the smallest limit in the kind")
    checkEqual(lower.voiceCharacterLimit(kind: "voice", language: "es"), 800, "a model without that language does not lower it")
    checkEqual(catalog.voiceCharacterLimit(kind: "voice_convert", language: "zh"), nil, "no limit written: nil")
    for id in ["chatterbox-hd", "chatterbox"] {
        checkEqual(catalog.model(id, kind: "voice_convert")?.limit("max_source_seconds"), 300, "\(id): 5 minutes at most")
    }
}

/// 服务商的 id（MiniMax 的 voice_id 是 `Voice` + 一长串十六进制）永远不出服务器：快照里没有，DTO 也不留。
private func runProviderIDChecks(_ text: String) {
    check(text.range(of: #"Voice[0-9a-fA-F]{12,}"#, options: .regularExpression) == nil, "no MiniMax voice id in the snapshot")
    for field in ["provider_voice_id", "minimax_voice_id", "voice_id\""] {
        check(!text.contains(field), "the snapshot has no \(field)")
    }
    let hostile: JSONValue = [
        "voice": ["id": "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d", "name": "Sky", "source": "recording", "provider_voice_id": "mm-leak",
                  "languages": [["language": "zh", "kind": "recording", "seconds": 29.95, "minimax": true, "minimax_voice_id": "mm-leak"]]]
    ]
    let voice = try? SkyStudioVoice(json: hostile["voice"] ?? .null)
    check(voice != nil, "a voice with extra fields still reads")
    check(voice.map { !$0.json.encodedString().contains("mm-leak") } ?? false, "the DTO drops fields it does not know, provider ids included")
    checkEqual(voice?.language("zh")?.minimax, true, "minimax is a yes / no, not an id")
}
