import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：listen（「听」）
//
// 管什么：AI 听不见，就把声音量给它：一段片段在成片里听到的（段音量 / 曲线、渐入渐出、轨道推子都算上）、一个素材文件、
// 或者整条时间线上每一段有声音的片段 —— 电平（有声音部分的 RMS）、真峰值（dBTP）、静音段、最响的那一帧、一条粗的响度曲线；
// 要鼓点时（beats，只对一段片段或一个文件）再给速度、每一拍、小节头（AIBeats，另读一遍 11025 Hz 的单声道）。
// Since 2026-11-17 a clip or a file is measured from one bounded read of exactly its window (AIListenAudioWindow): the true
// peak and the loudest frame need the samples, at the project's frame rate (AIListenFrameGrid). Files go through AIListenFileAudio.
// mix=true 交给 AIListenMix：用音频引擎按层离线渲，量混在一起之后的声音（每层、每帧、每个频段，整条的响度和过线），到帧。
// voice=… goes to AIListenVoiceCheck: each narration line's ESTOI against the mix and who covers it (2026-11-17, MCP-39);
// describe=true to AIListenSourceSound: a clip's own sound in words (traits, the classifier's labels, words heard).
// 不管什么：怎么算（AIAudioLevels）、文件怎么读（AIListenFileAudio）、说明文字（SrtFlowMCPKit/MCPSenseTools.swift）。
//
// 只读：不改工程、不动界面。点名文件夹以外的文件照「动硬盘才问」的规矩先问。

@MainActor
enum AIListenTool {
    /// 一次调用最多等多久（客户端对一次调用大多只等一分钟）。整条时间线没量完的段说一声，让 AI 一段一段地问。
    nonisolated static let waitSeconds = 40.0
    /// 整条时间线一次最多列多少段。
    static let maxClips = 80

    static func listen(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let silenceDB = min(max(try args.double("silence_db") ?? AIAudioLevels.defaultSilenceDB, -80), -10)
        let minSilence = min(max(try args.double("min_silence") ?? 0.5, 0.1), 10)
        var settings = Settings(silenceDB: silenceDB, minSilence: minSilence, beats: try args.bool("beats") ?? false)
        settings.grid = AIListenFrameGrid(fps: project.state.frameRate.fps)
        // from / to：时间线上的几秒（2026-10-14 用户拍板「只听某几秒」）。文件的几秒照旧用 source_in / source_out。
        settings.from = try args.double("from").map { max(0, $0) }
        settings.to = try args.double("to")
        if let from = settings.from, let to = settings.to, to <= from { throw AIToolError("to must be after from.") }
        // voice=…: is each line of the narration covered? (AIListenVoiceCheck; 2026-11-17, MCP-39.)
        if let voice = try args.string("voice") {
            return try await AIListenVoiceCheck.listen(args, project, spec: voice, from: settings.from, to: settings.to)
        }
        // describe=true: what is in a clip's own sound, in words (AIListenSourceSound; 2026-11-17, MCP-42 / MCP-44).
        if try args.bool("describe") ?? false {
            return try await AIListenSourceSound.listen(args, project, from: settings.from, to: settings.to)
        }
        // mix=true：用引擎按层量混在一起之后的声音，到帧（AIListenMix；2026-11-16，MCP-3 / MCP-10）。
        if try args.bool("mix") ?? false {
            return try await AIListenMix.listen(
                args, project, from: settings.from, to: settings.to, silenceDB: settings.silenceDB, minSilence: settings.minSilence
            )
        }
        if try args.stringArray("layers") != nil || (try args.bool("frames") ?? false) {
            throw AIToolError("layers and frames go with mix=true.")
        }
        // cuts=true：V1 的每个剪辑点一次查完（AIListenCuts）。门限不给就按每段自己量的（同 cut_speech），所以单独读。
        if try args.bool("cuts") ?? false {
            guard try args.string("clip_id") == nil, try args.string("file") == nil else {
                throw AIToolError("cuts=true checks every cut on V1: leave clip_id and file out (from/to narrow it).")
            }
            guard !settings.beats else { throw AIToolError("beats and cuts are separate: call listen twice.") }
            return .ok(try await AIListenCuts.check(
                project.state, AIShortIDs(state: project.state), from: settings.from, to: settings.to,
                silenceDB: try args.double("silence_db"), deadline: Date().addingTimeInterval(waitSeconds)
            ))
        }
        if let path = try args.string("file") {
            guard settings.from == nil, settings.to == nil else {
                throw AIToolError("from/to are timeline seconds; for part of a file use source_in/source_out.")
            }
            return try await listenToFile(path, args, project, settings)
        }
        let state = project.state
        let ids = AIShortIDs(state: state)
        if let clipText = try args.string("clip_id") {
            let id = try ids.resolve(clipText)
            guard let clip = state.clip(with: id) else { throw AIToolError("\(clipText) is not a clip.") }
            guard AIAudioLevels.sourceWindow(of: clip, from: settings.from, to: settings.to) != nil else {
                throw AIToolError(String(
                    format: "%@ plays from %.2f to %.2f s, outside from/to.", ids.short(id), clip.timelineStart, clip.timelineEnd
                ))
            }
            return .ok(.object(await listenToClip(clip, state, ids, settings, detailed: true)))
        }
        guard !settings.beats else { throw AIToolError("beats needs a clip_id (a music clip) or a file.") }
        return .ok(try await listenToTimeline(state, ids, settings))
    }

    private struct Settings {
        var silenceDB: Double
        var minSilence: Double
        /// The project's frames: `loudest_at` and `peak_at` are to the frame.
        var grid = AIListenFrameGrid(fps: 30)
        /// 也找鼓点（速度、每一拍、小节头；AIBeats）。只对一段片段或一个文件。
        var beats = false
        /// 只听时间线上的这几秒（from / to）；nil = 不限。片段只量落在里面的那一截，整条时间线只列落在里面的片段。
        var from: Double?
        var to: Double?
        var narrowed: Bool { from != nil || to != nil }
    }

    // MARK: 片段

    private static func listenToClip(
        _ clip: EditClip, _ state: TimelineState, _ ids: AIShortIDs, _ settings: Settings, detailed: Bool,
        deadline: Date = Date().addingTimeInterval(waitSeconds)
    ) async -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "id": .string(ids.short(clip.id)), "name": .string(clip.name),
            "start": AIFormat.seconds(clip.timelineStart), "end": AIFormat.seconds(clip.timelineEnd)
        ]
        if let location = state.location(of: clip.id) { object["track"] = .string(AITrackName.name(of: location.track)) }
        guard clip.hasAudio else {
            object["sound"] = "none: this clip has no audio"
            return object
        }
        // 成片里听不到的：不量（量出来的数会让 AI 以为它在响）。
        if clip.isMuted || clip.isHidden || trackIsHidden(of: clip.id, in: state) {
            object["sound"] = clip.isMuted ? "muted" : "hidden: not in the video"
            return object
        }
        guard let window = AIAudioLevels.sourceWindow(of: clip, from: settings.from, to: settings.to) else {
            object["sound"] = "outside from/to"
            return object
        }
        let (from, to) = (window.from, window.to)
        let timeline = (from: clip.timelineTime(atSource: from), to: clip.timelineTime(atSource: to))
        if settings.narrowed {
            object["from"] = AIFormat.seconds(timeline.from)
            object["to"] = AIFormat.seconds(timeline.to)
        }
        let trackGain = state.trackVolume(containingClip: clip.id)
        let frames = settings.grid.clip(clip, window: timeline, trackGain: trackGain)
        let reading: AIListenAudioWindow.Reading
        do {
            let bounds = frames.sourceBounds
            // `.sound`: past the end of the file's sound the clip plays silence (an audio track a few ms shorter than its picture).
            reading = try await AIListenAudioWindow.read(clip.sourceURL, from: from, to: to, until: deadline, frames: { _, _ in bounds },
                                                         edges: .sound, gain: frames.sampleGain)
        } catch {
            object["sound"] = deadline.timeIntervalSinceNow <= 0
                ? "still measuring: listen with clip_id, or narrow from/to"
                : .string("unreadable: SkyCut could not read this clip's audio (\(error.localizedDescription))")
            return object
        }
        let heard = AIAudioLevels.onTimeline(reading.windows, clip: clip)
        let report = AIAudioLevels.report(heard, silenceDB: settings.silenceDB, minSilence: settings.minSilence)
        let rate = reading.peaks.sampleRate
        let peaks = reading.frames.map { measured in
            AIListenPeaks.measure(measured, starts: frames.starts) { sample in
                clip.timelineTime(atSource: reading.sourceStart + Double(sample) / rate)
            }
        } ?? AIListenPeaks(truePeakDB: -60, peakAt: nil, loudestAt: nil)
        for (key, value) in AIAudioLevels.json(report, curve: AIAudioLevels.curve(heard), peaks: peaks, detailed: detailed) {
            object[key] = value
        }
        if settings.beats {
            do {
                let analysis = try await AIBeats.analysis(of: clip.sourceURL, from: from, to: to)
                let beats = AIBeats.json(analysis, sourceFrom: from, sourceTo: to, speed: clip.speed) { clip.timelineTime(atSource: $0) }
                for (key, value) in beats { object[key] = value }
            } catch {
                object["beats"] = .string("unreadable: \(error.localizedDescription)")
            }
        }
        return object
    }

    /// 整条轨藏起来了（眼睛关着）：上面的段不进成片。
    private static func trackIsHidden(of id: UUID, in state: TimelineState) -> Bool {
        switch state.location(of: id)?.track {
        case .main?: return state.mainHidden
        case .overlay(let index)?: return state.overlayTracks.indices.contains(index) && state.overlayTracks[index].isHidden
        case .audio(let index)?: return state.audioTracks.indices.contains(index) && state.audioTracks[index].isHidden
        case nil: return false
        }
    }

    // MARK: 整条时间线

    private static func listenToTimeline(_ state: TimelineState, _ ids: AIShortIDs, _ settings: Settings) async throws -> JSONValue {
        var clips: [EditClip] = state.mainClips.filter(\.hasAudio)
        for lane in state.overlayTracks { clips += lane.clips.filter(\.hasAudio) }
        for lane in state.audioTracks { clips += lane.clips }
        guard !clips.isEmpty else { throw AIToolError("Nothing on the timeline has sound.") }
        clips = clips.filter { AIAudioLevels.sourceWindow(of: $0, from: settings.from, to: settings.to) != nil }
        guard !clips.isEmpty else { throw AIToolError("Nothing with sound plays between from and to.") }
        let deadline = Date().addingTimeInterval(waitSeconds)
        var listed: [JSONValue] = []
        for clip in clips.prefix(maxClips) {
            listed.append(.object(await listenToClip(clip, state, ids, settings, detailed: false, deadline: deadline)))
        }
        var result: [String: JSONValue] = [
            "clips": .array(listed),
            "note": "Levels are what the video plays (each clip's volume, fades and track fader included); peak_db is the true peak (dBTP). Call listen with clip_id for one clip's silences and curve."
        ]
        if clips.count > maxClips { result["more_clips"] = .number(Double(clips.count - maxClips)) }
        return .object(result)
    }

    // MARK: 素材文件

    private static func listenToFile(
        _ path: String, _ args: AIToolArguments, _ project: VideoEditProject, _ settings: Settings
    ) async throws -> AIToolResult {
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
        if let ask = try AIWorkspace.shared.confirmReading([url], verb: "listen to", args: args, project: project) {
            return ask
        }
        let object = try await AIListenFileAudio.listen(
            url, args: args, display: AIWorkspace.shared.display(url), silenceDB: settings.silenceDB,
            minSilence: settings.minSilence, beats: settings.beats, frames: settings.grid, until: Date().addingTimeInterval(waitSeconds)
        )
        return .ok(.object(object))
    }

    // MARK: 波形

    /// 一个文件的波形（画时间线用的那一份，同一个文件只读一遍）。等到读完或者到点；到点时给出已经读到的部分。
    /// 读不了（没有音轨）返回 nil。
    static func waveform(of url: URL, until deadline: Date) async -> WaveformPeaks? {
        await AIListenFileAudio.waveform(of: url, until: deadline)
    }
}
