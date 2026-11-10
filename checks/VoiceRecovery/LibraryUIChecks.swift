import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 声音库的界面（声音 PR 8，SkyCut 声音方案 5.1–5.4、9.1 第 13 项）背后那几个对象，走真 App 对象 + 假协议（VoiceLibraryHTTP）：
// - VoiceLibraryStore：取到了 / 声音库用不了（预设照常、不能改）/ 没有 Key / 钥匙串要授权各是一种样子；改名；删除碰上存储一时不可用再发一次、
//   删了立刻从列表消失；试听的临时链接没过期用手里的、过期了只重取那一个声音；「声音库变了」（AI 改的也算）自己再取一遍。
// - NewVoiceModel：**没勾授权什么都不传**；勾了才传 `voice_reference` 一次、`POST /voices` 带 `consent: true` + 版本 / 用了哪一段 / 稳定的 key，
//   而且和 AI 的 manage_voices 对同一段录音发的是**同一个 key**（两个入口一条路）；人声不够当场说、不碰网络；语言照本机检测预选、用户选过就不替他改；
//   加录音不问名字、已有的语言不列也不替他选；全部权限 + 有效的长期授权时那一勾默认勾上（请求批准模式、用户动过都不替他勾）。
// - DesignVoiceModel：填好了才问价；按下去照报价判每日硬预算、记账、起 `voice_design` 任务（`max_credits` 是报价）、做完进声音库；
//   改了字手里的报价作废；超了每日额度不记账、不起任务。
// - 录音机：电平条的换算、规格和参考录音一样、最长 3 分钟、麦克风被拒就不录。
// - 界面上的话：授权那一句认得的版本用译文、没见过的版本原样显示服务器的英文；语言的名字照界面语言。

@MainActor
func runVoiceLibraryUIChecks(_ root: URL) async throws {
    try await storeChecks(root)
    try await newVoiceChecks(root)
    try await addRecordingChecks(root)
    try await designChecks(root)
    await recorderChecks(root)
    textChecks()
}

@MainActor
private func makeStore(_ fixture: VoiceLibraryFixture) -> VoiceLibraryStore {
    let store = VoiceLibraryStore()
    store.api = fixture.services.api
    store.readKey = { .success("local-library-fixture") }
    return store
}

@MainActor
private func eventually(_ what: String, _ done: @MainActor () -> Bool) async {
    // 最多等 15 秒：CI 的 runner 只有三个核，读 15 秒的 WAV、起任务都比本机慢。
    for _ in 0..<600 {
        if done() { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    require(false, "timed out waiting for \(what)")
}

/// 改名、删除、建声音之后会叫一声「声音库变了」，Store 自己再取一遍：等这些都落定再往下看。
@MainActor
private func settled(_ store: VoiceLibraryStore) async {
    try? await Task.sleep(nanoseconds: 60_000_000)
    await eventually("the store to settle") { store.refreshing == 0 }
}

private final class Counter: @unchecked Sendable { var value = 0 }

@MainActor
private func storeChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("ui-store"))
    let store = makeStore(fixture)
    require(store.phase == .idle && !store.canEdit, "a store nobody looked at has asked nothing")
    await store.refresh()
    require(store.phase == .ready && store.canEdit && store.voices.map(\.name) == ["Sky"], "the store lists the user's voices")
    require(store.consentStatement?.version == "voice-consent-v1" && store.catalog?.defaultPreset?.id == "gemini:Charon",
            "and reads the presets and the consent statement from /models")
    guard let sky = store.voices.first else { return }

    let renamed = await store.rename(sky, to: "Sky Two")
    require(renamed && store.voices.first?.name == "Sky Two" && VoiceLibraryHTTP.calls("PATCH", "/voices/" + sky.id).first?["name"] == "Sky Two",
            "rename sends PATCH and shows the new name")
    await settled(store)
    let empty = await store.rename(store.voices[0], to: "   ")
    require(!empty && store.notice != nil && VoiceLibraryHTTP.calls("PATCH", "/voices/" + sky.id).count == 1, "an empty name is refused before any request")

    // 试听的临时链接：没过期用手里的；过期了只重取那一个声音。
    VoiceLibraryHTTP.lock.withLock {
        VoiceLibraryHTTP.voices[sky.id] = ["id": .string(sky.id), "name": "Sky Two", "source": "recording", "languages": [[
            "language": "en", "kind": "recording", "minimax": false, "preview_url": "https://assets.example/voices/p1.wav",
            "preview_expires_at": "2030-01-01T00:00:00Z"]]]
    }
    await store.refresh()
    await settled(store)
    let gets = { VoiceLibraryHTTP.calls("GET", containing: "/voices/voice_") }
    let before = gets()
    let fresh = await store.previewURL(voice: sky.id, language: "en", now: Date(timeIntervalSince1970: 1_800_000_000))
    require(fresh?.absoluteString == "https://assets.example/voices/p1.wav" && gets() == before, "an unexpired preview link is used as is")
    let later = await store.previewURL(voice: sky.id, language: "en", now: Date(timeIntervalSince1970: 1_893_456_000 - 30))
    require(later != nil && gets() == before + 1, "a link about to expire is fetched again, for that one voice")
    await settled(store)
    let missing = await store.previewURL(voice: sky.id, language: "ja")
    require(missing == nil, "a language the voice has no recording in has nothing to play")

    // 「声音库变了」：AI 那边建了一个，这里自己再取一遍。
    VoiceLibraryHTTP.lock.withLock {
        let id = "voice_" + String(repeating: "b", count: 32)
        VoiceLibraryHTTP.voices[id] = VoiceLibraryHTTP.voice(id, name: "Made by AI", languages: ["zh"], minimax: false)
    }
    SkyStudioVoiceLibraryChange.post()
    await eventually("the store to notice the change") { store.voices.count == 2 }
    require(store.voices.contains { $0.name == "Made by AI" }, "a change made elsewhere shows up without reopening Settings")

    // 删除：存储一时不可用再发一次；删了立刻从列表消失。
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.deleteStorageFailures = 1 }
    await store.delete(store.voices.first { $0.id == sky.id }!)
    await settled(store)
    require(VoiceLibraryHTTP.calls("DELETE", containing: "/voices/" + sky.id) == 2 && !store.voices.contains { $0.id == sky.id } && store.notice == nil,
            "delete retries once after a storage failure and the voice leaves the list")

    // 声音库用不了：预设照常，新建 / 设计 / 改名 / 删除都不能做。
    VoiceLibraryHTTP.lock.withLock {
        VoiceLibraryHTTP.listFailure = (503, ["error": ["code": "voice_library_unavailable", "message": "Not configured.", "reason": "not_configured"]])
    }
    await store.refresh()
    await settled(store)
    require(store.phase == .unavailable && !store.canEdit && store.voices.isEmpty && store.catalog != nil,
            "an unavailable library is its own state: nothing to edit, presets still there")
    let patches = VoiceLibraryHTTP.calls("PATCH", "/voices/" + sky.id).count
    let refused = await store.rename(sky, to: "Nope")
    require(!refused && VoiceLibraryHTTP.calls("PATCH", "/voices/" + sky.id).count == patches, "nothing is sent while the library is unavailable")

    // 没有 Key / 钥匙串要授权：各是一种样子，什么都不问 Sky Studio。
    await settled(store)
    let asked = VoiceLibraryHTTP.log.count
    store.readKey = { .failure(.noKey) }
    await store.refresh()
    require(store.phase == .noKey && VoiceLibraryHTTP.log.count == asked, "without a key the store says so and asks Sky Studio nothing")
    store.readKey = { .failure(.needsPermission) }
    await store.refresh()
    require(store.phase == .needsPermission && VoiceLibraryHTTP.log.count == asked, "a keychain that needs permission is its own state")
}

@MainActor
private func prepared(_ model: NewVoiceModel, _ file: URL, language: String?) async {
    model.use(file: file)
    await eventually("the sample of \(file.lastPathComponent)") {
        if case .ready = model.sample { return !model.detectingLanguage && model.language == language }
        return false
    }
}

@MainActor
private func newVoiceChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("ui-new"))
    let store = makeStore(fixture)
    await store.refresh()
    let file = try fixture.recording()

    let model = NewVoiceModel(mode: .create, store: store)
    model.detectLanguage = { _, _ in "zh" }
    require(model.blocker == .name, "an empty dialog asks for a name first")
    model.name = "Sky Two"
    require(model.blocker == .recording, "then for a recording")
    await prepared(model, file, language: "zh")
    guard case .ready(let sample) = model.sample else { return require(false, "the chosen file becomes a sample") }
    require(abs(sample.voicedSeconds - 15) < 0.1 && !sample.autoSelected, "the sample is the same one manage_voices would make (15 s of speech)")
    require(model.language == "zh", "the language is preselected by the local detection")
    require(model.blocker == .consent, "everything else filled in, the consent box is what is missing")
    let silent = await model.submit()
    require(silent == nil && VoiceLibraryHTTP.calls("POST", "/uploads").isEmpty && VoiceLibraryHTTP.calls("POST", "/voices").isEmpty,
            "without the consent box nothing is uploaded or created")
    model.setAgreed(true)
    require(model.blocker == nil, "with the box checked the voice can be created")
    let created = await model.submit()
    let ticket = VoiceLibraryHTTP.calls("POST", "/uploads").first
    require(created != nil && ticket?["purpose"] == "voice_reference" && ticket?["content_type"] == "audio/wav" && VoiceLibraryHTTP.uploads.count == 1,
            "the sample is uploaded once as voice_reference WAV")
    let creation = VoiceLibraryHTTP.calls("POST", "/voices").first
    require(creation?["consent"] == true && creation?["consent_statement_version"] == "voice-consent-v1" && creation?["language"] == "zh"
            && creation?["name"] == "Sky Two" && creation?["reference_url"] == "skystudio-private://voice/uploads/u/1.wav"
            && creation?["source"]?["file_name"] == "my-voice.wav" && creation?["source"]?["auto_selected"] == false
            && creation?["idempotency_key"]?.stringValue?.count == 32,
            "POST /voices carries this recording's consent and version, the private upload name, the part used and a stable key")
    require(store.voices.contains { $0.id == created?.id }, "the new voice is in the list right away")
    model.close()
    await settled(store)

    // 两个入口一条路：AI 的 manage_voices 对同一段录音、同一个名字和语言发的是同一个 idempotency_key。
    let args: JSONValue = ["action": "create", "file": .string(file.path), "name": "Sky Two", "language": "zh"]
    let question = try await fixture.manage(args)
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = question.payload["confirm_token"] ?? .null
    _ = try await fixture.manage(.object(confirmed))
    let both = VoiceLibraryHTTP.calls("POST", "/voices").compactMap { $0["idempotency_key"]?.stringValue }
    require(both.count == 2 && both[0] == both[1], "the dialog and manage_voices send the same key for the same recording: \(both)")

    // 用户自己选过语言：检测出别的也不替他改。
    let chosen = NewVoiceModel(mode: .create, store: store)
    chosen.detectLanguage = { _, _ in "en" }
    chosen.choose(language: "ja")
    await prepared(chosen, file, language: "ja")
    require(chosen.language == "ja", "a language the user picked is not overwritten by the detection")
    chosen.close()

    // 检测不出来：那一行空着，要用户选。
    let unknown = NewVoiceModel(mode: .create, store: store)
    unknown.detectLanguage = { _, _ in nil }
    unknown.name = "Unknown"
    await prepared(unknown, file, language: nil)
    unknown.setAgreed(true)
    require(unknown.blocker == .language, "an undetected language is left for the user to choose, never guessed")
    unknown.close()

    // 人声不够：当场说，不碰网络。
    let short = fixture.folder.appendingPathComponent("allowed/short.wav")
    try VoiceReferenceSample.wavData(samples: (0..<(44_100 * 6)).map { Int16(sin(Double($0) * 0.05) * 6_000) }, sampleRate: 44_100).write(to: short)
    let requests = VoiceLibraryHTTP.log.count
    let tooShort = NewVoiceModel(mode: .create, store: store)
    tooShort.name = "Short"
    tooShort.use(file: short)
    await eventually("the short sample to be refused") { if case .failed = tooShort.sample { return true } else { return false } }
    if case .failed(let message) = tooShort.sample {
        require(message.contains("6.0") && message.contains("10 s"), "too little speech says how much there is and how much is needed: \(message)")
    }
    require(tooShort.blocker == .recording && VoiceLibraryHTTP.log.count == requests, "and nothing is sent")
    tooShort.close()

    // 那一勾的默认：全部权限 + 有效的长期授权才替用户勾上。
    let access = AIAccessStore.shared
    let mode = access.mode
    defer { access.setMode(mode) }
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.standingGrant = true }
    access.setMode(.ask)
    let asking = NewVoiceModel(mode: .create, store: store)
    await asking.presetAgreementFromStandingGrant()
    require(!asking.agreed, "in ask-for-approval mode the box starts unchecked")
    access.setMode(.full)
    let granted = NewVoiceModel(mode: .create, store: store)
    await granted.presetAgreementFromStandingGrant()
    require(granted.agreed, "with full access and an active standing consent the box starts checked")
    let touched = NewVoiceModel(mode: .create, store: store)
    touched.setAgreed(false)
    await touched.presetAgreementFromStandingGrant()
    require(!touched.agreed, "but a box the user already touched is left alone")
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.standingGrant = false }
    let ungranted = NewVoiceModel(mode: .create, store: store)
    await ungranted.presetAgreementFromStandingGrant()
    require(!ungranted.agreed, "full access without a standing consent leaves the box unchecked")
}

@MainActor
private func addRecordingChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("ui-add"))
    let store = makeStore(fixture)
    await store.refresh()
    guard let sky = store.voices.first else { return require(false, "the fixture has a voice") }
    let file = try fixture.recording("second-language.wav")
    let model = NewVoiceModel(mode: .addReference(sky), store: store)
    require(!model.languageChoices.contains("en") && model.languageChoices.contains("zh"), "a language the voice already has is not offered")
    model.detectLanguage = { _, _ in "en" }
    await prepared(model, file, language: nil)
    require(model.language == nil && model.blocker == .language, "a detected language the voice already has is not chosen for the user")
    model.choose(language: "en")
    model.setAgreed(true)
    require(model.blocker == .languageTaken("en"), "and choosing it is refused before any request")
    model.choose(language: "zh")
    require(model.blocker == nil, "another language needs no name")
    let added = await model.submit()
    let body = VoiceLibraryHTTP.calls("POST", "/voices/" + sky.id + "/references").first
    require(added?.languages.map(\.language).sorted() == ["en", "zh"] && body?["consent"] == true && body?["language"] == "zh"
            && body?["consent_statement_version"] == "voice-consent-v1" && body?["source"]?["file_name"] == "second-language.wav",
            "the recording is added to that voice with this recording's consent")
    require(store.voices.first { $0.id == sky.id }?.languages.count == 2, "and the list shows both languages")
    model.close()
}

@MainActor
private func designChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("ui-design"))
    let store = makeStore(fixture)
    await store.refresh()
    let spend = SkyStudioSpendStore.shared
    let model = DesignVoiceModel(store: store)
    model.quoteDelay = 0
    model.project = { fixture.project }
    model.prompt = "A calm narrator in his thirties."
    require(model.offer == .none && VoiceLibraryHTTP.calls("POST", "/quote").isEmpty, "no price is asked before the name is filled in")
    model.name = "Calm"
    await eventually("the design quote") { model.quote != nil }
    let quote = VoiceLibraryHTTP.calls("POST", "/quote").last
    require(quote?["kind"] == "voice_design" && quote?["model"] == "auto" && quote?["prompt"] == "A calm narrator in his thirties."
            && quote?["params"]?["name"] == "Calm" && model.quote?.credits == 22.5, "the filled-in design is quoted (model auto)")
    require(VoiceLibraryHTTP.calls("POST", "/jobs").isEmpty, "asking the price starts nothing")

    // 改了字：手里的报价作废，按钮按不动。
    model.sampleText = "Hello there."
    require(model.quote == nil && !model.design() && VoiceLibraryHTTP.calls("POST", "/jobs").isEmpty, "editing a field drops the quote; nothing can be ordered on the old price")
    await eventually("the new quote") { model.quote != nil }

    let before = spend.spentToday()
    require(model.design(), "pressing Design with a quote starts the job")
    require(abs(spend.spentToday() - before - 22.5) < 0.001 && store.designing == ["Calm"], "the quoted price is reserved against today's budget")
    await eventually("the designed voice") { store.designing.isEmpty && store.voices.contains { $0.source == "design" } }
    let job = VoiceLibraryHTTP.calls("POST", "/jobs").first
    require(job?["kind"] == "voice_design" && job?["max_credits"] == 22.5 && job?["params"]?["name"] == "Calm"
            && job?["params"]?["sample_text"] == "Hello there." && job?["prompt"] == "A calm narrator in his thirties."
            && job?["model"] == "auto" && job?["idempotency_key"]?.stringValue?.isEmpty == false,
            "voice_design is sent with the quote as max_credits, the same request that was quoted")
    require(abs(spend.spentToday() - before - 22.5) < 0.001 && store.notice == nil, "the charge stays as settled, and the voice is in the library")
    model.close()

    // 中文描述：服务器回的是 MiniMax、「约」和「最多」不一样，两个数都要显示。
    let chinese = DesignVoiceModel(store: store)
    chinese.quoteDelay = 0
    chinese.project = { fixture.project }
    chinese.name = "沉稳旁白"
    chinese.prompt = "三十多岁的男声，沉稳。"
    await eventually("the Chinese design quote") { chinese.quote != nil }
    let offer = chinese.quote.map(VoiceLibraryText.designOffer) ?? ""
    require(offer.contains("MiniMax") && offer.contains("751.4") && offer.contains("760") && VoiceLibraryText.designButton(chinese.quote).contains("760"),
            "a quote with an expected and a maximum price shows both, and the button names the maximum: \(offer)")

    // 超了每日额度：不记账、不起任务（两种权限模式都一样，这里没有模式的事）。
    let jobs = VoiceLibraryHTTP.calls("POST", "/jobs").count
    let spent = spend.spentToday()
    spend.setDailyLimit(max(1, (spent + 100).rounded()))
    require(chinese.overLimit(spend: spend), "a quote over today's budget is flagged")
    require(!chinese.design() && chinese.problem != nil && VoiceLibraryHTTP.calls("POST", "/jobs").count == jobs && abs(spend.spentToday() - spent) < 0.001,
            "and pressing Design reserves nothing and starts nothing")
    spend.setDailyLimit(100_000)
    chinese.close()

    // 描述太长：不问价。
    let long = DesignVoiceModel(store: store)
    long.quoteDelay = 0
    let quotes = VoiceLibraryHTTP.calls("POST", "/quote").count
    long.name = "Long"
    long.prompt = String(repeating: "a", count: SkyStudioVoiceDesignOrder.maxDescription + 1)
    try await Task.sleep(nanoseconds: 100_000_000)
    require(long.promptTooLong && long.offer == .none && VoiceLibraryHTTP.calls("POST", "/quote").count == quotes, "an over-long description is not quoted")
}

@MainActor
private func recorderChecks(_ root: URL) async {
    require(VoiceSampleRecorder.level(decibels: -60) == 0 && VoiceSampleRecorder.level(decibels: 0) == 1
            && abs(VoiceSampleRecorder.level(decibels: -25) - 0.5) < 0.001 && VoiceSampleRecorder.level(decibels: .nan) == 0
            && VoiceSampleRecorder.level(decibels: 12) == 1, "the level meter maps −50…0 dB to 0…1 and survives bad readings")
    require(VoiceSampleRecorder.maximumSeconds == 180, "recording stops at the 3-minute sample limit")
    let settings = VoiceSampleRecorder.settings
    require(settings[AVSampleRateKey] as? Double == 44_100 && settings[AVNumberOfChannelsKey] as? Int == 1 && settings[AVLinearPCMBitDepthKey] as? Int == 16
            && settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM, "the microphone records the reference format: 44.1 kHz mono 16-bit PCM")
    let recorder = VoiceSampleRecorder()
    let asked = Counter(), finished = Counter()
    recorder.requestAccess = { asked.value += 1; return false }
    recorder.onFinish = { _ in finished.value += 1 }
    let folder = root.appendingPathComponent("ui-recorder")
    require(asked.value == 0, "the microphone is not asked for until Record is pressed")
    await recorder.start(in: folder)
    require(asked.value == 1 && recorder.state == .denied && finished.value == 0 && !FileManager.default.fileExists(atPath: folder.path),
            "a refused microphone records nothing and says so")
}

@MainActor
private func textChecks() {
    let catalog = SkyStudioVoiceCatalog(json: VoiceRecoveryHTTP.catalog)
    if let statement = catalog?.perRecordingConsent {
        require(VoiceLibraryText.consent(statement).hasPrefix("I have the right to use this voice"), "the known consent version shows SkyCut's own wording")
    } else {
        require(false, "the catalog has the per-recording consent")
    }
    let newer: JSONValue = ["version": "voice-consent-v2", "statement": "A newer statement from Sky Studio."]
    if let statement = SkyStudioVoiceConsentStatement(json: newer) {
        require(VoiceLibraryText.consent(statement) == "A newer statement from Sky Studio.", "an unknown consent version shows the server's own words")
    }
    require(VoiceLibraryText.languageName("zh", uiLanguage: "zh-Hans") == "中文" && VoiceLibraryText.languageName("zh", uiLanguage: "es") == "Chino"
            && VoiceLibraryText.languageName("en", uiLanguage: "en") == "English", "language names follow the interface language, capitalised")
    require(VoiceLibraryText.designModel("minimax-voice-design") == "MiniMax" && VoiceLibraryText.designModel("qwen3-voice-design") == "Qwen3"
            && VoiceLibraryText.designModel(nil) == "Sky Studio", "design models are shown by their maker's name")
    let blockers: [NewVoiceGate.Blocker] = [.unavailable, .tooManyVoices(limit: 50), .name, .recording, .language, .languageTaken("zh"), .consent]
    require(blockers.allSatisfy { VoiceLibraryText.blocker($0, voiceName: "Sky")?.isEmpty == false } && VoiceLibraryText.blocker(nil, voiceName: nil) == nil
            && VoiceLibraryText.blocker(.busy, voiceName: nil) == nil, "every reason the button is off has a sentence; none when it is on")
    let full = SkyStudioFailure.server(SkyStudioServerError(status: 409, code: "voice_limit", message: "Full.", fields: ["limit": 50]))
    require(VoiceLibraryText.message(full).contains("50") && !VoiceLibraryText.message(full).contains("manage_voices"),
            "the interface never tells the user to call an AI tool")
}
