import Foundation
import SrtFlowMCPKit

// MARK: - 按旁白段落同步的显式映射（纯值）
// 管什么：解析并一次核对段落范围、对象身份 / 所属、重复项与新旧旁白；不猜画面含义。
// 不管什么：音频时长 / 转写、时间换算和提交（AIVoiceoverSyncTool / AIVoiceoverSyncPlan）。

struct AIVoiceoverSyncInput {
    enum Fit: String { case speed, trim, freeze }
    struct Picture {
        let id: UUID
        let fit: Fit
    }
    struct Paragraph {
        let from: Double
        let to: Double
        let voice: UUID
        let replaces: UUID?
        let pictures: [Picture]
        let texts: [UUID]
        let shapes: [UUID]
        let subtitles: [UUID]

        func contains(_ start: Double, _ end: Double) -> Bool {
            start >= from - 0.000001 && end <= to + 0.000001 && end > start
        }
    }

    let paragraphs: [Paragraph]
    let start: Double
    let language: String

    init(_ args: AIToolArguments, state: TimelineState) throws {
        let items = try AIBatchItems.read(args, key: "paragraphs", tool: .syncVoiceover)
        let ids = AIShortIDs(state: state)
        var seen = Set<UUID>()
        var parsed: [Paragraph] = []
        func claim(_ raw: String) throws -> UUID {
            let id = try ids.resolve(raw)
            guard seen.insert(id).inserted else { throw AIToolError("\(raw) is mapped more than once.") }
            return id
        }
        for (index, item) in items.enumerated() {
            parsed.append(try AIBatchItems.entry("paragraphs", index) {
                let from = try item.requiredDouble("from")
                let to = try item.requiredDouble("to")
                guard from >= 0, to > from else { throw AIToolError("Require 0 <= from < to (old timeline seconds).") }
                if let last = parsed.last, abs(from - last.to) > 0.000001 {
                    throw AIToolError("Old paragraph ranges must be consecutive and ordered; include each later paragraph explicitly.")
                }
                let voice = try claim(item.requiredString("voiceover_id"))
                guard let audio = state.clip(with: voice), audio.isAudioOnly, audio.speed == 1,
                      !audio.isHidden, !audio.isMuted, audio.volume > 0,
                      let track = state.location(of: voice)?.track, !state.isLaneHidden(track) else {
                    throw AIToolError("voiceover_id must be an audible audio clip at speed 1. Add the new audio first.")
                }
                let replaces = try item.string("old_voiceover_id").map { try claim($0) }
                if let replaces {
                    guard let old = state.clip(with: replaces), old.isAudioOnly,
                          old.timelineStart >= from - 0.000001, old.timelineEnd <= to + 0.000001 else {
                        throw AIToolError("old_voiceover_id must be an audio clip inside this old paragraph.")
                    }
                }
                var pictures: [Picture] = []
                for raw in try item.array("clips") ?? [] {
                    guard raw.objectValue != nil else { throw AIToolError("clips entries must be objects.") }
                    let entry = AIToolArguments(raw)
                    let id = try claim(entry.requiredString("clip_id"))
                    guard let clip = state.clip(with: id), !clip.isAudioOnly, !clip.needsStillConversion else {
                        throw AIToolError("clips must name ready video or image clips.")
                    }
                    let fit = try entry.choice("fit", from: ["speed", "trim", "freeze"]) ?? "speed"
                    pictures.append(Picture(id: id, fit: Fit(rawValue: fit)!))
                }
                func list(_ key: String) throws -> [UUID] {
                    try (item.stringArray(key) ?? []).map { try claim($0) }
                }
                let p = Paragraph(from: from, to: to, voice: voice, replaces: replaces, pictures: pictures,
                                  texts: try list("texts"), shapes: try list("shapes"), subtitles: try list("subtitles"))
                for picture in pictures {
                    let clip = state.clip(with: picture.id)!
                    guard p.contains(clip.timelineStart, clip.timelineEnd) else {
                        throw AIToolError("A mapped picture crosses the old paragraph boundary; split it first.")
                    }
                }
                for id in p.texts {
                    guard let text = state.textOverlays.first(where: { $0.id == id }), p.contains(text.timelineStart, text.timelineEnd) else {
                        throw AIToolError("texts must name text overlays inside this old paragraph.")
                    }
                }
                for id in p.shapes {
                    guard let shape = state.shapes.first(where: { $0.id == id }), p.contains(shape.timelineStart, shape.timelineEnd) else {
                        throw AIToolError("shapes must name shapes inside this old paragraph.")
                    }
                }
                for id in p.subtitles {
                    guard let cue = state.subtitleCue(id), p.contains(cue.start, cue.end) else {
                        throw AIToolError("subtitles must name subtitle cues inside this old paragraph.")
                    }
                }
                return p
            })
        }
        paragraphs = parsed
        start = try args.double("start") ?? parsed[0].from
        guard start >= 0 else { throw AIToolError("start must be nonnegative.") }
        language = try args.requiredString("language")
        guard !language.isEmpty, language != "auto" else { throw AIToolError("Give the spoken language (for example zh or en), not auto.") }
        // 显式链接的画面 / 声音也必须被列出；不能在副本里偷偷带上没映射的伙伴。
        let moving = Set(parsed.flatMap { [$0.voice] + $0.pictures.map(\.id) })
        for clip in state.allClips where moving.contains(clip.id) {
            if let group = clip.linkGroup,
               state.allClips.contains(where: { $0.linkGroup == group && !seen.contains($0.id) }) {
                throw AIToolError("A mapped clip has an unmapped linked partner. Unlink it first or map its replacement explicitly.")
            }
        }
    }
}
