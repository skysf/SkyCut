import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：cut_speech（按文字剪、删停顿和口头禅，第 3 块的智能剪）
//
// 管什么：参数读成要剪掉的几截（`AISpeechCuts`，纯值），分两步：`plan` 可以 await（量这段声音 —— 画波形那一份数据；
// 读转写缓存 —— transcribe 那一份），`apply` 同步落到时间线上（路由包 `AIUndoGrouping.step`，一次调用 = 一步撤销，同 edit_clip）。
// 中途时间线变了（用户动了）就不落，请 AI 重来。AI 给的时间挪了多少、哪一刀附近没有停顿，结果里照实报（`moved`、`notes`）。
// 把切口挪进真的停顿按**整个素材文件**的电平、门限和词判（`AISpeechHearing`，listen cuts=true 同一份，读法也在这里：
// `wholeFile` / `transcript`）；删停顿照旧量这段片段。
// 不管什么：切口落在哪（AISpeechCutPoints）、要剪哪几截、怎么切（AISpeechCuts）、说明文字（SrtFlowMCPKit/MCPSmartEditTools.swift）。
//
// 只剪 V1 上的片段（口播），链接的声音跟着剪。声音从片段自己来；它静音了、声音分离到了音频轨上，就用链接的那段声音。

@MainActor
enum AISpeechCutTool {
    struct Plan {
        var clipID: UUID
        var cuts: [AISpeechCuts.Cut]
        /// AI 给的时间挪了超过 50ms 的。
        var moved: [AISpeechCutPoints.Move]
        var state: TimelineState
        var generation: Int
        var notes: [String]
    }

    static func plan(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> Plan {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let clipID = try ids.resolve(try args.requiredString("clip_id"))
        guard let clip = state.clip(with: clipID) else { throw AIToolError("There is no clip \(try args.requiredString("clip_id")).") }
        guard state.location(of: clipID)?.track == .main else {
            throw AIToolError("cut_speech works on V1 clips (the talking clip). Move \(clip.name) to V1 first.")
        }
        let range = clip.timelineStart...clip.timelineEnd
        let remove = try ranges(args, "remove")
        let keep = try ranges(args, "keep")
        guard remove == nil || keep == nil else { throw AIToolError("Give remove or keep, not both.") }
        if let keep, keep.isEmpty { throw AIToolError("keep is empty: that would cut the whole clip. Use delete_items for that.") }
        let pauseLength = try args.double("remove_pauses")
        let fillers = try args.bool("remove_fillers") ?? false
        let repeats = try args.bool("remove_repeats") ?? false
        guard remove != nil || keep != nil || pauseLength != nil || fillers || repeats else {
            throw AIToolError("Say what to cut: remove, keep, remove_pauses, remove_fillers or remove_repeats.")
        }
        let snaps = try args.bool("snap") ?? true
        let speech = speechClip(of: clip, in: state)
        let transcript = await transcript(of: speech, in: state, language: try args.string("language") ?? "auto")
        // 口头禅、重复词在这段片段里认（时间线秒）；切口判在哪用整个文件的词（AISpeechHearing）。
        let words = transcript.map { SpeechTranscript.sentences(words: $0.words, window: $0.window).flatMap(\.words) }
        if (fillers || repeats), words == nil {
            throw AIToolError("Filler words and repeats come from the transcript: call transcribe on this clip first, then try again.")
        }
        let asked = (remove ?? []) + (keep ?? [])
        // 声音：删停顿要量它；切口也按它挪进真的停顿（只按给的时间剪、又说了 snap=false 时不用读）。
        let readsSound = pauseLength != nil || fillers || repeats || (!asked.isEmpty && snaps)
        let peaks = readsSound ? try await soundOf(speech) : nil
        let silenceDB = try args.double("silence_db")
        // 切口找停顿：整个文件的电平和词、按整个文件量的门限（AI 给了 silence_db 就用它），和 listen cuts=true 判的是同一份。
        let hearing = AISpeechHearing(levels: peaks.map { AIAudioLevels.windows($0, from: 0, to: $0.duration) }, transcript: transcript?.words)
        let points = hearing.points(silenceDB: silenceDB, snaps: snaps, clip: speech)
        var cuts: [AISpeechCuts.Cut] = []
        if let remove { cuts += AISpeechCuts.requested(remove, points: points) }
        if let keep { cuts += AISpeechCuts.outside(keep, clip: range, points: points) }
        if let pauseLength {
            // 删停顿量这段片段（门限没给就从这一段自己量）。
            guard let peaks else { throw AIToolError("SrtFlow could not read the sound of \(speech.name).") }
            let levels = clipLevels(peaks, of: speech)
            let measured = AISpeechCuts.silenceThreshold(levels.map(\.decibels))
            let leave = min(max(try args.double("pause_left") ?? 0.25, 0), 2)
            let longer = max(pauseLength, 0.2)
            let found = AIAudioLevels.report(levels, silenceDB: silenceDB ?? measured, minSilence: longer).silences
            cuts += AISpeechCuts.pauses(found, longerThan: longer, leave: leave)
        }
        if fillers, let words { cuts += AISpeechCuts.fillerWords(words, points: points) }
        if repeats, let words { cuts += AISpeechCuts.repeats(words, points: points) }
        let frame = state.frameRate.secondsPerFrame
        let report = points.report(asked, clip: range, frame: frame)
        let notes = asked.isEmpty || !snaps ? [] : snapNotes(transcript: words != nil, sound: peaks != nil, onSpeech: report.onSpeech)
        return Plan(
            clipID: clipID, cuts: AISpeechCuts.merged(cuts, clip: range, frame: frame), moved: report.moved,
            state: state, generation: project.documentGeneration, notes: notes
        )
    }

    /// 按给的时间剪时：切口靠什么挪的（没转写 / 读不到声音时少一样），哪几刀附近没有停顿、可能切到字。
    private static func snapNotes(transcript: Bool, sound: Bool, onSpeech: [Double]) -> [String] {
        var notes: [String] = []
        switch (transcript, sound) {
        case (false, true):
            notes.append("No transcript yet: cut points on speech moved into the nearest pause by sound alone. Call transcribe first so cuts also know where the words are.")
        case (true, false):
            notes.append("SrtFlow could not read this clip's sound, so cut points follow the transcript only; its word times can be 0.1-0.3 s off around pauses.")
        case (false, false):
            notes.append("No transcript and no readable sound: cuts are exactly at the given times.")
        case (true, true):
            break
        }
        if !onSpeech.isEmpty {
            let times = onSpeech.map { String(format: "%.3f", $0) }.joined(separator: ", ")
            notes.append("No pause near the cut at \(times) s, so it may clip a word: check it with listen, or pass a time inside a pause.")
        }
        return notes
    }

    static func apply(_ plan: Plan, _ project: VideoEditProject) throws -> AIToolResult {
        guard project.isCurrentGeneration(plan.generation), project.state == plan.state else {
            throw AIToolError("The timeline changed while SrtFlow was measuring. Call cut_speech again.")
        }
        let ids = AIShortIDs(state: plan.state)
        var result: [String: JSONValue] = [:]
        if !plan.notes.isEmpty { result["notes"] = .array(plan.notes.map { .string($0) }) }
        guard !plan.cuts.isEmpty else {
            result["removed"] = .array([])
            result["note"] = "Nothing to cut: no range, pause, filler or repeat matched."
            return .ok(.object(result))
        }
        var next = plan.state
        let pieces = AISpeechCuts.apply(plan.cuts, to: plan.clipID, in: &next)
        // 真删：联动开着时压在剪掉那几块上的东西一起删、后面的跟着画面前移。
        let linkage = project.perform(deletesContent: true) { $0 = next }
        let state = project.state
        let now = AIShortIDs(state: state)
        result["clip"] = .string(ids.short(plan.clipID))
        result["removed"] = .array(plan.cuts.map { cut in
            ["start": AIFormat.seconds(cut.start), "end": AIFormat.seconds(cut.end), "why": .string(cut.reason)]
        })
        if !plan.moved.isEmpty {
            result["moved"] = .array(plan.moved.map { move in
                ["asked": AIFormat.seconds(move.asked), "cut_at": AIFormat.seconds(move.cutAt), "why": .string(move.why)]
            })
        }
        result["removed_seconds"] = AIFormat.seconds(plan.cuts.reduce(0) { $0 + $1.end - $1.start })
        result["pieces"] = .array(pieces.compactMap { id in
            state.clip(with: id).map { piece in
                ["id": .string(now.short(id)), "start": AIFormat.seconds(piece.timelineStart), "end": AIFormat.seconds(piece.timelineEnd)]
            }
        })
        result["timeline_duration"] = AIFormat.seconds(state.duration)
        if let followed = AILinkageReport.json(linkage, ids: now) { result["linkage"] = followed }
        if let packed = AILinkageReport.magnet(linkage) { result["magnet"] = packed }
        result["next_step"] = .string(project.linkageEnabled
            ? "Removed times are where they were before the cut. Later V1 clips moved left and, with Linkage on, subtitles, "
                + "texts and sounds sitting on the clip moved with its pieces; those sitting only on a removed part were deleted. "
                + "A subtitle across a cut shrank to the speech left under it (deleted when less than half was left). "
                + "Music spanning several clips stays."
            : "Removed times are where they were before the cut. Later V1 clips moved left; music, texts and subtitles did "
                + "not move (Linkage is off) — regenerate subtitles if the clip had them (the transcript is cached, so it is quick)."
        )
        AIEditorPresenter.reveal(.init(clips: Set(pieces), time: plan.cuts.first?.start), project: project)
        return .ok(.object(result), changed: true)
    }

    // MARK: 参数

    private static func ranges(_ args: AIToolArguments, _ key: String) throws -> [ClosedRange<Double>]? {
        try args.array(key).map { items in
            try items.enumerated().map { index, item in
                let entry = AIToolArguments(item)
                let start = try entry.requiredDouble("start")
                let end = try entry.requiredDouble("end")
                guard end > start else { throw AIToolError("\(key)[\(index)]: end must be after start.") }
                return start...end
            }
        }
    }

    // MARK: 声音从哪来

    /// 听哪一段：片段自己有声音就是它；静音了 / 声音分离出去了，就是链接的、同一时间在放的那段声音。
    /// listen cuts=true（AIListenCuts）查剪辑点时也用它：声音从哪段来只有这一份。
    static func speechClip(of clip: EditClip, in state: TimelineState) -> EditClip {
        func audible(_ candidate: EditClip) -> Bool { candidate.hasAudio && !candidate.isMuted && candidate.volume > 0 }
        if audible(clip) { return clip }
        let partners = state.linkedClipIDs(of: clip.id).compactMap(state.clip(with:))
            .filter { $0.id != clip.id && $0.timelineStart < clip.timelineEnd && clip.timelineStart < $0.timelineEnd }
        return partners.first(where: audible) ?? clip
    }

    // MARK: 听这段声音（listen cuts=true 也用：AIListenCuts）

    /// 这段声音的转写缓存：整个文件的词（识别器原样的源秒）和这段在时间线上的窗口。只读缓存，没转写过（或没盖住这一段）是 nil。
    static func transcript(
        of sound: EditClip, in state: TimelineState, language: String
    ) async -> (words: [TimedWord], window: SubtitleClipWindow)? {
        guard #available(macOS 26.0, *),
              let audible = SubtitleAudibleClips.soundClips(in: state, only: [sound.id]).first,
              let cached = await AITranscribeTool.cached([audible], language: language),
              let words = cached.entries[audible.fingerprint]?.words else { return nil }
        return (words, AITranscribeTool.Target(sound: audible, id: nil, track: nil).window)
    }

    /// 整个文件的波形读到哪了：判切口按整个文件量（AISpeechHearing），要读完。
    enum WholeFile {
        case ready(WaveformPeaks)
        /// 到 `deadline` 还没读完。
        case reading
        /// 没有声音 / 读不出来。
        case unreadable
    }

    /// 这段声音整个文件的波形（画波形那一份数据，和 listen 同一份窗），最多等到 `deadline`。
    static func wholeFile(of sound: EditClip, until deadline: Date) async -> WholeFile {
        guard sound.hasAudio, let peaks = await AIListenTool.waveform(of: sound.sourceURL, until: deadline) else { return .unreadable }
        return peaks.isComplete || peaks.duration >= sound.assetDuration - 0.01 ? .ready(peaks) : .reading
    }

    /// cut_speech 要读的波形：没有声音、读不出来是 nil；还没读完就请 AI 等一会儿再调。
    private static func soundOf(_ clip: EditClip) async throws -> WaveformPeaks? {
        switch await wholeFile(of: clip, until: Date().addingTimeInterval(AIListenTool.waitSeconds)) {
        case .ready(let peaks): return peaks
        case .unreadable: return nil
        case .reading: throw AIToolError("SrtFlow is still reading the sound of \(clip.name). Call cut_speech again in a moment.")
        }
    }

    /// 这段片段按窗的电平（时间线秒）：删停顿量它。
    private static func clipLevels(_ peaks: WaveformPeaks, of clip: EditClip) -> [AIAudioLevels.Window] {
        AIAudioLevels.windows(peaks, from: clip.sourceStart, to: clip.sourceStart + clip.sourceDuration).map { window in
            var placed = window
            placed.start = clip.timelineTime(atSource: window.start)
            placed.end = clip.timelineTime(atSource: window.end)
            return placed
        }
    }
}
