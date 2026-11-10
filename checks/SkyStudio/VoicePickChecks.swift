import Foundation
import SrtFlowMCPKit

// 声音 PR 3（SkyCut 声音方案 4.3、9.1 第 8 项）：add_voiceover 的 voice 在 Sky Studio 上是谁（SkyStudioVoicePick），对着目录快照认。
// 钉住：认声音的顺序（没给 / 角色 / gemini: / eleven: / 不带前缀的名字 / Kokoro 的音色名不走云端）；不给 = 目录里的默认（gemini:Charon），
// 不是温和女声；角色只认 voice_roles；英式男声读非英文改用那种语言的旁白角色并说一声；预设名不计较大小写、不带前缀也认；
// 目录缺东西退本机；本机退档按角色 / 预设在这种语言里的性别挑（Gacrux 中文男、英文女），读不到目录按旁白；
// 本机不点名的旁白角色（zh_male / en_male）在服务器上正是默认预设（同一个人设）。
// 读 Key、报价、真起任务在 scripts/check-voice-recovery.sh（真 App 对象 + 假协议）。

func runVoicePickChecks() {
    guard let voices = loadVoiceFixture()?.catalog.voices else { return check(false, "the voice catalog snapshot loads for the voice checks") }
    runAskChecks()
    runResolveChecks(voices)
    runLocalRoleChecks(voices)
}

private func runAskChecks() {
    checkEqual(SkyStudioVoicePick.ask(nil), .standard, "no voice: the catalog's default")
    checkEqual(SkyStudioVoicePick.ask("  "), .standard, "a blank voice: the catalog's default")
    checkEqual(SkyStudioVoicePick.ask("EN_MALE"), .role(AIVoiceRole.named("en_male")!), "roles are case-insensitive")
    checkEqual(SkyStudioVoicePick.ask("gemini:Charon"), .preset("gemini:Charon"), "gemini: is a preset")
    checkEqual(SkyStudioVoicePick.ask("Eleven:Daniel"), .eleven("Eleven:Daniel"), "eleven: is an Eleven v4 voice")
    checkEqual(SkyStudioVoicePick.ask("af_heart"), nil, "a SkyCut (Kokoro) voice name never goes to Sky Studio")
    checkEqual(SkyStudioVoicePick.ask("Charon"), .name("Charon"), "a bare name may be a preset (or a Mac voice)")
}

private func runResolveChecks(_ voices: SkyStudioVoiceCatalog) {
    func voice(_ ask: SkyStudioVoiceAsk, _ language: String) -> String? {
        if case .cloud(let pick) = SkyStudioVoicePick.resolve(ask, in: voices, language: language) { return pick.voice }
        return nil
    }
    checkEqual(voice(.standard, "en"), "gemini:Charon", "no voice named: gemini:Charon, not the warm female voice")
    checkEqual(voice(.standard, "zh"), "gemini:Charon", "the default is the same in every language")
    checkEqual(voice(.role(AIVoiceRole.named("zh_female_lively")!), "zh"), "gemini:Laomedeia", "a role reads as its voice_roles preset")
    checkEqual(voice(.role(AIVoiceRole.named("en_male_british")!), "en"), "gemini:Iapetus", "the British male role reads English as Iapetus")
    if case .cloud(let pick) = SkyStudioVoicePick.resolve(.role(AIVoiceRole.named("en_male_british")!), in: voices, language: "zh") {
        checkEqual(pick.voice, "gemini:Charon", "en_male_british with Chinese text: the Chinese male role's preset instead of Iapetus")
        check(pick.notes.first?.contains("en_male_british only reads English") == true && pick.notes.first?.contains("Chinese") == true,
              "and voice.note says so")
    } else { check(false, "en_male_british with Chinese text resolves") }
    checkEqual(voice(.role(AIVoiceRole.named("en_male_british")!), "ja"), "gemini:Charon", "a language without a male role: the default preset")
    checkEqual(voice(.preset("GEMINI:charon"), "en"), "gemini:Charon", "preset ids are case-insensitive")
    checkEqual(voice(.name("aoede"), "zh"), "gemini:Aoede", "a bare preset name is a preset (even one not listed for the language)")
    checkEqual(voice(.eleven("eleven:Daniel"), "en"), "eleven:Daniel", "an Eleven v4 voice goes as eleven:<name>")
    checkEqual(SkyStudioVoicePick.resolve(.preset("gemini:Nobody"), in: voices, language: "en"), .notPreset("gemini:Nobody"), "an unknown preset")
    checkEqual(SkyStudioVoicePick.resolve(.name("Samantha"), in: voices, language: "en"), .notPreset("Samantha"),
               "a bare name that is not a preset goes back to the Mac voices")
    checkEqual(SkyStudioVoicePick.resolve(.eleven("eleven:"), in: voices, language: "en"), .notPreset("eleven:"), "an empty Eleven name")
    check(voice(.name("Rachel"), "en") == nil, "old bare Eleven names are no longer Sky Studio voices")

    var noDefault = voices
    noDefault.presets = voices.presets.map { preset in var copy = preset; copy.isDefault = false; return copy }
    if case .incomplete = SkyStudioVoicePick.resolve(.standard, in: noDefault, language: "en") { check(true, "no default preset: Sky Studio is incomplete") }
    else { check(false, "no default preset: Sky Studio is incomplete") }
    var noRoles = voices
    noRoles.roles = [:]
    if case .incomplete = SkyStudioVoicePick.resolve(.role(AIVoiceRole.named("zh_male")!), in: noRoles, language: "zh") {
        check(true, "a role missing from voice_roles: Sky Studio is incomplete")
    } else { check(false, "a role missing from voice_roles: Sky Studio is incomplete") }
    let listed = SkyStudioVoicePick.listedNames(in: voices, language: "zh")
    check(listed.hasPrefix("gemini:") && listed.contains("gemini:Charon") && !listed.contains("gemini:Despina"),
          "an unknown voice is answered with the language's listed presets")
}

private func runLocalRoleChecks(_ voices: SkyStudioVoiceCatalog) {
    func role(_ ask: SkyStudioVoiceAsk, _ language: String, catalog: SkyStudioVoiceCatalog? = nil) -> String? {
        SkyStudioVoicePick.localRole(for: ask, catalog: catalog, language: language)?.name
    }
    checkEqual(role(.standard, "zh"), "zh_male", "no voice, Chinese, no Sky Studio: zh_male's local voice")
    checkEqual(role(.standard, "en"), "en_male", "no voice, English, no Sky Studio: en_male's local voice")
    checkEqual(role(.standard, "ja"), nil, "a language without roles: that language's default local voice")
    checkEqual(role(.role(AIVoiceRole.named("en_female_lively")!), "en"), "en_female_lively", "a role keeps its own local voice")
    checkEqual(role(.preset("gemini:Gacrux"), "zh", catalog: voices), "zh_male", "Gacrux reads Chinese as a man: the male role")
    checkEqual(role(.preset("gemini:Gacrux"), "en", catalog: voices), "en_female_warm", "Gacrux reads English as a woman: the warm female role")
    checkEqual(role(.preset("gemini:Despina"), "en", catalog: voices), "en_female_warm", "Despina reads English as a woman: the warm female role")
    // 服务器可以报「性别不明」（gender unknown）；最终快照里已经没有这样的声音，拿一份改过的目录照样钉住：不明的退到旁白角色。
    var unplaced = voices
    if let index = unplaced.presets.firstIndex(where: { $0.id == "gemini:Despina" }) {
        for language in unplaced.presets[index].languages.keys { unplaced.presets[index].languages[language]?.gender = "unknown" }
    }
    checkEqual(role(.preset("gemini:Despina"), "en", catalog: unplaced), "en_male", "gender unknown: the narrator")
    checkEqual(role(.preset("gemini:Sulafat"), "zh"), "zh_male", "no catalog: the narrator")
    checkEqual(role(.eleven("eleven:Daniel"), "en"), "en_male", "an Eleven voice falls back to the narrator, as before")
    // 本机不点名的那个角色和 Sky Studio 不点名的那个声音是同一个人设（4.3：照 voice_roles 里指向 Charon 的角色）。
    for language in ["zh", "en"] {
        let narrator = AIVoiceRole.narrator(forLanguage: language)
        checkEqual(narrator.flatMap { voices.rolePreset($0.name)?.id }, voices.defaultPreset?.id,
                   "\(language): the local narrator role is the role Sky Studio maps to its default preset")
    }
}
