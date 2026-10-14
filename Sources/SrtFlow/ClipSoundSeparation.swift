import Foundation

// MARK: - 视频段的声音单独放到音频轨上（分离音频、J/L cut）
//
// 管什么：「分离音频」这一个动作的规则 —— 界面（右键 / 工具栏的 Detach Audio，`VideoEditProject.detachAudio`）和 AI
// （add_clips 的 sound=separate）都走这一份；以及 AI 的 sound=only（只要一个视频文件的声音）怎么把视频段换成只取声音的一段。
// 不管什么：分出来那段带走哪些声音设置（`EditClip.detachedAudio`，VideoEditAudioFade.swift）、两边怎么各自裁（AI 的
// edit_clip alone，AIClipEdit）、放进哪条音频轨（`TimelineState.place(_:intoAudio:)`）。

/// 一个视频文件的声音怎么上时间线（add_clips 的 `sound`，词表 `MCPVocabulary.clipSounds`）。
enum ClipSoundMode: String, CaseIterable {
    /// 画面照放，声音另放到音频轨上的一段、和画面链接着，画面那段静音（= 界面上的分离音频）。
    case separate
    /// 只要声音：一段只取声音的音频段，放在音频轨上，没有画面。
    case only
}

enum ClipSoundSeparation {
    /// 能分吗：只有声音的段、没有声音的视频、已经静音的段都不分（静音的那段分出来也是哑的）。
    static func canSeparate(_ clip: EditClip) -> Bool {
        !clip.isAudioOnly && clip.hasAudio && !clip.isMuted
    }

    /// 分离音频：视频段的声音变成音频轨上的一段（同一个源文件、只取声音，声音的设置跟着走），视频段静音，
    /// 两边用链接组绑在一起（视频段原来就在组里就沿用那个组）。返回分出来那段的 id；不能分返回 nil、什么都不改。
    @discardableResult
    static func separate(_ id: UUID, in state: inout TimelineState) -> UUID? {
        guard let clip = state.clip(with: id), canSeparate(clip) else { return nil }
        let group = clip.linkGroup ?? UUID()
        let sound = clip.detachedAudio(linkGroup: group)
        state.update(id) { picture in
            picture.isMuted = true
            picture.linkGroup = group
        }
        _ = state.place(sound, intoAudio: true)
        return sound.id
    }

    /// 分出来的那段：和画面同一个链接组、同一个源文件、只取声音。没有返回 nil。
    static func sound(of pictureID: UUID, in state: TimelineState) -> EditClip? {
        guard let picture = state.clip(with: pictureID), let group = picture.linkGroup else { return nil }
        return state.allClips.first {
            $0.linkGroup == group && $0.isAudioOnly && $0.sourceURL == picture.sourceURL && $0.id != pictureID
        }
    }
}
