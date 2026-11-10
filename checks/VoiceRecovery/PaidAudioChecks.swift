import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 付过钱的声音不许卡死（2026-11-10 声音 PR 3–5 的审查，docs/bugfixes/2026-11-10-*.md 那三个），真 App 对象 + 假协议 / 假转写。
// 每个场景修之前都以 local_split 失败、怎么恢复都一样：
// - 繁体中文稿合一批、转写写成简体：照样切开、字幕是稿子的繁体字；问转写时带的是 zh-Hant（起任务时、恢复时都是）；
// - 一句太长拆成两批、一批在服务器上换了备用：一片 24 kHz（Gemini 的 WAV）、一片 44.1 kHz（Eleven），两种先后都接得起来；
// - 这台 Mac 转写不了、整段点名 eleven-v4 合一批，Eleven 的 `words` 是 null / 对不回原文：按字数估句界，落地并说清楚哪几句是估的；
// 另外：任务里重新报过价之后，运行中和没做成的 get_job 也带 voice.note；点名 eleven-v4 读 Gemini 的预设时 voice.note 说实际是谁读的。

@MainActor
func runVoicePaidAudioChecks(_ root: URL) async {
    await scenario("resampling") { try resampleChecks() }
    await scenario("traditional script") { try await traditionalChecks(root) }
    await scenario("rates, fallback second") { try await mixedRateChecks(root, name: "rates-fallback-second", fallbackAt: 1) }
    await scenario("rates, fallback first") { try await mixedRateChecks(root, name: "rates-fallback-first", fallbackAt: 0) }
    await scenario("words null") { try await noWordTimesChecks(root, name: "words-null", broken: .null) }
    await scenario("words wrong") { try await noWordTimesChecks(root, name: "words-wrong", broken: .wrongLetters) }
    await scenario("voice note") { try await voiceNoteChecks(root) }
}

/// 一个场景抛了错只算它自己没过，后面的照跑（一处坏了不把别的守卫挡住）。
@MainActor
private func scenario(_ name: String, _ body: @MainActor () async throws -> Void) async {
    do { try await body() } catch { require(false, "\(name): \(error)") }
}

/// 换采样率：时长不变、开头对着开头（一下「嗒」还在原来那一刻）、音高不变。
@MainActor
private func resampleChecks() throws {
    var click = [Float](repeating: 0, count: 48_000)
    click[24_000] = 0.8
    let up = try SkyStudioVoiceLineAudio.resampled(click, from: 24_000, to: 44_100)
    let peak = up.indices.max { abs(up[$0]) < abs(up[$1]) } ?? 0
    require(up.count == 88_200 && abs(Double(peak) / 44_100 - 1) < 0.001,
            "resampling keeps the duration and where a click is (\(up.count) frames, click at \(Double(peak) / 44_100) s)")
    let tone = (0..<24_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 24_000)) * 0.5 }
    let toneUp = try SkyStudioVoiceLineAudio.resampled(tone, from: 24_000, to: 44_100)
    let crossings = zip(toneUp, toneUp.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
    require(abs(crossings - 440) <= 2, "a 440 Hz tone is still 440 Hz after resampling (\(crossings) cycles in one second)")
    var line = SkyStudioVoiceLineAudio()
    let first = try line.append(tone, sampleRate: 24_000)
    let second = try line.append([Float](repeating: 0.1, count: 44_100), sampleRate: 44_100)
    let third = try line.append(tone, sampleRate: 24_000)
    require(first == 0 && abs(second - 1) < 0.0001 && abs(third - 2) < 0.0001 && line.sampleRate == 44_100 && abs(line.duration - 3) < 0.0001,
            "parts at 24 kHz and 44.1 kHz join at the higher rate, each starting where the last one ended (\(second), \(third), \(line.duration) s)")
}

/// 繁体中文稿、三句合一批，转写写成简体（每句只有三到五成的字和稿子一模一样）。
@MainActor
private func traditionalChecks(_ root: URL) async throws {
    let lines = ["歡迎來到這門課程。", "今天我們學習剪輯影片。", "請記得訂閱頻道。"]
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("traditional"), cap: 800)
    fixture.failSplitOnce = false
    fixture.simplifies = true
    let done = try await fixture.wait(fixture.started(fixture.narrate(lines)))
    require(VoiceRecoveryHTTP.bodies("/jobs").count == 1, "three Traditional Chinese lines are read in one paid request")
    require(done["status"] == "done" && done["subtitle_timing"] == "aligned",
            "a Traditional Chinese batch transcribed in Simplified characters is still split into its lines "
            + "(got \(done["status"] ?? .null), \(done["failure_stage"] ?? .null): \(done["message"] ?? .null))")
    require(fixture.project.state.audioTracks.flatMap(\.clips).count == 3, "three clips land")
    let text = fixture.project.state.subtitleCues(of: .original).map(\.text).joined()
    require(text.contains("歡迎") && text.contains("學習") && !text.contains("欢迎") && !text.contains("学习"),
            "the subtitles keep the script's Traditional characters (got \(text))")
    require(fixture.transcriptionLanguages == ["zh-Hant"],
            "this Mac is asked for a Traditional Chinese transcriber, not zh (got \(fixture.transcriptionLanguages))")

    // 恢复时也照字形问（那时没有报价时留下的 locale）：第一次转写一个词都没有 → 切不开（转写得了的 Mac 上照旧报错、能恢复）。
    let resumed = try VoiceRecoveryFixture(folder: root.appendingPathComponent("traditional-resume"), cap: 800)
    resumed.failSplitOnce = false
    resumed.simplifies = true
    resumed.failSubtitleOnce = true
    let failed = try await resumed.wait(resumed.started(resumed.narrate(lines)))
    require(failed["status"] == "failed" && failed["failure_stage"] == "local_split", "an empty transcription still fails the split on a Mac that can transcribe")
    let recovered = try await resumed.resume(failed["recovery_file"]?.stringValue ?? "")
    require(recovered["status"] == "done" && VoiceRecoveryHTTP.posts == 1, "resume splits the kept audio without paying again")
    require(resumed.transcriptionLanguages == ["zh-Hant", "zh-Hant"],
            "resume also asks for the Traditional Chinese transcriber (got \(resumed.transcriptionLanguages))")
    require(AITextLanguage.speechLanguage("zh", texts: ["欢迎来到这门课程。", "你好"]) == "zh"
            && AITextLanguage.speechLanguage("zh", texts: ["你好"]) == "zh"
            && AITextLanguage.speechLanguage("en", texts: lines) == "en",
            "Simplified scripts, scripts that read the same either way and other languages keep their language")
}

/// 一句拆成两批、同时交，一批在服务器上换了备用（Eleven，44.1 kHz）、另一批是 Gemini 的 24 kHz WAV。
@MainActor
private func mixedRateChecks(_ root: URL, name: String, fallbackAt: Int) async throws {
    let line = "One two three four five six seven eight nine ten eleven twelve."
    let parts = try SkyStudioVoiceBatch.make(lines: [line], limit: 40, pack: false).map(\.prompt)
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent(name), cap: 40, audioSlots: 2)
    fixture.failSplitOnce = false
    VoiceRecoveryHTTP.deferred = true
    VoiceRecoveryHTTP.offerFallback = true
    VoiceRecoveryHTTP.promptIndex = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($0.element, $0.offset) })
    VoiceRecoveryHTTP.holdUntil = [0: 1]
    VoiceRecoveryHTTP.fallbackAt = fallbackAt
    VoiceRecoveryHTTP.lowRate = [1 - fallbackAt]
    let done = try await fixture.wait(fixture.started(fixture.narrate([line])))
    require(parts.count == 2 && VoiceRecoveryHTTP.posts == 2, "\(name): the long line is read in two paid batches")
    require(done["status"] == "done",
            "\(name): halves at 24 kHz and 44.1 kHz are joined, not failed "
            + "(got \(done["status"] ?? .null), \(done["failure_stage"] ?? .null): \(done["message"] ?? .null))")
    let clips = fixture.project.state.audioTracks.flatMap(\.clips)
    require(clips.count == 1 && abs((clips.first?.timelineDuration ?? 0) - 12) < 0.2,
            "\(name): one clip as long as both six-second halves (got \(clips.first?.timelineDuration ?? 0) s)")
    if let url = clips.first?.sourceURL, let file = try? AVAudioFile(forReading: url) {
        require(abs(file.fileFormat.sampleRate - 44_100) < 1, "\(name): the joined line keeps the higher sample rate (got \(file.fileFormat.sampleRate))")
    } else {
        require(false, "\(name): the joined line's file can be read")
    }
    let record = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: done["recovery_file"]?.stringValue ?? ""))
    let words = record.outputs[0]?.words ?? []
    let nine = words.first { $0.text.trimmingCharacters(in: .whitespaces) == "nine" }?.start ?? -1
    require(words.map(\.text).joined() == line && nine > 5.5 && nine < 7,
            "\(name): the second half's words start after the first half (nine at \(nine))")
    require(done["line_models"]?.arrayValue?.first?["fallback_used"] == true, "\(name): line_models says the fallback read part of the line")
}

/// 这台 Mac 转写不了：整段点名 eleven-v4、三句合一批，可它的 `words` 用不了。
@MainActor
private func noWordTimesChecks(_ root: URL, name: String, broken: VoiceRecoveryHTTP.BrokenWords) async throws {
    let lines = ["Hello world.", "Good night.", "See you soon."]
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent(name), cap: 800)
    fixture.failSplitOnce = false
    fixture.transcribes = false
    VoiceRecoveryHTTP.brokenWords = broken
    let done = try await fixture.wait(fixture.started(fixture.narrate(lines)))
    let jobs = VoiceRecoveryHTTP.bodies("/jobs")
    require(jobs.count == 1 && jobs.first?["model"] == "eleven-v4" && jobs.first?["prompt"]?.stringValue == lines.joined(separator: "\n"),
            "\(name): eleven-v4 reads the three lines in one paid batch")
    require(done["status"] == "done",
            "\(name): a packed batch without usable word times on a Mac that cannot transcribe still lands "
            + "(got \(done["status"] ?? .null), \(done["failure_stage"] ?? .null): \(done["message"] ?? .null))")
    let clips = fixture.project.state.audioTracks.flatMap(\.clips)
    let total = clips.reduce(0) { $0 + $1.timelineDuration }
    require(clips.count == 3 && clips.allSatisfy { $0.timelineDuration > 0.5 } && abs(total - 6) < 0.2,
            "\(name): the six seconds are cut into three clips (got \(clips.map(\.timelineDuration)))")
    require(done["subtitle_timing"] == "estimated" && done["estimated_split_line_indices"] == [0, 1, 2] && fixture.transcriptions == 0,
            "\(name): the result says the cuts and subtitle timing are estimated, and nothing was transcribed "
            + "(got \(done["subtitle_timing"] ?? .null), \(done["estimated_split_line_indices"] ?? .null))")
    let note = done["voice"]?["note"]?.stringValue ?? ""
    require(note.contains("listen to where those lines start and end") && done["next_step"]?.stringValue?.contains("estimated_split_line_indices") == true,
            "\(name): voice.note and next_step ask the AI to tell the user (got: \(note))")
    require(fixture.project.state.subtitleCues(of: .original).count >= 3, "\(name): each line keeps its subtitles")
}

/// 任务里重新报过价（装不上转写模型，整段换成 eleven-v4）：运行中和没做成之后的 get_job 都带 voice.note；点名 eleven-v4 时说实际是谁读的。
@MainActor
private func voiceNoteChecks(_ root: URL) async throws {
    let lines = ["Hello world.", "Good night."]
    let failing = try VoiceRecoveryFixture(folder: root.appendingPathComponent("note-after-failure"), cap: 800)
    failing.failSplitOnce = false
    failing.installed = false
    failing.installFailure = "No network for the speech model."
    VoiceRecoveryHTTP.cloudFailure = 0
    let failed = try await failing.wait(failing.started(failing.narrate(lines)))
    let failedNote = failed["voice"]?["note"]?.stringValue ?? ""
    require(failed["status"] == "failed" && failed["voice_plan"]?["selection"]?["model"] == "eleven-v4",
            "the re-quoted narration failed on Sky Studio (got \(failed["status"] ?? .null))")
    require(failedNote.contains("could not install") && failedNote.contains("eleven-v4") && failed["voice"]?["name"] == "gemini:Charon",
            "get_job after the failure still says why the script moved to eleven-v4 (got: \(failedNote))")

    let running = try VoiceRecoveryFixture(folder: root.appendingPathComponent("note-while-running"), cap: 800)
    running.failSplitOnce = false
    running.installed = false
    running.installFailure = "No network for the speech model."
    VoiceRecoveryHTTP.deferred = true
    VoiceRecoveryHTTP.holdUntil = [0: 99]
    let started = try running.started(await running.narrate(lines))
    guard let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("No job to watch") }
    for _ in 0..<400 where VoiceRecoveryHTTP.posts == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    let live = AIJobs.shared.json(job)
    let liveNote = live["voice"]?["note"]?.stringValue ?? ""
    require(VoiceRecoveryHTTP.posts == 1 && live["status"] == "running" && liveNote.contains("could not install") && liveNote.contains("eleven-v4"),
            "get_job while the re-quoted batch is running says why the script moved to eleven-v4 (got \(live["status"] ?? .null): \(liveNote))")
    VoiceRecoveryHTTP.release()
    let finished = try await running.wait(started)
    require(finished["status"] == "done", "the held batch finishes once released")

    let named = try VoiceRecoveryFixture(folder: root.appendingPathComponent("named-eleven"), cap: 800)
    named.failSplitOnce = false
    let namedStart = try named.started(await named.narrate(lines, model: "eleven-v4"))
    let namedNote = namedStart.payload["voice"]?["note"]?.stringValue ?? ""
    require(namedStart.payload["voice_plan"]?["selection"]?["voice"]?.stringValue?.hasPrefix("eleven:") == true
            && namedNote.contains("stands in for gemini:Charon") && namedNote.contains("sounds different"),
            "naming eleven-v4 for a Gemini preset: voice.note says which Eleven voice reads it and that it sounds different (got: \(namedNote))")
    _ = try await named.wait(namedStart)
}
