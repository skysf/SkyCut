import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 旁白段落的完整候选时间线（纯值）
// 管什么：实际时长累加、画面 / 标题 / 形状落点、字幕词时间与来源、最终重叠核对。
// 复用批量事务、单项片段 / 叠层规则；先算所有落点再查重叠，允许相邻段同时变长。
// 不管什么：IO / 转写 / 定格素材准备、撤销和预览（AIVoiceoverSyncTool）。

struct AIVoiceoverSyncPlan {
    struct Audio {
        let sourceDuration: Double
        let assetDuration: Double
        let words: [TimedWord] // 相对本次选择的音频窗口，来自新音频。
    }
    struct Span {
        let paragraph: AIVoiceoverSyncInput.Paragraph
        let start: Double
        let end: Double
        var scale: Double { (end - start) / (paragraph.to - paragraph.from) }
        func time(_ old: Double) -> Double { start + (old - paragraph.from) * scale }
    }
    struct Freeze {
        let id: UUID
        let at: Double
        let duration: Double
        let start: Double
    }

    var edit: AIBatchEdit
    let spans: [Span]
    private(set) var freezes: [Freeze] = []

    init(input: AIVoiceoverSyncInput, state: TimelineState, audio: [UUID: Audio]) throws {
        edit = AIBatchEdit(state)
        var cursor = input.start
        var spans: [Span] = []
        for p in input.paragraphs {
            guard let sound = audio[p.voice], sound.sourceDuration.isFinite, sound.sourceDuration >= TimelineTrim.clipMinimumDuration else {
                throw AIToolError("The new voiceover must contain readable audio of at least \(TimelineTrim.clipMinimumDuration) s.")
            }
            spans.append(Span(paragraph: p, start: cursor, end: cursor + sound.sourceDuration))
            cursor += sound.sourceDuration
        }
        self.spans = spans
        for (index, span) in spans.enumerated() {
            try AIBatchItems.entry("paragraphs", index) {
                try append(span, sound: audio[span.paragraph.voice]!)
            }
        }
    }

    private mutating func append(_ span: Span, sound: Audio) throws {
        let p = span.paragraph
        let state = edit.before
        if let old = p.replaces { edit.next.remove(old) }
        // 真实文件时长覆盖导入时的缓存信息，再交给原片段编辑器校验 / 应用。
        edit.next.update(p.voice) { $0.audioAssetDuration = sound.assetDuration }
        let voice = state.clip(with: p.voice)!
        try clip(p.voice, change: AIClipChange(start: span.start, sourceOut: voice.sourceStart + sound.sourceDuration, alone: true))
        for picture in p.pictures { try pictureChange(picture, span: span) }
        try overlays(span)
        try subtitles(span, sound: sound, voice: voice)
    }

    private mutating func pictureChange(_ picture: AIVoiceoverSyncInput.Picture, span: Span) throws {
        let state = edit.before
        let old = state.clip(with: picture.id)!
        let start = span.time(old.timelineStart)
        let duration = old.timelineDuration * span.scale
        guard duration >= TimelineTrim.clipMinimumDuration else { throw AIToolError("A mapped picture would be shorter than the clip minimum.") }
        var change = AIClipChange(start: start, alone: true)
        if old.isStillImage || picture.fit == .trim || picture.fit == .freeze && duration <= old.timelineDuration {
            let length = duration * old.speed
            guard length <= (old.isStillImage ? StillImageClipFactory.stillDuration : old.assetDuration - old.sourceStart) + 0.000001 else {
                throw AIToolError("The mapped duration exceeds the available source / still duration. Choose speed or freeze explicitly.")
            }
            change.sourceOut = old.sourceStart + length
        } else if picture.fit == .speed {
            let speed = old.sourceDuration / duration
            guard TimelineTrim.clipSpeedRange.contains(speed) else { throw AIToolError("The required picture speed \(speed) is outside \(TimelineTrim.clipSpeedRange). Choose trim / freeze or revise the mapping.") }
            change.speed = speed
        } else {
            let hold = duration - old.timelineDuration
            guard hold >= TimelineTrim.clipMinimumDuration, hold <= StillImageClipFactory.stillDuration else {
                throw AIToolError("The freeze tail must be between the clip minimum and \(StillImageClipFactory.stillDuration) s.")
            }
            // 同现有末帧抽取口径，用素材帧率退回最后一帧中心。
            let frame = old.info?.frameRate ?? Double(state.frameRate.fps)
            let at = old.timelineEnd - min(old.timelineDuration / 2, 0.5 / max(frame, 1) / old.speed)
            freezes.append(Freeze(id: old.id, at: at, duration: hold, start: start + old.timelineDuration))
        }
        try clip(picture.id, change: change)
    }

    private mutating func overlays(_ span: Span) throws {
        let p = span.paragraph
        let state = edit.before
        for id in p.texts {
            let old = state.textOverlays.first { $0.id == id }!
            let duration = old.duration * span.scale
            guard duration >= TextOverlay.minimumDuration else { throw AIToolError("A title would be shorter than \(TextOverlay.minimumDuration) s.") }
            _ = try AIOverlayEdits.text(AIToolArguments([
                "text_id": .string(id.uuidString), "start": .number(span.time(old.timelineStart)), "duration": .number(duration)
            ]), at: span.start, in: &edit.next)
        }
        for id in p.shapes {
            let old = state.shapes.first { $0.id == id }!
            let duration = old.duration * span.scale
            guard duration >= 0.2 else { throw AIToolError("A shape would be shorter than 0.2 s.") }
            _ = try AIOverlayEdits.shape(AIToolArguments([
                "shape_id": .string(id.uuidString), "start": .number(span.time(old.timelineStart)), "duration": .number(duration)
            ]), at: span.start, in: &edit.next)
        }
    }

    private mutating func subtitles(_ span: Span, sound: Audio, voice: EditClip) throws {
        let p = span.paragraph
        let state = edit.before
        var timings: [UUID: SubtitleTrackEditing.Timing] = [:]
        for track in [SubtitleTrack.original, .translation] {
            let cues = p.subtitles.compactMap { id in state.subtitleTrack(of: id) == track ? state.subtitleCue(id) : nil }
            timings.merge(try AIVoiceoverSyncAlignment.timings(cues: cues, words: sound.words, start: span.start,
                                                            duration: sound.sourceDuration)) { _, new in new }
        }
        edit.next.editSubtitleTracks { original, companion in
            SubtitleTrackEditing.setTimings(timings, original: &original, companion: &companion)
            for (id, timing) in timings where state.subtitleTrack(of: id) == .original {
                var meta = companion.cueMeta[id] ?? CueMeta(origin: .editedManually)
                meta.provenance = CueProvenance(clipID: p.voice, sourceStart: voice.sourceStart + timing.start - span.start,
                                                sourceEnd: voice.sourceStart + timing.end - span.start)
                companion.cueMeta[id] = meta
            }
        }
    }

    private mutating func clip(_ id: UUID, change: AIClipChange) throws {
        let canvas = VideoEditCompositionBuilder.renderSize(for: edit.before)
        edit.next = try AIClipEditPlan(id: id, change: change, canvas: canvas).applying(
            to: edit.next, linkage: false, stillDuration: StillImageClipFactory.stillDuration, canvas: canvas, checksOverlap: false
        )
    }

    mutating func addFreeze(_ frozen: EditClip, for request: Freeze) throws {
        guard let slot = edit.next.location(of: request.id)?.track else { throw AIToolError("The freeze target disappeared.") }
        var frozen = frozen
        frozen.timelineStart = request.start
        let old = edit.before.clip(with: request.id)!
        frozen.transitionAfter = old.transitionAfter
        frozen.transitionDuration = old.transitionDuration
        frozen.videoFadeInDuration = 0
        frozen.presetAnimation.entrance = .none
        edit.next.update(request.id) {
            $0.transitionAfter = .none
            $0.videoFadeOutDuration = 0
            $0.presetAnimation.exit = .none
        }
        var lane = edit.next[track: slot]
        lane.append(frozen)
        edit.next[track: slot] = lane
        AITimelineEdits.sortLanes(&edit.next)
    }

    func validate() throws {
        // 不自动抬轨 / 换行，否则会改变叠放关系。只拒绝涉及本次映射的新冲突。
        let ids = Set(spans.flatMap { [$0.paragraph.voice] + $0.paragraph.pictures.map(\.id) })
            .union(edit.next.allClips.filter { edit.before.clip(with: $0.id) == nil }.map(\.id))
        for id in ids {
            if let other = AITimelineEdits.conflict(for: id, in: edit.next) {
                throw AIToolError("The synchronized clips overlap \(other.name) on the same track. Map the obstruction or move it first; nothing was applied.")
            }
        }
        let texts = Set(spans.flatMap { $0.paragraph.texts })
        for text in edit.next.textOverlays where texts.contains(text.id) {
            if edit.next.textOverlays.contains(where: { $0.id != text.id && $0.row == text.row
                && overlaps(text.timelineStart, text.timelineEnd, $0.timelineStart, $0.timelineEnd) }) {
                throw AIToolError("Synchronized titles overlap on the same row; nothing was applied.")
            }
        }
        let cues = Set(spans.flatMap { $0.paragraph.subtitles })
        for track in [SubtitleTrack.original, .translation] {
            let all = edit.next.subtitleCues(of: track)
            for cue in all where cues.contains(cue.id) {
                if all.contains(where: { $0.id != cue.id && overlaps(cue.start, cue.end, $0.start, $0.end) }) {
                    throw AIToolError("Synchronized subtitles overlap another cue on the same track; nothing was applied.")
                }
            }
        }
    }

    private func overlaps(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Bool {
        a < d - 0.000001 && c < b - 0.000001
    }
}
