import Foundation

// 一段切成两个正长度片段的纯值实现；普通分割与定格共用字段复制规则。
// 不决定准入或让位：普通分割保留 1ms 边缘保护，定格另用有限半开范围。
enum TimelineClipSplit {
    static func make(_ original: EditClip, at time: Double) -> (left: EditClip, right: EditClip)? {
        var left = original
        let leftSourceLength = (time - left.timelineStart) * left.speed
        guard time.isFinite, leftSourceLength.isFinite, left.sourceDuration.isFinite,
              leftSourceLength > 0, leftSourceLength < left.sourceDuration else { return nil }
        var right = left
        // 右半是新的一段，得有自己的身份，链接组保持一致。
        right = EditClip(
            sourceURL: left.sourceURL,
            isAudioOnly: left.isAudioOnly,
            sourceStart: left.sourceStart + leftSourceLength,
            sourceDuration: left.sourceDuration - leftSourceLength,
            speed: left.speed,
            timelineStart: time,
            isMuted: left.isMuted,
            volume: left.volume,
            linkGroup: left.linkGroup,
            transitionAfter: left.transitionAfter,
            transitionDuration: left.transitionDuration,
            placement: left.placement,
            rotationDegrees: left.rotationDegrees,
            opacity: left.opacity,
            flippedHorizontally: left.flippedHorizontally,
            flippedVertically: left.flippedVertically,
            crop: left.crop,
            // 关键帧锚在源时间上：两半带同一份轨，各自只播自己窗口内的段落，
            // 接缝处数值天然连续。
            animation: left.animation,
            info: left.info,
            audioAssetDuration: left.audioAssetDuration,
            // 图片段的身份必须跟过来：`sourceURL` 只是随时会被系统清掉的静帧缓存，
            // 丢了 `stillImageURL` 的话，右半段会把缓存 mp4 当真实素材写进工程 ——
            // 缓存一清这段就再也无法从原图重建了。
            stillImageURL: left.stillImageURL,
            // 音频库素材的身份（重链接的第一层线索）同理：丢了的话右半段缓存一清就永久失链。
            remoteKey: left.remoteKey
        )
        right.needsStillConversion = left.needsStillConversion
        // 藏起来的段切开，两半都还藏着（2026-09-26 以前右半段会冒出来，进预览也进成片）。
        right.isHidden = left.isHidden
        // 预设的入/出场**不抄给右半**：它的时长就是 `videoFade*`，而那两个字段
        // 切开之后本来就不跟过来（切口右边没有"头尾渐变"可言），只抄效果会留下
        // 一个时长为 0 的空壳。左半照旧留着自己那份。
        // 标记同样锚在源时间上，所以两半各带一份**完整**的标记表，各自只画落在
        // 自己窗口里的那些 —— 切口两边谁也不会丢标记，跟关键帧一个处理法。
        right.markers = left.markers
        // 音量曲线也锚在源时间上：两半各带一份完整的点，切口两边的线连续
        //（同关键帧；合同见 docs/architecture/audio-volume-curve.md）。
        right.volumeCurve = left.volumeCurve
        // 声音场景跟着声音走：两半各带同一个（余音越过段尾，切开前后听起来一样）。
        right.soundScene = left.soundScene
        // upscale 的来源也要跟过来（从旧段构造新段漏字段的老坑：docs/bugfixes/2026-09-26-split-drops-hidden-and-library-key.md）。
        right.upscale = left.upscale
        left.sourceDuration = leftSourceLength
        // 切口是硬切，原来的转场跟着右半走。
        left.transitionAfter = .none

        return (left, right)
    }
}
