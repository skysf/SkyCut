import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 变声（声音 PR 9，SkyCut 声音方案 4.8、4.9、5.5、9.1 第 7、11 项）走真 App 对象 + 假协议（VoiceChangeHTTP）：
// - 落地的规则（纯值）：原段静音、两条新轨、链接、变速 / 音量 / 渐变 / 曲线照抄、长几毫秒裁到原长、这一段被动过照现在的样子落、
//   不在了 / 换了素材 / 往外拉长了不落；联动开着时挪主轨的原片段，两段新音频跟着走。
// - change_voice：先报价再上传（单声道 16-bit WAV、`voice_convert_source`）、`voice_convert` 的请求、`max_credits` 是报价、两个文件、
//   一次 `/jobs`；AI 给的 `language` 优先于本机检测，知道语言、目标声音又有这种参考时才带 `params.target_language`；
//   超过上限 / 静音 / 几乎没声音 / 每日额度不够都在收费之前停；声音库用不了照实说。
// - 落地是**一步撤销 / 重做**；工程换了、这一段没了只留文件；服务器说没做成退回那一笔；提交结果不明不重交、那一笔留在账上。
// - 面板背后的那一份：默认选哪个声音、选了才问价、换声音报价作废、按下去过每日硬预算并起同一个任务、做完提示条说一句。

@MainActor
func runVoiceChangeChecks(_ root: URL) async throws {
    landingChecks()
    orderChecks()
    try await toolChecks(root)
    try await languageChecks(root)
    try await refusalChecks(root)
    try await undoChecks(root)
    try await projectChangedChecks(root)
    try await failureChecks(root)
    try await panelChecks(root)
}

// MARK: 落地的规则（纯值）

@MainActor
private func landingChecks() {
    let source = URL(fileURLWithPath: "/media/interview.mov")
    let info = MediaInfo(duration: 60, displaySize: CGSize(width: 1920, height: 1080), frameRate: 30, videoCodec: "h264", audioCodec: "aac",
                         hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1)
    var main = EditClip(sourceURL: source, sourceStart: 2, sourceDuration: 6, speed: 1.5, timelineStart: 4, volume: 0.8,
                        fadeInDuration: 0.3, fadeOutDuration: 0.4, info: info)
    main.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 3, value: -2), Keyframe(time: 5, value: -8)])
    let music = EditClip(sourceURL: URL(fileURLWithPath: "/media/music.m4a"), isAudioOnly: true, sourceDuration: 30, audioAssetDuration: 30)
    var state = TimelineState()
    state.mainClips = [main]
    state.audioTracks = [EditLane(clips: [music])]
    let before = state
    let origin = VoiceChangeLanding.Origin(clipID: main.id, sourceURL: source, sourceStart: 2, sourceDuration: 6)
    let files = VoiceChangeLanding.Files(voice: URL(fileURLWithPath: "/media/interview - Sky.wav"), voiceSeconds: 6.02,
                                         background: URL(fileURLWithPath: "/media/interview - background.wav"), backgroundSeconds: 6)
    guard case .success(let landed) = VoiceChangeLanding.land(files, origin: origin, in: &state),
          let original = state.clip(with: main.id), let voice = state.clip(with: landed.voiceID),
          let background = state.clip(with: landed.backgroundID) else {
        return require(false, "the two files land on a clip that is still there")
    }
    require(original.isMuted && original.sourceStart == 2 && original.sourceDuration == 6 && state.mainClips.count == 1,
            "the original clip is muted, not deleted or changed otherwise")
    require(state.audioTracks.count == 3 && landed.voiceTrack == 1 && landed.backgroundTrack == 2
            && state.audioTracks[1].clips.map(\.id) == [voice.id] && state.audioTracks[2].clips.map(\.id) == [background.id]
            && state.audioTracks[0].clips == [music], "voice and background each get a new audio track after the existing ones")
    require(original.linkGroup != nil && voice.linkGroup == original.linkGroup && background.linkGroup == original.linkGroup
            && state.linkedClipIDs(of: main.id) == [main.id, voice.id, background.id], "the three clips share one link group")
    for (piece, file) in [(voice, files.voice), (background, files.background)] {
        require(piece.isAudioOnly && piece.sourceURL == file && piece.sourceStart == 0 && piece.timelineStart == 4
                && abs(piece.timelineEnd - original.timelineEnd) < 1e-9, "\(file.lastPathComponent) sits at the clip's place on the timeline")
        require(piece.speed == 1.5 && piece.volume == 0.8 && piece.fadeInDuration == 0.3 && piece.fadeOutDuration == 0.4 && !piece.isMuted,
                "\(file.lastPathComponent) takes the clip's speed, volume and fades")
        require(piece.volumeCurve.keys.map(\.time) == [1, 3] && piece.volumeCurve.keys.map(\.value) == [-2, -8],
                "\(file.lastPathComponent) takes the volume curve, moved onto the new file's own time")
    }
    require(voice.sourceDuration == 6 && voice.audioAssetDuration == 6.02, "a voice a few milliseconds longer is trimmed on the timeline; the file is untouched")

    // 原片段本来就在链接组里（视频 + 分离出来的音频）：沿用那个组。
    var grouped = before
    let group = UUID()
    grouped.update(main.id) { $0.linkGroup = group }
    if case .success(let again) = VoiceChangeLanding.land(files, origin: origin, in: &grouped) {
        require(grouped.clip(with: again.voiceID)?.linkGroup == group && grouped.clip(with: main.id)?.linkGroup == group,
                "a clip that is already linked keeps its group")
    } else { require(false, "an already linked clip lands too") }

    // 任务跑着的时候这一段被裁短、挪了：照现在的样子落，只取还用着的那一截。
    var trimmed = before
    trimmed.update(main.id) { $0.sourceStart = 3; $0.sourceDuration = 4; $0.timelineStart = 10 }
    if case .success(let part) = VoiceChangeLanding.land(files, origin: origin, in: &trimmed), let piece = trimmed.clip(with: part.voiceID) {
        require(piece.sourceStart == 1 && piece.sourceDuration == 4 && piece.timelineStart == 10, "a clip trimmed and moved meanwhile gets the matching part, at its new place")
    } else { require(false, "a clip trimmed inside the sent range still lands") }

    // 背景比这一段短一点：那一段就短一点，不许比文件长。
    var shortFiles = files
    shortFiles.backgroundSeconds = 5.9
    var short = before
    if case .success(let part) = VoiceChangeLanding.land(shortFiles, origin: origin, in: &short) {
        require(short.clip(with: part.backgroundID)?.sourceDuration == 5.9, "a background shorter than the clip is not stretched past its file")
    } else { require(false, "a slightly short background still lands") }

    // 落不了的三种：什么都不改。
    var gone = before
    gone.mainClips = []
    require(VoiceChangeLanding.land(files, origin: origin, in: &gone) == .failure(.clipGone) && gone.audioTracks.count == 1,
            "a clip that was deleted meanwhile: nothing lands")
    var swapped = before
    swapped.update(main.id) { $0.sourceURL = URL(fileURLWithPath: "/media/other.mov") }
    let swappedBefore = swapped
    require(VoiceChangeLanding.land(files, origin: origin, in: &swapped) == .failure(.sourceChanged) && swapped == swappedBefore,
            "a clip that now uses another file: nothing lands, nothing is muted")
    var widened = before
    widened.update(main.id) { $0.sourceStart = 1; $0.sourceDuration = 8 }
    let widenedBefore = widened
    require(VoiceChangeLanding.land(files, origin: origin, in: &widened) == .failure(.notCovered) && widened == widenedBefore,
            "a clip trimmed outwards past what was sent: nothing lands")

    // 联动开着：挪主轨的原片段，压在它上面的两段新音频跟着走（联动的规矩 2：完全落在一段主轨块里的，挪它就挪）。
    var moved = state
    moved.update(main.id) { $0.timelineStart += 3 }
    _ = TimelineLinkage.follow(from: state, to: &moved, deletesContent: false)
    require(moved.clip(with: voice.id)?.timelineStart == 7 && moved.clip(with: background.id)?.timelineStart == 7,
            "with linkage on, the two new clips follow the original clip when it moves")
    // 真删原片段（⌫）：两段新音频跟着删。
    var deleted = state
    deleted.mainClips = []
    _ = TimelineLinkage.follow(from: state, to: &deleted, deletesContent: true)
    require(deleted.clip(with: voice.id) == nil && deleted.clip(with: background.id) == nil,
            "with linkage on, deleting the original clip deletes the two new clips with it")
}

// MARK: 下单的规则（纯值）

@MainActor
private func orderChecks() {
    let catalog = SkyStudioCatalog(json: VoiceRecoveryHTTP.catalog)
    require(catalog.map(VoiceChangeOrder.maxSourceSeconds(in:)) == 300, "the longest source comes from /models (300 s today)")
    let clip = { (seconds: Double) in EditClip(sourceURL: URL(fileURLWithPath: "/a.wav"), isAudioOnly: true, sourceDuration: seconds) }
    require(VoiceChangeSource.tooLong(clip(300.0004), limit: 300) == nil && VoiceChangeSource.tooLong(clip(300), limit: 300) == nil,
            "a clip of exactly the limit is accepted")
    require(VoiceChangeSource.tooLong(clip(301), limit: 300) == .tooLong(seconds: 301, limit: 300) && VoiceChangeSource.tooLong(clip(301), limit: nil) == nil,
            "a longer clip is refused; without a limit from Sky Studio nothing is refused locally")
    require(VoiceChangeProblem.tooLong(seconds: 301, limit: 300).message.contains("split_clip"), "the refusal tells the AI to split the clip first")
    var muted = clip(5)
    muted.isMuted = true
    let silentVideo = EditClip(sourceURL: URL(fileURLWithPath: "/a.mov"), sourceDuration: 5, info: MediaInfo(
        duration: 5, displaySize: .zero, frameRate: 30, videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1))
    require(VoiceChangeSource.refusal(for: clip(5)) == nil && VoiceChangeSource.refusal(for: muted) == .muted(name: "a")
            && VoiceChangeSource.refusal(for: silentVideo) == .noSound(name: "a"), "a muted clip and a clip without sound cannot be re-voiced")
    require(VoiceChangeSource.sampleRate(native: 48_000) == 48_000 && VoiceChangeSource.sampleRate(native: 96_000) == 48_000
            && VoiceChangeSource.sampleRate(native: 22_050) == 22_050 && VoiceChangeSource.sampleRate(native: nil) == 44_100,
            "the upload keeps the source's sample rate, 48 kHz at most")

    let sky = VoiceChangeTarget(id: VoiceChangeHTTP.voiceID, name: "Sky", languages: ["zh", "en"])
    require(VoiceChangeOrder.targetLanguage(spoken: "en", target: sky) == "en" && VoiceChangeOrder.targetLanguage(spoken: "ja", target: sky) == nil
            && VoiceChangeOrder.targetLanguage(spoken: nil, target: sky) == nil,
            "target_language only when the clip's language is known and the voice has a recording in it")
    let draft = try? VoiceChangeOrder.draft(target: sky, seconds: 4.00049, spoken: "en")
    require(draft?.kind == "voice_convert" && draft?.model == "auto" && draft?.params["target_voice"] == .string(sky.id)
            && draft?.params["source"]?["seconds"] == 4 && draft?.params["target_language"] == "en" && draft?.inputs.isEmpty == true,
            "the quote names the voice, the source seconds and the language; nothing is uploaded for it")
    require((try? VoiceChangeOrder.draft(target: sky, seconds: 4, spoken: "ja"))?.params["target_language"] == nil,
            "a language the voice has no recording in is not sent")
    if let voices = catalog?.voices, let charon = voices.preset("gemini:Charon") {
        let preset = VoiceChangeTarget(preset: charon)
        require(preset.id == "gemini:Charon" && preset.name == "Charon" && !preset.isLibraryVoice
                && preset.languages == Set(charon.languages.filter { $0.value.sampleURL != nil }.keys) && preset.languages.contains("zh"),
                "a preset's languages are the ones it has a sample in")
    } else { require(false, "the catalog fixture lists gemini:Charon") }

    // 两个文件叫什么、放哪。
    let original = URL(fileURLWithPath: "/media/采访 01.mov")
    let names = VoiceChangeOutputName.stems(original: original, voiceName: "Sky/2", backgroundLabel: "background")
    require(names.voice == "采访 01 - Sky-2" && names.background == "采访 01 - background", "<original> - <voice> and <original> - background")
    require(VoiceChangeOutputName.pathExtension(contentType: "audio/wav", url: URL(string: "https://a/b")!) == "wav"
            && VoiceChangeOutputName.pathExtension(contentType: "audio/mpeg", url: URL(string: "https://a/b.wav")!) == "mp3"
            && VoiceChangeOutputName.pathExtension(contentType: nil, url: URL(string: "https://a/b.flac")!) == "flac"
            && VoiceChangeOutputName.pathExtension(contentType: "application/octet-stream", url: URL(string: "https://a/b")!) == "wav",
            "the extension follows the content type, then the link, then wav")
    let taken: Set<String> = ["/media/采访 01 - Sky.wav"]
    let places = VoiceChangeOutputName.destinations(original: original, voiceName: "Sky", backgroundLabel: "background", voiceExtension: "wav",
        backgroundExtension: "wav", fallbacks: [], isWritable: { _ in true }, exists: { taken.contains($0.path) })
    require(places.voice.lastPathComponent == "采访 01 - Sky 2.wav" && places.background.lastPathComponent == "采访 01 - background.wav"
            && places.voice.deletingLastPathComponent().path == "/media", "files go next to the source and never replace one")
    let same = VoiceChangeOutputName.destinations(original: original, voiceName: "background", backgroundLabel: "background", voiceExtension: "wav",
        backgroundExtension: "wav", fallbacks: [], isWritable: { _ in true }, exists: { _ in false })
    require(same.voice != same.background, "a voice that happens to be called background does not collide with the background file")
    let readOnly = VoiceChangeOutputName.destinations(original: original, voiceName: "Sky", backgroundLabel: "background", voiceExtension: "wav",
        backgroundExtension: "wav", fallbacks: [URL(fileURLWithPath: "/home")], isWritable: { $0.path == "/home" }, exists: { _ in false })
    require(readOnly.voice.deletingLastPathComponent().path == "/home" && readOnly.background.deletingLastPathComponent().path == "/home",
            "a source folder that cannot be written falls back to the project's home")

    // 面板默认选哪个声音。
    let voice = { (id: String, source: String) -> SkyStudioVoice in
        try! SkyStudioVoice(json: VoiceChangeHTTP.voice("voice_" + String(repeating: id, count: 32), name: id, languages: ["zh"], source: source))
    }
    let a = voice("a", "recording"), b = voice("b", "recording"), d = voice("d", "design")
    require(VoiceChangePanelModel.defaultSelection(voices: [a, d], last: nil) == a.id, "one voice of my own: it is the default")
    require(VoiceChangePanelModel.defaultSelection(voices: [a, b, d], last: b.id) == b.id, "several: the one used last time")
    require(VoiceChangePanelModel.defaultSelection(voices: [a, b], last: nil) == nil
            && VoiceChangePanelModel.defaultSelection(voices: [a, b], last: d.id) == nil, "several and none used before: nothing is picked for the user")
    require(VoiceChangePanelModel.defaultSelection(voices: [d], last: d.id) == nil, "no voice of my own: nothing is picked, designed voices and presets stay selectable")
}

// MARK: change_voice 走全程

@MainActor
private func toolChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-tool"))
    let source = try fixture.stereoSource()
    let clipID = fixture.placeClip(source)
    let spent = SkyStudioSpendStore.shared.spentToday()
    let started = try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"])
    require(started.payload["status"] == "started" && started.payload["kind"] == "voice_change" && started.payload["credits"] == 9
            && started.payload["credits_expected"] == 6 && started.payload["voice_name"] == "Sky" && started.payload["target_language"] == "en",
            "change_voice returns a job id with the quoted price and what it will do: \(started.payload)")
    require(fixture.detections == 0, "a language given by the AI is used as is: nothing is detected")
    let quote = VoiceChangeHTTP.calls("POST", "/quote").first
    require(quote?["kind"] == "voice_convert" && quote?["model"] == "auto" && quote?["params"]?["target_voice"] == .string(VoiceChangeHTTP.voiceID)
            && quote?["params"]?["source"]?["seconds"] == 4 && quote?["params"]?["target_language"] == "en" && quote?["inputs"]?["source_audio_url"] == nil,
            "the quote is asked by source seconds before anything is uploaded: \(String(describing: quote))")
    let done = try await fixture.wait(started)
    require(done["status"] == "done", "the job finishes: \(done)")
    let log = VoiceChangeHTTP.log
    if let quoted = VoiceChangeHTTP.index("POST", "/quote"), let ticket = VoiceChangeHTTP.index("POST", "/uploads"),
       let submitted = VoiceChangeHTTP.index("POST", "/jobs") {
        require(quoted < ticket && ticket < submitted, "quote, then upload, then the job")
    } else { require(false, "quote, upload and job were all sent: \(log.map { $0.method + " " + $0.path })") }
    let ticket = VoiceChangeHTTP.calls("POST", "/uploads").first
    require(ticket?["purpose"] == "voice_convert_source" && ticket?["content_type"] == "audio/wav", "the source is uploaded as voice_convert_source")
    let header = VoiceChangeHTTP.uploaded.first.flatMap(WaveHeader.init)
    require(VoiceChangeHTTP.uploaded.count == 1 && header?.channels == 1 && header?.bits == 16 && header?.sampleRate == 48_000
            && header?.dataBytes == 4 * 48_000 * 2, "one mono 16-bit WAV at the source's rate, exactly the clip's 4 seconds: \(String(describing: header))")
    let jobs = VoiceChangeHTTP.calls("POST", "/jobs")
    require(jobs.count == 1 && jobs[0]["kind"] == "voice_convert" && jobs[0]["model"] == "auto" && jobs[0]["max_credits"] == 9
            && jobs[0]["inputs"]?["source_audio_url"] == "skystudio-private://voice/uploads/u/1.wav"
            && jobs[0]["params"]?["target_voice"] == .string(VoiceChangeHTTP.voiceID) && jobs[0]["params"]?["source"]?["seconds"] == 4
            && jobs[0]["params"]?["target_language"] == "en", "one voice_convert job, with the upload, the voice and the quote as max_credits: \(jobs)")

    // 落地：原段静音、两条新轨、链接、声音设置照抄、长的那 20 毫秒不上时间线。
    let state = fixture.project.state
    guard let original = state.clip(with: clipID), state.audioTracks.count == 3,
          let voice = state.audioTracks[1].clips.first, let background = state.audioTracks[2].clips.first else {
        return require(false, "the result lands on two new audio tracks: \(state.audioTracks.map(\.clips.count))")
    }
    require(original.isMuted && state.audioTracks[0].clips.map(\.id) == [clipID], "the original clip is muted and stays where it was")
    require(original.linkGroup != nil && voice.linkGroup == original.linkGroup && background.linkGroup == original.linkGroup, "the three clips are linked")
    for piece in [voice, background] {
        require(piece.timelineStart == 2 && piece.sourceStart == 0 && piece.sourceDuration == 4 && piece.speed == 1 && piece.volume == 0.7
                && piece.fadeInDuration == 0.2 && piece.fadeOutDuration == 0.3 && piece.volumeCurve.keys.map(\.time) == [0.5, 2],
                "\(piece.name) sits at the clip's place with its volume, fades and curve")
    }
    require(abs((voice.audioAssetDuration ?? 0) - 4.02) < 0.005 && voice.sourceDuration == 4, "the longer voice file is trimmed on the timeline only")
    // 「背景」那个词照界面语言写（这台机器的系统语言是什么就是什么）。
    require(voice.sourceURL.lastPathComponent == "talk - Sky.wav"
            && background.sourceURL.lastPathComponent == "talk - \(L10n("background (file name)")).wav"
            && voice.sourceURL.deletingLastPathComponent() == source.deletingLastPathComponent()
            && FileManager.default.fileExists(atPath: voice.sourceURL.path) && FileManager.default.fileExists(atPath: background.sourceURL.path),
            "the two files are saved next to the source: \(voice.sourceURL.lastPathComponent), \(background.sourceURL.lastPathComponent)")
    require(done["voice_clip_id"]?.stringValue == fixture.short(voice.id) && done["background_clip_id"]?.stringValue == fixture.short(background.id)
            && done["clip_id"]?.stringValue == fixture.short(clipID) && done["voice_track"] == "A2" && done["background_track"] == "A3"
            && done["model"] == "chatterbox-hd" && done["fallback_used"] == false && done["skystudio_job_id"] == "convert-1"
            && done["credits_charged"] == 7.5 && done["target_language"] == "en", "get_job reports the new clips, the model and the charge: \(done)")
    require(abs(SkyStudioSpendStore.shared.spentToday() - spent - 7.5) < 0.0001, "the books hold what Sky Studio charged, not the quote")
    require(!FileManager.default.fileExists(atPath: fixture.services.workFolder.path)
            || ((try? FileManager.default.contentsOfDirectory(atPath: fixture.services.workFolder.path)) ?? []).isEmpty,
            "the uploaded source is deleted when the job ends")
    require(!SkyStudioGenerationActivity.shared.runs.contains { $0.title == "talk" }, "a finished change leaves the cloud task list")
    require(!VoiceChangeActivity.shared.isChanging(clipID), "the clip is free to be changed again")
    require(fixture.project.notice == nil, "a change the AI started says nothing in the notice bar: the AI tells the user")

    // 预设当目标：不问声音库，照预设的 id 送；结果里提醒预设没验证过。
    let second = try VoiceChangeFixture(folder: root.appendingPathComponent("change-preset"))
    let other = second.placeClip(try second.stereoSource())
    second.detected = "zh"
    let preset = try await second.change(["clip_id": .string(second.short(other)), "voice": "charon"])
    require(preset.payload["voice"] == "gemini:Charon" && preset.payload["note"]?.stringValue?.contains("untested") == true
            && preset.payload["spoken_language"] == "zh" && preset.payload["target_language"] == "zh",
            "a preset is accepted by name, with a warning that it is untested: \(preset.payload)")
    require(!VoiceChangeHTTP.log.contains { $0.path.contains("/voices") } && second.detections == 1, "a preset target does not ask the voice library; the language is detected once")
    _ = try await second.wait(preset)
}

// MARK: 用哪种语言的参考

@MainActor
private func languageChecks(_ root: URL) async throws {
    // 检测出日语、目标声音没有日语的录音：不带 target_language，并说一声。
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-language"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    fixture.detected = "ja"
    let japanese = try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID)])
    require(fixture.detections == 1 && japanese.payload["spoken_language"] == "ja" && japanese.payload["target_language"] == nil
            && VoiceChangeHTTP.calls("POST", "/quote").first?["params"]?["target_language"] == nil
            && japanese.payload["note"]?.stringValue?.contains("Japanese") == true,
            "a detected language the voice has no recording in is not sent as target_language, and the result says so: \(japanese.payload)")
    let done = try await fixture.wait(japanese)
    require(done["status"] == "done" && VoiceChangeHTTP.calls("POST", "/jobs").first?["params"]?["target_language"] == nil
            && done["target_language"] == nil, "the job is sent without target_language too")

    // 检测不出来：不带。
    let unknown = try VoiceChangeFixture(folder: root.appendingPathComponent("change-language-unknown"))
    let second = unknown.placeClip(try unknown.stereoSource())
    let silent = try await unknown.change(["clip_id": .string(unknown.short(second)), "voice": .string(VoiceChangeHTTP.voiceID)])
    require(unknown.detections == 1 && silent.payload["spoken_language"] == nil
            && VoiceChangeHTTP.calls("POST", "/quote").first?["params"]?["target_language"] == nil
            && silent.payload["note"]?.stringValue?.contains("pass language") == true,
            "an undetected language sends no target_language and asks the AI to pass language: \(silent.payload)")
    _ = try await unknown.wait(silent)

    // AI 给的语言优先于本机检测（检测会说英文，根本不叫它）。
    let given = try VoiceChangeFixture(folder: root.appendingPathComponent("change-language-given"))
    let third = given.placeClip(try given.stereoSource())
    given.detected = "en"
    let chinese = try await given.change(["clip_id": .string(given.short(third)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "ZH"])
    require(given.detections == 0 && chinese.payload["target_language"] == "zh"
            && VoiceChangeHTTP.calls("POST", "/quote").first?["params"]?["target_language"] == "zh",
            "the AI's language wins over detection: \(chinese.payload)")
    _ = try await given.wait(chinese)
    do {
        _ = try await given.change(["clip_id": .string(given.short(third)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "english"])
        require(false, "a language that is not an ISO 639-1 code is refused")
    } catch let error as AIToolError {
        require(VoiceChangeHTTP.calls("POST", "/quote").count == 1, "a bad language code is refused before asking for a price: \(error.message)")
    }
}

// MARK: 收费之前停下来的

@MainActor
private func refusalChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-refusals"))
    let source = try fixture.stereoSource()
    let spent = SkyStudioSpendStore.shared.spentToday()
    func refused(_ args: JSONValue, _ what: String, saying phrase: String) async {
        do {
            let result = try await fixture.change(args)
            require(false, "\(what) is refused, not \(result.payload)")
        } catch let error as AIToolError {
            require(error.message.contains(phrase), "\(what): the refusal says \"\(phrase)\" (it says: \(error.message))")
        } catch {
            require(false, "\(what): unexpected \(error)")
        }
        require(VoiceChangeHTTP.calls("POST", "/uploads").isEmpty && VoiceChangeHTTP.calls("POST", "/jobs").isEmpty
                && SkyStudioSpendStore.shared.spentToday() == spent, "\(what): nothing is uploaded, started or charged")
    }

    // 超过一次的上限：在读文件、报价之前就拒。
    let long = fixture.placeClip(source, sourceStart: 0, sourceDuration: 301, assetSeconds: 400)
    await refused(["clip_id": .string(fixture.short(long)), "voice": .string(VoiceChangeHTTP.voiceID)], "a clip over the limit", saying: "split_clip")
    require(VoiceChangeHTTP.calls("POST", "/quote").isEmpty, "a clip over the limit is not even quoted")

    // 静音了的段。
    let muted = fixture.placeClip(source, muted: true)
    await refused(["clip_id": .string(fixture.short(muted)), "voice": .string(VoiceChangeHTTP.voiceID)], "a muted clip", saying: "muted")
    require(VoiceChangeHTTP.log.isEmpty || !VoiceChangeHTTP.log.contains { $0.path.hasSuffix("/quote") }, "a muted clip asks Sky Studio for no price")

    // 几乎没声音。
    let quiet = fixture.placeClip(try fixture.stereoSource("quiet.wav", silent: true))
    await refused(["clip_id": .string(fixture.short(quiet)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"], "an almost silent clip",
                  saying: "almost silent")
    require(VoiceChangeHTTP.calls("POST", "/quote").isEmpty, "an almost silent clip is not quoted")

    // 目标声音不对。
    let clipID = fixture.placeClip(source)
    await refused(["clip_id": .string(fixture.short(clipID)), "voice": "eleven:Daniel"], "an Eleven voice", saying: "list_voices")
    await refused(["clip_id": .string(fixture.short(clipID)), "voice": "Nobody"], "an unknown voice name", saying: "list_voices")

    // 声音库用不了：照实说、一分不花。
    VoiceChangeHTTP.lock.withLock {
        VoiceChangeHTTP.libraryFailure = (503, ["error": ["code": "voice_library_unavailable", "message": "Not configured.", "reason": "not_configured"]])
    }
    await refused(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID)], "an unavailable voice library",
                  saying: "not available right now")
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.libraryFailure = nil }

    // 每日硬预算：两种权限模式都拦，不发确认码、不起任务、不记账。
    SkyStudioSpendStore.shared.setDailyLimit(spent + 5)
    let blocked = try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"])
    require(blocked.payload["status"] == "blocked" && blocked.payload["code"] == "daily_budget_exceeded" && blocked.payload["confirm_token"] == nil
            && blocked.payload["job_id"] == nil, "over the daily limit nothing starts and no token is offered: \(blocked.payload)")
    require(VoiceChangeHTTP.calls("POST", "/uploads").isEmpty && VoiceChangeHTTP.calls("POST", "/jobs").isEmpty
            && SkyStudioSpendStore.shared.spentToday() == spent, "over the daily limit nothing is uploaded or charged")
    require(((try? FileManager.default.contentsOfDirectory(atPath: fixture.services.workFolder.path)) ?? []).isEmpty,
            "the prepared sound is deleted when nothing starts")
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    require(fixture.project.state.audioTracks.count == 1 && fixture.project.state.clip(with: clipID)?.isMuted == false,
            "nothing on the timeline changed")
}

// MARK: 一步撤销 / 重做

@MainActor
private func undoChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-undo"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    let done = try await fixture.wait(try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
    require(done["status"] == "done", "the change lands: \(done)")
    let after = fixture.project.state
    require(after != before && after.audioTracks.count == 3, "the timeline changed")
    guard let manager = fixture.project.effectiveUndoManager else { return require(false, "the project has an undo manager") }
    require(manager.canUndo, "the landing registered an undo step")
    // 落地是异步落账、不是用户事件：没包进 AIUndoGrouping.step 的话，按事件自动开的那一组在后台的 App 里关不上，之后 AI 的每一步都并进去。
    // 这个进程里主循环一直在转、那一组自己会关，所以「包没包」由扫描钉着（checks/MCP/router-wiring.sh）；这里钉的是结果：落地之后再做一步，两步各是各的。
    require(manager.groupingLevel == 0, "the landing leaves no undo group open behind it")
    _ = AIUndoGrouping.step(manager) { fixture.project.perform { $0.masterVolume = 0.5 } }
    manager.undo()
    require(fixture.project.state == after, "the next edit is its own undo step: undoing it leaves the changed voice in place")
    manager.undo()
    require(fixture.project.state == before, "one undo brings back the original sound: unmuted, no new tracks, no link")
    require(!manager.canUndo, "the landing was exactly one undo step")
    manager.redo()
    require(fixture.project.state == after, "one redo lands everything again")
    manager.redo()
    require(fixture.project.state.masterVolume == 0.5 && !manager.canRedo, "and the later edit is the only other redo step")
}

// MARK: 工程换了 / 这一段没了：只留文件

@MainActor
private func projectChangedChecks(_ root: URL) async throws {
    // 任务跑着的时候这一段被删了。
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-gone"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdJob = true; VoiceChangeHTTP.released = false }
    let started = try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"])
    await eventually("the job to be submitted") { !VoiceChangeHTTP.calls("POST", "/jobs").isEmpty }
    do {
        _ = try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"])
        require(false, "a clip that is already being changed is refused")
    } catch let error as AIToolError {
        require(error.message.contains("already") && VoiceChangeHTTP.calls("POST", "/jobs").count == 1, "the same clip is not sent twice: \(error.message)")
    }
    _ = AIUndoGrouping.step(fixture.project.effectiveUndoManager) { fixture.project.perform { $0.audioTracks = [] } }
    let emptied = fixture.project.state
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.released = true }
    let done = try await fixture.wait(started)
    require(done["status"] == "done" && done["landed"] == false && done["voice_clip_id"] == nil
            && done["next_step"]?.stringValue?.contains("no longer on the timeline") == true, "a deleted clip: the job says nothing landed: \(done)")
    require(fixture.project.state == emptied, "nothing lands when the clip is gone")
    let voiceFile = done["voice_file"]?.stringValue.map { URL(fileURLWithPath: $0) }
    require(voiceFile.map { FileManager.default.fileExists(atPath: $0.path) } == true && done["background_file"]?.stringValue != nil
            && done["credits_charged"] == 7.5, "the two files are kept and the charge is reported")

    // 任务跑着的时候工程换了（另开了一个工程）：不落到现在的工程上。
    let second = try VoiceChangeFixture(folder: root.appendingPathComponent("change-project"))
    let other = second.placeClip(try second.stereoSource())
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.holdJob = true; VoiceChangeHTTP.released = false }
    let running = try await second.change(["clip_id": .string(second.short(other)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"])
    await eventually("the job to be submitted") { !VoiceChangeHTTP.calls("POST", "/jobs").isEmpty }
    second.project.invalidateDocumentGeneration()
    let untouched = second.project.state
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.released = true }
    let kept = try await second.wait(running)
    require(kept["status"] == "done" && kept["landed"] == false && kept["next_step"]?.stringValue?.contains("no longer open") == true
            && kept["voice_file"]?.stringValue != nil, "a project that changed meanwhile only keeps the files: \(kept)")
    require(second.project.state == untouched && second.project.state.clip(with: other)?.isMuted == false, "another project's timeline is never touched")
}

// MARK: 没做成、结果不明

@MainActor
private func failureChecks(_ root: URL) async throws {
    // 服务器说没做成（它退了钱）：本机的那一笔退回，时间线不动，这一行留在云端任务浮层里。
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-failed"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let before = fixture.project.state
    let spent = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.jobFails = true }
    let failed = try await fixture.wait(try await fixture.change(["clip_id": .string(fixture.short(clipID)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
    require(failed["status"] == "failed" && failed["skystudio_job_id"] == "convert-1", "a job Sky Studio could not finish fails with its id: \(failed)")
    require(abs(SkyStudioSpendStore.shared.spentToday() - spent) < 0.0001, "a refunded job gives the reservation back")
    require(fixture.project.state == before, "a failed change leaves the timeline alone")
    let row = SkyStudioGenerationActivity.shared.runs.first { $0.title == "talk" && $0.issue != nil }
    require(row != nil, "a failed change stays in the cloud task list until the user dismisses it")
    if let row { SkyStudioGenerationActivity.shared.dismiss(row) }
    require(VoiceChangeHTTP.calls("POST", "/jobs").count == 1, "a failed job is not sent again")

    // 提交的回答丢了（断网）：结果不明，不重交，那一笔留在账上。
    let unknown = try VoiceChangeFixture(folder: root.appendingPathComponent("change-unknown"))
    let other = unknown.placeClip(try unknown.stereoSource())
    let base = SkyStudioSpendStore.shared.spentToday()
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.submitNetworkFailure = true }
    let lost = try await unknown.wait(try await unknown.change(["clip_id": .string(unknown.short(other)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]))
    require(lost["status"] == "failed" && VoiceChangeHTTP.calls("POST", "/jobs").count == 1, "a lost answer to the paid request is never sent again: \(lost)")
    require(abs(SkyStudioSpendStore.shared.spentToday() - base - 9) < 0.0001, "an unknown outcome keeps the reservation on the books")
    require(unknown.project.state.clip(with: other)?.isMuted == false && unknown.project.state.audioTracks.count == 1, "and the timeline is untouched")
    for row in SkyStudioGenerationActivity.shared.runs where row.issue != nil { SkyStudioGenerationActivity.shared.dismiss(row) }
    SkyStudioSpendStore.shared.refund(9, on: Date())
}

// MARK: 面板背后的那一份

@MainActor
private func panelChecks(_ root: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: root.appendingPathComponent("change-panel"))
    let clipID = fixture.placeClip(try fixture.stereoSource())
    let store = VoiceLibraryStore()
    store.readKey = { .success("local-voice-change-fixture") }
    store.api = fixture.api
    fixture.detected = "en"
    guard let model = VoiceChangePanelModel(project: fixture.project, clipID: clipID, store: store) else { return require(false, "the panel opens for a clip with sound") }
    model.services = fixture.services
    require(model.clipName == "talk" && model.clipSeconds == 4 && model.quote == nil, "the panel shows the clip and no price yet")
    await model.open()
    await eventually("the panel's quote") { model.quote != nil }
    require(model.selection == VoiceChangeHTTP.voiceID && model.spoken == "en" && model.target?.name == "Sky",
            "one voice of my own is picked by default, and the clip's language is detected")
    require(model.quote?.credits == 9 && model.quote?.creditsExpected == 6
            && VoiceChangeHTTP.calls("POST", "/quote").last?["params"]?["target_language"] == "en", "the price is asked once a voice is picked")
    require(VoiceChangeHTTP.calls("POST", "/uploads").isEmpty && VoiceChangeHTTP.calls("POST", "/jobs").isEmpty, "opening the panel uploads and starts nothing")
    require(!model.hasNoVoiceOfMine, "with a voice of my own there is no New Voice prompt")

    // 换一个声音：手里的报价作废、重新问（预设没有英文以外……照它有样音的语言带）。
    let quotes = VoiceChangeHTTP.calls("POST", "/quote").count
    model.selection = "gemini:Charon"
    require(model.quote == nil, "picking another voice drops the price in hand")
    await eventually("the new quote") { model.quote != nil }
    require(VoiceChangeHTTP.calls("POST", "/quote").count == quotes + 1
            && VoiceChangeHTTP.calls("POST", "/quote").last?["params"]?["target_voice"] == "gemini:Charon", "and asks again for the new voice")
    model.selection = VoiceChangeHTTP.voiceID
    await eventually("the quote for my voice") { model.quote != nil }

    // 每日额度不够：按不下去、不记账、不起任务。
    let spent = SkyStudioSpendStore.shared.spentToday()
    SkyStudioSpendStore.shared.setDailyLimit(spent + 5)
    require(model.overLimit(spend: SkyStudioSpendStore.shared), "a price over the daily limit is flagged")
    require(!model.start() && model.problem != nil && VoiceChangeHTTP.calls("POST", "/jobs").isEmpty
            && SkyStudioSpendStore.shared.spentToday() == spent, "over the daily limit the button starts nothing and records nothing")
    SkyStudioSpendStore.shared.setDailyLimit(100_000)

    // 按下「开始」就是确认：记账、起同一个任务、做完自动落地、提示条说一句；记住上次用的声音。
    let before = fixture.project.state
    require(model.start(), "the button starts the change")
    model.close()
    require(abs(SkyStudioSpendStore.shared.spentToday() - spent - 9) < 0.0001, "the quote is recorded when the button is pressed")
    await eventually("the change to land") { fixture.project.state.audioTracks.count == 3 }
    let job = VoiceChangeHTTP.calls("POST", "/jobs").first
    require(job?["kind"] == "voice_convert" && job?["max_credits"] == 9 && job?["params"]?["target_voice"] == .string(VoiceChangeHTTP.voiceID)
            && job?["params"]?["target_language"] == "en", "the panel sends the same voice_convert job as the AI's tool: \(String(describing: job))")
    require(fixture.project.state.clip(with: clipID)?.isMuted == true, "and it lands by itself: original muted, two new tracks")
    await eventually("the notice") { fixture.project.notice != nil }
    require(fixture.project.notice?.contains("Sky") == true, "the notice bar says which voice it was changed to: \(fixture.project.notice ?? "")")
    require(VoiceChangeActivity.shared.lastVoiceID == VoiceChangeHTTP.voiceID, "the voice used is remembered for next time")
    let manager = fixture.project.effectiveUndoManager
    manager?.undo()
    require(fixture.project.state == before && manager?.canUndo == false, "a change started from the panel is one undo step too")
    // 一份报价只起一单：任务做完、撤销回原声之后（这一段又能变了），同一个面板再按也不起第二单、不再记一笔。
    let settled = SkyStudioSpendStore.shared.spentToday()
    let pressedAgain = model.start()
    require(!pressedAgain && VoiceChangeHTTP.calls("POST", "/jobs").count == 1 && SkyStudioSpendStore.shared.spentToday() == settled,
            "the start button stays latched: one quote, one job, one charge (started again: \(pressedAgain), jobs: "
            + "\(VoiceChangeHTTP.calls("POST", "/jobs").count), spend \(settled) -> \(SkyStudioSpendStore.shared.spentToday()))")

    // 没有自己的声音：不替用户选，顶上有「新建声音…」；设计的声音照样能选。
    let empty = try VoiceChangeFixture(folder: root.appendingPathComponent("change-panel-empty"))
    let other = empty.placeClip(try empty.stereoSource())
    VoiceChangeHTTP.lock.withLock {
        let id = "voice_" + String(repeating: "d", count: 32)
        VoiceChangeHTTP.voices = [id: VoiceChangeHTTP.voice(id, name: "Designed", languages: ["en"], source: "design")]
    }
    let emptyStore = VoiceLibraryStore()
    emptyStore.readKey = { .success("local-voice-change-fixture") }
    emptyStore.api = empty.api
    guard let blank = VoiceChangePanelModel(project: empty.project, clipID: other, store: emptyStore) else { return require(false, "the panel opens") }
    blank.services = empty.services
    await blank.open()
    require(blank.selection == nil && blank.hasNoVoiceOfMine && blank.quote == nil && VoiceChangeHTTP.calls("POST", "/quote").isEmpty,
            "without a voice of my own nothing is picked and no price is asked")
    require(!blank.start(), "nothing starts without a voice")
    blank.close()
    require(((try? FileManager.default.contentsOfDirectory(atPath: empty.services.workFolder.path)) ?? []).isEmpty,
            "closing the panel without starting deletes the prepared sound")

    // 静音了的段不摆面板；超过上限的说为什么、不准备、不问价。
    let muted = empty.placeClip(try empty.stereoSource(), muted: true)
    require(VoiceChangePanelModel(project: empty.project, clipID: muted, store: emptyStore) == nil, "no panel for a muted clip")
    let long = empty.placeClip(try empty.stereoSource(), sourceStart: 0, sourceDuration: 301, assetSeconds: 400)
    if let tooLong = VoiceChangePanelModel(project: empty.project, clipID: long, store: emptyStore) {
        tooLong.services = empty.services
        await tooLong.open()
        if case .failed(let message) = tooLong.source { require(message.contains("5:00"), "a clip over the limit says the limit: \(message)") }
        else { require(false, "a clip over the limit is refused in the panel: \(tooLong.source)") }
        tooLong.close()
    } else { require(false, "the panel opens to say why") }
}

@MainActor
private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<1500 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, "timed out waiting for \(what)")
}
