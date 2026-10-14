import Foundation

// MARK: - 一段换成另一个文件（edit_clip 的 file，2026-10-14 用户拍板）
//
// 管什么：时间线上一段的素材换成另一个文件 —— 起点、时长、速度、裁切摆放、动画、音量、渐变、转场、标记都不动，只换
// 「读哪个文件、从它的第几秒读」。锚在源时间上的东西（关键帧、标记、音量曲线）跟着入点整体平移（`ClipSourceSwap.shift`，
// 和 upscale 换源同一个挪法），所以都留在段里原来的相对位置上。纯值，自检够得着。
// 不管什么：文件怎么探、图片怎么先转成静帧视频（AIClipTools 的 plan 里转好才提交，转不了什么都不改）、读文件要不要用户点头
// （AIWorkspace）、链接伙伴（AIClipEdit：伙伴只跟换完文件之后的改动，不跟换文件本身）。

/// 换进来的文件，探好了的。
struct ClipFileReplacement: Equatable {
    enum Kind: Equatable {
        case video, image, audio
    }

    /// 用户给的那个文件（图片就是原图）。
    var url: URL
    var kind: Kind
    /// 视频 / 声音文件的长度；图片不看。
    var duration: Double
    /// 视频的探测信息；图片是转好的静帧视频的；声音文件没有。
    var info: MediaInfo?
    var hasAudio: Bool
    /// 图片转好的静帧视频：时间线读它，`stillImageURL` 记原图（同拖图片进来）。
    var stillVideo: URL?

    /// 入点超出素材一丁点（四舍五入的误差）就夹回来，同 `AIClipEdit.tolerance`。
    static let tolerance = 0.05

    /// 换文件。`sourceStart` = 从新文件的第几秒读（图片永远是 0）。类型对不上、文件不够长就抛错，段原样不动。
    static func apply(_ replacement: Self, to clip: inout EditClip, sourceStart: Double, stillDuration: Double) throws {
        let file = replacement.url.lastPathComponent
        if clip.isAudioOnly {
            guard replacement.kind != .image else {
                throw AIToolError("\(clip.name) is a sound clip; give it an audio or video file, not an image.")
            }
            guard replacement.hasAudio else { throw AIToolError("\(file) has no sound.") }
        } else if replacement.kind == .audio {
            throw AIToolError("\(clip.name) has a picture; give it a video or image file (add sound with add_clips).")
        }

        var start = replacement.kind == .image ? 0 : sourceStart
        if start < 0 {
            guard start > -tolerance else { throw AIToolError("source_in cannot be negative.") }
            start = 0
        }
        if replacement.kind == .image {
            guard clip.sourceDuration <= stillDuration + tolerance else {
                throw AIToolError(String(
                    format: "An image can show for at most %.0f s; this clip is %.2f s. Trim it first.",
                    stillDuration, clip.sourceDuration
                ))
            }
        } else if start + clip.sourceDuration > replacement.duration + tolerance {
            throw AIToolError(String(
                format: "%@ is %.2f s long; from %.2f s in it, this clip needs %.2f s. Use an earlier source_in, "
                    + "a longer file, or trim the clip first.",
                file, replacement.duration, start, clip.sourceDuration
            ))
        }

        ClipSourceSwap.shift(&clip, by: start - clip.sourceStart)
        clip.sourceStart = start
        clip.sourceDuration = min(clip.sourceDuration, replacement.kind == .image ? stillDuration : replacement.duration - start)
        switch replacement.kind {
        case .video:
            clip.sourceURL = replacement.url
            clip.info = replacement.info
            clip.stillImageURL = nil
            clip.audioAssetDuration = clip.isAudioOnly ? replacement.duration : nil
        case .image:
            clip.sourceURL = replacement.stillVideo ?? replacement.url
            clip.info = replacement.info
            clip.stillImageURL = replacement.url
            clip.audioAssetDuration = nil
        case .audio:
            clip.sourceURL = replacement.url
            clip.info = nil
            clip.audioAssetDuration = replacement.duration
        }
        // 换成了另一个文件：音乐库的身份、upscale 的来源记录都是旧文件的。
        clip.remoteKey = nil
        clip.upscale = nil
        clip.needsStillConversion = false
    }

    /// 画面的长宽比变了：原来的裁切 / 摆放是按旧画面算的，提醒 AI 重新铺一次。没变或说不准返回 nil。
    static func aspectNote(old: EditClip, new: EditClip) -> String? {
        guard !new.isAudioOnly, let before = old.info?.displaySize, let after = new.info?.displaySize,
              before.width > 0, before.height > 0, after.width > 0, after.height > 0 else { return nil }
        let ratio = (after.width / after.height) / (before.width / before.height)
        guard abs(ratio - 1) > 0.01 else { return nil }
        return String(
            format: "The new picture is %.0f×%.0f (was %.0f×%.0f): the clip keeps its old crop and placement, so call edit_clip "
                + "fit=fill (or fit) again if it should fill the frame.",
            after.width, after.height, before.width, before.height
        )
    }
}
