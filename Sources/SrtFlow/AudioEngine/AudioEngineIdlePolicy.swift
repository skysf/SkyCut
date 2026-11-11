import Foundation

// MARK: - 预览的音频引擎该不该开着（纯值）
//
// 管什么：一句话的规矩 —— 图只在「马上要出声」时开着：
//   1. 时间线上没有要出声的段：不开（在播也不开，播放头按 host 时间走）；
//   2. 在播：开着；
//   3. 停着：最近 `idleAfter` 秒里有人要用声音（刚播过，或者用户在 SkyCut 里动过鼠标 / 键盘）才开着，否则停。
// 为什么：图开着就占着声卡，coreaudiod 替它拦着系统空闲睡眠，App Nap 也不生效 —— 2026-10-01 到 11-11 图从第一次建预览起
// 一直开到退出（docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md）。
// 为什么「用户动了一下」也算：冷的声卡起一次要 0.1–0.2 秒，等按下播放才起就晚了；人回到 SkyCut 总是先动鼠标 / 按键，
// 那一下就在后台把图起好，按播放时和一直开着一样。数字和量法见 docs/architecture/audio-engine.md 第二节第 11 条。
// 不管什么：谁来问、多久问一次（AudioEngineIdleKeeper）；图怎么停怎么起（TimelineAudioEngine.suspend / wake）。

struct AudioEngineIdlePolicy: Equatable, Sendable {
    /// 停着、也没人在用，过这么久停图（2026-11-11 用户同意的「约 30 秒」）。
    var idleAfter: TimeInterval = 30

    /// - Parameters:
    ///   - hasSound: 时间线上有没有要出声的段。
    ///   - isPlaying: 在不在播。
    ///   - quietFor: 距离上一次「有人要用声音」（在播、用户在 App 里动了鼠标 / 键盘）过了多久；从来没有就传 `.infinity`。
    func shouldRun(hasSound: Bool, isPlaying: Bool, quietFor: TimeInterval) -> Bool {
        guard hasSound else { return false }
        return isPlaying || quietFor < idleAfter
    }
}
