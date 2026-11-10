import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 字幕时间（声音 PR 5，SkyCut 声音方案第七节、8.1），真 App 对象 + 假协议 / 假转写：
// - 几句合一批、在这台 Mac 上转写切开、字幕对到原文上（显示稿子的字，不显示听成的字）；
// - 这台 Mac 转写不了：预设要字幕整段改点名 eleven-v4（按它的字符时间切、不转写）；点名的模型、声音库的声音一句一单、按字数估；
// - 模型没装：交第一批之前先装（付费请求之前）；装不上当转写不了，再报一次价（第一笔预留退回）；
// - 一句的转写对不上：这一句按字数估、整段不失败（subtitle_timing mixed、estimated_line_indices）。

@MainActor
func runVoiceRecoveryTimingChecks(_ root: URL) async throws {
    try await packingChecks(root)
    try await cannotTranscribeChecks(root)
    try await installChecks(root)
    try await lineFallbackChecks(root)
}

private let twoLines = ["Hello world.", "Good night."]

@MainActor
private func packingChecks(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("packed"), cap: 800)
    fixture.failSplitOnce = false
    let lines = ["Welcome to the course.", "First, open the project.", "Then add a clip."]
    let started = try fixture.started(await fixture.narrate(lines))
    require(VoiceRecoveryHTTP.bodies("/quote").last?["params"]?["batches"] == [.string(lines.joined(separator: "\n"))],
            "narration packs whole lines into one batch when this Mac can split them")
    require(started.payload["subtitle_timing"] == "aligned", "job_id says the subtitles will be aligned on this Mac")
    let done = try await fixture.wait(started)
    require(done["status"] == "done" && VoiceRecoveryHTTP.bodies("/jobs").count == 1, "one paid request reads all three lines")
    require(done["subtitle_timing"] == "aligned", "the result reports aligned subtitle timing (got \(done["subtitle_timing"] ?? .null))")
    let clips = fixture.project.state.audioTracks.flatMap(\.clips)
    let cues = fixture.project.state.subtitleCues(of: .original)
    require(clips.count == 3 && clips.allSatisfy { clip in cues.contains { $0.start >= clip.timelineStart - 0.01 && $0.start < clip.timelineEnd } },
            "the batch is split back into three clips, each with its subtitles (got \(clips.count) clips, \(cues.count) subtitles)")

    let heard = try VoiceRecoveryFixture(folder: root.appendingPathComponent("script-words"), cap: 800)
    heard.failSplitOnce = false
    heard.mishear = ["SkyCut": "Sky cut", "20": "twenty"]
    let wordsDone = try await heard.wait(heard.started(heard.narrate(["SkyCut makes 20 videos a day"])))
    let text = heard.project.state.subtitleCues(of: .original).map(\.text).joined(separator: " ")
    require(wordsDone["status"] == "done" && text.contains("SkyCut") && text.contains("20") && !text.contains("Sky cut") && !text.contains("twenty"),
            "subtitles show the script's words, not what this Mac's transcription heard (got \(text))")
}

@MainActor
private func cannotTranscribeChecks(_ root: URL) async throws {
    let eleven = try VoiceRecoveryFixture(folder: root.appendingPathComponent("eleven-timing"), cap: 800)
    eleven.failSplitOnce = false
    eleven.transcribes = false
    let started = try eleven.started(await eleven.narrate(twoLines))
    let quote = VoiceRecoveryHTTP.bodies("/quote").last
    require(quote?["model"] == "eleven-v4" && quote?["params"]?["voice"] == "gemini:Charon"
            && quote?["params"]?["batches"] == [.string(twoLines.joined(separator: "\n"))],
            "a preset with subtitles this Mac cannot transcribe: the whole script names eleven-v4, packed (got \(quote ?? .null))")
    let note = started.payload["voice"]?["note"]?.stringValue ?? ""
    require(note.contains("eleven-v4") && note.contains("Eleven voice"), "voice.note says the whole script switched voice (got: \(note))")
    let done = try await eleven.wait(started)
    let jobs = VoiceRecoveryHTTP.bodies("/jobs")
    require(done["status"] == "done" && done["subtitle_timing"] == "provider" && jobs.count == 1
            && jobs.first?["model"] == "eleven-v4" && jobs.first?["params"]?["plan"]?["model"] == "eleven-v4",
            "eleven-v4 reads it in one batch and its character times give the subtitle timing")
    require(eleven.transcriptions == 0, "Eleven's character times split the batch; nothing is transcribed")
    require(eleven.project.state.audioTracks.flatMap(\.clips).count == 2 && eleven.project.state.subtitleCues(of: .original).count >= 2,
            "two clips, each with subtitles")

    let named = try VoiceRecoveryFixture(folder: root.appendingPathComponent("named-estimated"), cap: 800)
    named.failSplitOnce = false
    named.transcribes = false
    let estimated = try named.started(await named.narrate(twoLines, model: "gemini-3.8-flash-tts"))
    require(VoiceRecoveryHTTP.bodies("/quote").last?["params"]?["batches"] == .array(twoLines.map(JSONValue.string))
            && VoiceRecoveryHTTP.bodies("/quote").last?["model"] == "gemini-3.8-flash-tts",
            "a named model is kept, and lines this Mac cannot split go one per request")
    require(estimated.payload["subtitle_timing"] == "estimated"
            && estimated.payload["voice"]?["note"]?.stringValue?.contains("estimated from character counts") == true,
            "job_id says the subtitle timing will be estimated")
    let estimatedDone = try await named.wait(estimated)
    require(estimatedDone["status"] == "done" && estimatedDone["subtitle_timing"] == "estimated" && named.transcriptions == 0
            && named.project.state.subtitleCues(of: .original).count >= 2, "the narration finishes with estimated subtitles")

    let library = try VoiceRecoveryFixture(folder: root.appendingPathComponent("library-estimated"), cap: 800)
    library.failSplitOnce = false
    library.transcribes = false
    let libraryDone = try await library.wait(library.clone(twoLines))
    require(libraryDone["status"] == "done" && libraryDone["subtitle_timing"] == "estimated" && VoiceRecoveryHTTP.bodies("/jobs").count == 2
            && library.transcriptions == 0, "a library voice this Mac cannot transcribe: one line per request, estimated, never Eleven")
}

@MainActor
private func installChecks(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("install"), cap: 800)
    fixture.failSplitOnce = false
    fixture.installed = false
    let started = try fixture.started(await fixture.narrate(twoLines))
    require(started.payload["next_step"]?.stringValue?.contains("installs this Mac's speech model") == true,
            "job_id says the speech model is installed first")
    let done = try await fixture.wait(started)
    require(done["status"] == "done" && fixture.installs == [0], "the model is installed once, before any paid batch (got \(fixture.installs))")
    require(done["subtitle_timing"] == "aligned" && VoiceRecoveryHTTP.bodies("/jobs").count == 1, "then the packed batch is split and aligned")

    let failing = try VoiceRecoveryFixture(folder: root.appendingPathComponent("install-fails"), cap: 800)
    failing.failSplitOnce = false
    failing.installed = false
    failing.installFailure = "No network for the speech model."
    let spent = SkyStudioSpendStore.shared.spentToday()
    let failed = try await failing.wait(failing.started(failing.narrate(twoLines)))
    let quotes = VoiceRecoveryHTTP.bodies("/quote")
    require(quotes.count == 2 && quotes[0]["model"] == "auto" && quotes[1]["model"] == "eleven-v4",
            "the model cannot be installed: asked for a price again, as if this Mac cannot transcribe (eleven-v4 for the subtitles)")
    let note = failed["voice"]?["note"]?.stringValue ?? ""
    require(failed["status"] == "done" && failed["subtitle_timing"] == "provider" && failing.transcriptions == 0
            && note.contains("could not install") && note.contains("No network for the speech model") && note.contains("eleven-v4"),
            "it finishes on eleven-v4 and voice.note says why (got: \(note))")
    require(VoiceRecoveryHTTP.bodies("/jobs").count == 1 && VoiceRecoveryHTTP.bodies("/jobs").first?["model"] == "eleven-v4",
            "only the new plan was sent")
    require(SkyStudioSpendStore.shared.spentToday() == spent + 2.5, "the first reservation went back; only what was read was charged")
}

@MainActor
private func lineFallbackChecks(_ root: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("mixed-timing"), cap: 12)
    fixture.failSplitOnce = false
    fixture.garbleAt = 1
    let done = try await fixture.wait(fixture.started(fixture.narrate(twoLines)))
    require(done["status"] == "done" && done["subtitle_timing"] == "mixed" && done["subtitles"]?["estimated_line_indices"] == [1],
            "a line whose transcription does not match is estimated; the narration still finishes (got \(done["subtitle_timing"] ?? .null))")
    require(done["voice"]?["note"]?.stringValue?.contains("1 of 2 lines") == true, "voice.note says which part is estimated")
    require(fixture.project.state.subtitleCues(of: .original).count >= 2 && VoiceRecoveryHTTP.posts == 2,
            "both lines keep their subtitles and nothing is paid again")
}
