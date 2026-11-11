import Foundation

// MARK: - 预览的音频引擎该不该开着（纯值）
//
// 管什么：一句话的规矩 —— 图只在「马上要出声」时开着：
//   1. 时间线上没有要出声的段：不开（在播也不开，播放头按 host 时间走）；
//   2. 在播：开着；
//   3. 停着：最近 `idleAfter`（2 分钟）里有人要用声音（刚播过，或者用户回到 SkyCut 有过动作）才开着，否则停。
// 为什么：图开着就占着声卡，coreaudiod 替它拦着系统空闲睡眠，App Nap 也不生效 —— 2026-10-01 到 11-11 图从第一次建预览起
// 一直开到退出（docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md）。
// 为什么「用户回来了」也算：冷的声卡起一次要 0.15–0.3 秒，等按下播放才起就晚了；人回到 SkyCut 总是先切过来 / 动鼠标 /
// 按键，那一下就在后台把图起好，按播放时和一直开着一样。
// 为什么是 2 分钟（2026-11-11 用户定；当天先定的是约 30 秒，看过量出来的数之后改的）：冷着按播放（图停着、回来的第一下
// 就是播放）要等声卡，画面和声音一起晚 0.15–0.3 秒 —— 30 秒太容易碰上（停下来看一会儿画面再按空格就是），放到 2 分钟
// 只剩「离开 2 分钟以上、回来第一下就是按播放」这一种。代价：Mac 的睡眠计时是分钟级的，晚 2 分钟放手照样睡得下去；
// App Nap 晚 2 分钟生效。数字和量法见 docs/architecture/audio-engine.md 第二节第 11 条。
// 不管什么：谁来问、多久问一次（AudioEngineIdleKeeper）；图怎么停怎么起（TimelineAudioEngine.suspend / wake）。

struct AudioEngineIdlePolicy: Equatable, Sendable {
    /// 停着、也没人在用，过这么久停图（2026-11-11 用户定的「约 2 分钟」，理由见文件头）。
    var idleAfter: TimeInterval = 120

    /// - Parameters:
    ///   - hasSound: 时间线上有没有要出声的段。
    ///   - isPlaying: 在不在播。
    ///   - quietFor: 距离上一次「有人要用声音」（刚播完、用户回到 SkyCut 有过动作）过了多久；从来没有就传 `.infinity`。
    func shouldRun(hasSound: Bool, isPlaying: Bool, quietFor: TimeInterval) -> Bool {
        guard hasSound else { return false }
        return isPlaying || quietFor < idleAfter
    }
}
