import AppKit
import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 合成媒体和完整工程：生产音频解码 / 定格 / 编辑 / 提交，只有 ASR 的词时间可控。
@MainActor final class VoiceoverSyncFixture {
    let project: VideoEditProject
    let before: TimelineState
    let args: AIToolArguments
    let voices: [UUID]
    let oldVoices: [UUID]
    let videos: [UUID]
    let upper: [UUID]
    let texts: [UUID]
    let shapes: [UUID]
    let cues: [UUID]
    var calls = 0
    var badWords = false
    var mutateOnWords = false
    var cancelOnWords = false
    private let lengths: [Double]
    private let firstWords = ["台湾", "经济", "回暖"]
    private let lastWords = ["市场", "正在", "变化"]

    init(folder: URL, video: URL, lengths: [Double], fit: String = "speed") throws {
        self.lengths = lengths
        project = OpenProjects.shared.primary
        project.newProject()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project.documentURL = folder.appendingPathComponent("sync.skycut")
        project.linkageEnabled = true
        var state = TimelineState()
        state.mainMagnet = true
        let info = MediaInfo(duration: 30, displaySize: .init(width: 160, height: 90), frameRate: 24,
                             videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 100, keyframeInterval: 0)
        var pictures: [EditClip] = []
        var overlays: [EditClip] = []
        var old: [EditClip] = []
        var fresh: [EditClip] = []
        var titles: [TextOverlay] = []
        var boxes: [ShapeAnnotation] = []
        var subtitles: [SubtitleCue] = []
        var mapping: [JSONValue] = []
        for index in 0..<2 {
            let start = 10 + Double(index) * 10
            var picture = EditClip(sourceURL: video, sourceStart: 2, sourceDuration: 10, timelineStart: start, info: info)
            picture.opacity = 0.8
            picture.flippedHorizontally = true
            picture.rotationDegrees = 3
            pictures.append(picture)
            var overlay = EditClip(sourceURL: video, sourceStart: 1, sourceDuration: 4, timelineStart: start + 2, info: info)
            overlay.opacity = 0.6
            overlays.append(overlay)
            let file = folder.appendingPathComponent("voice-\(index).wav")
            try Self.wave(lengths[index], to: file)
            // 故意过期的时长：必须实读 WAV，不能照导入缓存 +1 秒去算。
            let sound = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: lengths[index] + 1,
                                 timelineStart: 50 + Double(index) * 30, audioAssetDuration: lengths[index] + 1)
            fresh.append(sound)
            old.append(EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 10, timelineStart: start, audioAssetDuration: 30))
            var title = TextOverlay(timelineStart: start + 1)
            title.text = "段落 \(index)"
            title.duration = 5
            title.row = 2
            title.style.fontSize = 46
            titles.append(title)
            boxes.append(ShapeAnnotation(kind: .arc, timelineStart: start + 2, duration: 4, centerX: 0.3))
            // 两句使用非线性的词时间；原稿繁体，假转写简体，旧逐词时间刻意不正确。
            let a = SubtitleCue(id: UUID(), start: start + 0.2, end: start + 3, text: "臺灣經濟")
            let b = SubtitleCue(id: UUID(), start: start + 4, end: start + 8, text: "回暖")
            let c = SubtitleCue(id: UUID(), start: start + 0.2, end: start + 3, text: "市場正在")
            let d = SubtitleCue(id: UUID(), start: start + 4, end: start + 8, text: "變化")
            let pair = index == 0 ? [a, b] : [c, d]
            subtitles += pair
            mapping.append([
                "from": .number(start), "to": .number(start + 10), "voiceover_id": .string(sound.id.uuidString),
                "old_voiceover_id": .string(old.last!.id.uuidString),
                "clips": [["clip_id": .string(picture.id.uuidString), "fit": .string(fit)],
                          ["clip_id": .string(overlay.id.uuidString)]],
                "texts": [.string(title.id.uuidString)], "shapes": [.string(boxes.last!.id.uuidString)],
                "subtitles": .array(pair.map { .string($0.id.uuidString) })
            ])
        }
        state.mainClips = pictures
        state.overlayTracks = [EditLane(clips: overlays)]
        state.audioTracks = [EditLane(clips: old), EditLane(clips: fresh)]
        state.textOverlays = titles
        state.shapes = boxes + [ShapeAnnotation(kind: .rectangle, timelineStart: 12, duration: 2)]
        state.subtitle = SubtitleDocumentModel(cues: subtitles, format: .srt)
        state.subtitleCompanion = SubtitleCompanion(origin: .imported)
        // 原来源也要被改成新声音，后续正常联动才认得。
        for (index, cue) in subtitles.enumerated() {
            state.subtitleCompanion!.cueMeta[cue.id] = CueMeta(origin: .generated, provenance: CueProvenance(clipID: old[index / 2].id))
        }
        before = state
        voices = fresh.map(\.id); oldVoices = old.map(\.id); videos = pictures.map(\.id); upper = overlays.map(\.id)
        texts = titles.map(\.id); shapes = boxes.map(\.id); cues = subtitles.map(\.id)
        args = AIToolArguments(["paragraphs": .array(mapping), "language": "zh"])
        project.restoreTimeline(state)
        project.effectiveUndoManager?.removeAllActions()
        AIReadGrants.shared.remember([folder])
    }

    var services: AIVoiceoverSyncTool.Services {
        var services = AIVoiceoverSyncTool.Services()
        services.words = { file, _ in
            self.calls += 1
            if self.cancelOnWords { throw CancellationError() }
            if self.mutateOnWords { self.project.perform { $0.mainClips[0].opacity = 0.4 } }
            let index = file.lastPathComponent.contains("0") ? 0 : 1
            if self.badWords && index == 1 { return [TimedWord(text: "completely different", start: 0.2, end: 0.5)] }
            let tokens = index == 0 ? self.firstWords : self.lastWords
            let length = self.lengths[index]
            let starts = [0.05, 0.18, 0.75]
            let ends = [0.14, 0.30, 0.93]
            return tokens.indices.map { TimedWord(text: tokens[$0], start: length * starts[$0], end: length * ends[$0]) }
        }
        return services
    }

    func run(_ args: AIToolArguments? = nil) async throws -> JSONValue {
        let tool = try AIVoiceoverSyncTool(args ?? self.args, project, services: services)
        let result = tool.start()
        let job = AIJobs.shared.job(result.payload["job_id"]!.stringValue!)!
        await AIJobs.shared.wait(for: job, seconds: 30)
        return AIJobs.shared.json(job)
    }

    static func wave(_ duration: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let count = AVAudioFrameCount(duration * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for i in 0..<Int(count) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.07)) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
