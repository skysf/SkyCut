import AppKit
import Foundation

// 第 15 组的一部分：用户在不在用 SkyCut（AppUserPresence，预览的音频引擎靠它提前起图）。2026-11-11 审查之后补的三处：
//   1. 从 App 启动起就在看（不是等第一次建音频引擎）：不然打开工程的那一下已经错过，刚起的图当场被当成没人用停掉；
//   2. `lastInput` 只往后走：时间戳更早的事件（合成事件带 0、晚到的旧事件）不把它写回过去；
//   3. 指针移出不算「回来了」。
// 不建 NSApplication、不开窗口：通知自己发，事件类型只看那张表。编译方式见 scripts/check-audio-engine.sh。

@MainActor
func checkUserPresence() {
    let presence = AppUserPresence.shared
    check(presence.lastInput == nil, "前提：还没人动过")

    // 哪些事件算：指针动 / 移进、点、滚、按键算；移出不算。
    for kind in [NSEvent.EventTypeMask.mouseMoved, .mouseEntered, .leftMouseDown, .scrollWheel, .keyDown] {
        check(AppUserPresence.inputs.contains(kind), "算「在用」的事件少了一种（\(kind.rawValue)）")
    }
    check(!AppUserPresence.inputs.contains(.mouseExited), "指针移出不算「回来了」")

    var returns = 0
    let owner = NSObject()
    presence.whenReturned(owner) { returns += 1 }

    // 开始看（App 启动时调的就是它）：之后窗口变成键窗口 / 主窗口、App 变成活动的，都算回来了 —— 不用等建音频引擎。
    presence.start()
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
    pumpMain(until: { presence.lastInput != nil })
    check(presence.lastInput != nil && returns == 1, "开始看之后窗口变成键窗口：记下了、叫了一次（叫了 \(returns) 次）")

    // 第一次建引擎时已经知道用户刚才在：管空闲的接手，图留着（审查之前这时候 lastInput 还是 nil，当场停）。
    do {
        let audio = FakeIdleAudio()
        let idle = AudioEngineIdleKeeper(checkEvery: 3_600, lastInput: { presence.lastInput })
        idle.keep(audio)
        check(!audio.isSuspended && audio.suspends == 0, "启动起就在看：第一次建引擎时知道用户刚才在，图留着")
        idle.release()
    }

    // 只往后走。
    let time = (presence.lastInput ?? 0) + 10
    presence.note(at: time)
    check(presence.lastInput == time && returns == 2, "隔了 10 秒又动了一下：记下、算回来了")
    presence.note(at: time - 180)
    check(presence.lastInput == time, "时间戳早 3 分钟的事件：不把「上一次」写回过去（\(presence.lastInput ?? -1)）")
    presence.note(at: 0)
    check(presence.lastInput == time && returns == 2, "时间戳是 0 的合成事件：不算数")
    do {
        // 配上管空闲的：旧时间戳不会让图被当成很久没人用（审查之前：lastInput 退回去，图随即被停）。
        let audio = FakeIdleAudio()
        let idle = AudioEngineIdleKeeper(checkEvery: 3_600, now: { time + 1 }, lastInput: { presence.lastInput })
        idle.keep(audio)
        presence.note(at: time - 180)
        idle.reconcile()
        check(!audio.isSuspended, "旧时间戳的事件之后：图还开着")
        idle.release()
    }

    // 连着动不重复叫人；安静过一阵再动才算回来了。
    presence.note(at: time + 0.5)
    check(presence.lastInput == time + 0.5 && returns == 2, "半秒之后又动：记下时间，不算「回来了」")
    presence.note(at: time + 5)
    check(returns == 3, "安静了几秒再动：算回来了")
}
