import Foundation

// MARK: - 变声的两个文件落到时间线上（纯值）
//
// 管什么（SkyCut 声音方案 4.8 第 4 步、约定第 4 条）：服务器回两个文件——变声后的人声、分离出来的背景，混音在 SkyCut 里做：
// - 原片段**静音、不删**；
// - **新开两条音频轨**（接在现有音频轨后面），人声一段、背景一段，放在原片段同一时间；
// - 两段带上原片段的变速、音量、渐入渐出、音量曲线、声音场景（两段都用原片段的音量、不另加增益；导出的限幅器兜底）；
// - 三段进同一个链接组（原片段本来就在组里就沿用那个组）：联动开着时挪、裁、删原片段，两段新音频跟着走；
// - 人声比原片段长几毫秒（Chatterbox HD 实测长 5–35 ms，服务器只补短的、长了不裁）：只在时间线上裁到原长，文件不动。
// 任务跑了几分钟，这一段可能被动过：**照它现在的样子落**（挪了就落到新位置、裁短了就只取还用着的那一截）；这一段不在了、
// 换了素材、往外拉出了当初没送去变声的部分，就不落（文件留着，调用方照实说）。新文件的 0 秒 = 当初那一段的入点（`Origin.sourceStart`），
// 音量曲线锚在源时间上，跟着平移过去。
// 调用方把 `land` 放进**一次** `perform`、外面包一层 `AIUndoGrouping.step`：静音 + 两条新轨 + 两段新音频 + 链接是一步撤销（方案 4.9）。
// 不管什么：文件怎么来（VoiceChangeJob）、撤销怎么包（VoiceChangeJob.land）。

enum VoiceChangeLanding {
    /// 送去变声的是哪一段的哪一截素材（任务起手时记下）。
    struct Origin: Equatable, Sendable {
        let clipID: UUID
        let sourceURL: URL
        let sourceStart: Double
        let sourceDuration: Double
    }

    /// 落盘的两个文件和各自多长（秒，从文件探出来的）。
    struct Files: Equatable, Sendable {
        var voice: URL
        var voiceSeconds: Double
        var background: URL
        var backgroundSeconds: Double
    }

    struct Landed: Equatable, Sendable {
        let voiceID: UUID
        let backgroundID: UUID
        /// 两段各落在第几条音频轨（从 0 起）。
        let voiceTrack: Int
        let backgroundTrack: Int
    }

    enum Refusal: Error, Equatable {
        /// 这一段不在时间线上了。
        case clipGone
        /// 这一段换了素材（换源、换文件）。
        case sourceChanged
        /// 这一段现在用到了当初没送去变声的部分（往外拉长了）。
        case notCovered
    }

    /// 差这么多秒以内算盖住（一帧上下）。
    static let slack = 0.05

    /// 现在还落不落得了；落得了回这一段现在的样子。
    static func target(_ origin: Origin, files: Files, in state: TimelineState) -> Result<EditClip, Refusal> {
        guard let clip = state.clip(with: origin.clipID) else { return .failure(.clipGone) }
        guard clip.sourceURL == origin.sourceURL else { return .failure(.sourceChanged) }
        let offset = clip.sourceStart - origin.sourceStart
        guard offset >= -slack, clip.sourceStart + clip.sourceDuration <= origin.sourceStart + origin.sourceDuration + slack,
              min(files.voiceSeconds, files.backgroundSeconds) - max(0, offset) > slack else { return .failure(.notCovered) }
        return .success(clip)
    }

    /// 落地：原片段静音、两条新音频轨、两段新音频、链接。落不了什么都不改。
    static func land(_ files: Files, origin: Origin, voiceID: UUID = UUID(), backgroundID: UUID = UUID(),
                     in state: inout TimelineState) -> Result<Landed, Refusal> {
        let clip: EditClip
        switch target(origin, files: files, in: state) {
        case .success(let found): clip = found
        case .failure(let refusal): return .failure(refusal)
        }
        let group = clip.linkGroup ?? UUID()
        let voice = piece(files.voice, seconds: files.voiceSeconds, id: voiceID, of: clip, origin: origin, group: group)
        let background = piece(files.background, seconds: files.backgroundSeconds, id: backgroundID, of: clip, origin: origin, group: group)
        state.update(clip.id) { original in
            original.isMuted = true
            original.linkGroup = group
        }
        let first = state.audioTracks.count
        state.audioTracks.append(EditLane(clips: [voice]))
        state.audioTracks.append(EditLane(clips: [background]))
        return .success(Landed(voiceID: voiceID, backgroundID: backgroundID, voiceTrack: first, backgroundTrack: first + 1))
    }

    /// 一段新音频：和原片段同一时间、同样的变速和声音设置，只取声音；比原片段长的那几毫秒不上时间线。
    private static func piece(_ file: URL, seconds: Double, id: UUID, of clip: EditClip, origin: Origin, group: UUID) -> EditClip {
        let offset = max(0, clip.sourceStart - origin.sourceStart)
        var piece = EditClip(
            id: id, sourceURL: file, isAudioOnly: true, sourceStart: offset,
            sourceDuration: max(0, min(clip.sourceDuration, seconds - offset)), speed: clip.speed, timelineStart: clip.timelineStart,
            volume: clip.volume, fadeInDuration: clip.fadeInDuration, fadeOutDuration: clip.fadeOutDuration, linkGroup: group,
            audioAssetDuration: seconds
        )
        // 曲线的点锚在原素材的源时间上；新文件的 0 秒是当初那一段的入点。
        piece.volumeCurve = clip.volumeCurve.stretched(from: 0...1, to: -origin.sourceStart...(1 - origin.sourceStart))
        piece.soundScene = clip.soundScene
        piece.isHidden = clip.isHidden
        return piece
    }
}
