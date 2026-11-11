import AVFoundation
import Foundation
import SrtFlowCore
import Synchronization

// 第 15 组的一部分：后台起图 starting → running 交接的那一下，图一直算「开着」，管空闲的不许把计时器撤了。
//
// 2026-11-11 复审复现的竞态：`graphIsUp` 写成 `run.state == .running || run.state == .starting`，原子状态读了两次 ——
// 主线程第一次读到 starting（左边不成立），后台正好写成 running，第二次读到 running（右边也不成立），两个本来都算开着的
// 状态合起来答成「没在跑」。管空闲的收尾时据此撤掉计时器，后台成功的那条路不会再上：图开着、没人在两分钟后停它。
// 假引擎没有并发的 starting，撞不到；这里拿**真引擎的 getter**、真的管空闲的，直接驱动引擎里那份 AudioGraphRun。两层：
//   1. **把那一下原样造出来**（`didReadState`：主线程读完第一次状态，「后台」当场把 starting 写成 running）。每次必中：
//      读两次的写法第一次读到 starting、第二次读到 running，答成「没在跑」。
//   2. 另一条线程照后台起图那样反复交接、主线程不停地问 / 不停地看一眼：真并发下也不出错。这一层撞不撞得上看运气
//      （读两次的写法在这台 M1 上一百万次才中一两次），只当旁证，红不红不靠它。
// 手动渲染，不碰声卡。

/// 两条线程之间的开关（`Atomic` 不能被闭包按值捕获，收在引用里）。
private final class Flag: @unchecked Sendable {
    let raised = Atomic<Bool>(false)
}

/// 引擎里那份私有的 AudioGraphRun。反射取：自检要直接驱动合法的交接，生产代码不为它开口子。
private func graphRun(of engine: TimelineAudioEngine) -> AudioGraphRun? {
    Mirror(reflecting: engine).children.first { $0.label == "run" }?.value as? AudioGraphRun
}

/// 另一条线程照后台起图那样交接 `times` 次（starting → running），做完举旗。
private func handOff(_ run: AudioGraphRun, times: Int, started: Flag, done: Flag) {
    let thread = Thread {
        started.raised.store(true, ordering: .releasing)
        for _ in 0..<times {
            run.state = .starting
            run.state = .running
        }
        done.raised.store(true, ordering: .releasing)
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    while !started.raised.load(ordering: .acquiring) { usleep(50) }
}

@MainActor
func checkGraphHandoff(tone: URL) {
    // 在取出来的那一个值上判：四种状态各是什么。
    check(AudioGraphRun.State.running.isUp && AudioGraphRun.State.starting.isUp, "在跑、正在起：都算开着")
    check(!AudioGraphRun.State.suspended.isUp && !AudioGraphRun.State.stopped.isUp, "故意停着、没在跑：不算开着")

    let handoffs = 300_000
    do {
        let audio = try TimelineAudioEngine(config: AudioEngineConfig.make(from: plainLane(tone)), mode: .offline)
        defer { audio.stop() }
        check(try audio.recoverIfNeeded(), "前提：图起来了")
        guard let run = graphRun(of: audio) else {
            return check(false, "反射取不到引擎的 AudioGraphRun（属性改名了？这一组驱动不了交接）")
        }

        // 1. 把那一下原样造出来：读完第一次状态，后台「正好」起完。
        var reads = 0
        run.state = .starting
        run.didReadState = {
            reads += 1
            if reads == 1 { run.state = .running }
        }
        let answered = audio.graphIsUp
        run.didReadState = nil
        check(answered, "读状态的那一下后台正好从 starting 交接到 running：graphIsUp 照样答「开着」")
        check(reads == 1, "graphIsUp 一个判断只读一次状态（读了 \(reads) 次）")

        // 管空闲的看一眼的时候撞上：第几次读状态时交接都试一遍，计时器都不许被撤（撤了之后后台那条路不会再上）。
        do {
            let now = ProcessInfo.processInfo.systemUptime
            let idle = AudioEngineIdleKeeper(checkEvery: 3_600, now: { now }, lastInput: { now })
            idle.keep(audio)
            check(idle.isArmed, "前提：图开着，计时器上着")
            var disarmedAt: [Int] = []
            for flip in 1...6 {
                var count = 0
                run.state = .starting
                run.didReadState = {
                    count += 1
                    if count == flip { run.state = .running }
                }
                idle.reconcile()
                run.didReadState = nil
                if !idle.isArmed { disarmedAt.append(flip) }
                run.state = .running
                idle.reconcile()
            }
            check(disarmedAt.isEmpty, "看一眼的中途后台正好交接（第 1–6 次读状态时各试一次）：计时器都没被撤（第 \(disarmedAt) 次时撤了）")
            idle.release()
        }

        // 2. 真并发：交接期间一次都不许答「没在跑」。
        var started = Flag(), done = Flag()
        handOff(run, times: handoffs, started: started, done: done)
        var asked = 0, misreports = 0
        while !done.raised.load(ordering: .acquiring) {
            if !audio.graphIsUp { misreports += 1 }
            asked += 1
        }
        print("  真并发：交接 \(handoffs) 次期间 graphIsUp 问了 \(asked) 次，答错 \(misreports) 次")
        check(asked > 1_000, "前提：交接的同时主线程真的在问（问了 \(asked) 次）")
        check(misreports == 0, "starting → running 交接 \(handoffs) 次：graphIsUp 一次都没答成「没在跑」（答错 \(misreports) 次）")
        check(audio.graphIsUp && audio.graphState == .running, "交接完：图在跑")

        // 管空闲的也在真并发下看：用户在场、图开着，交接期间怎么看都不许把计时器撤了（撤了就没人在两分钟后停图）。
        let now = ProcessInfo.processInfo.systemUptime
        let idle = AudioEngineIdleKeeper(checkEvery: 3_600, now: { now }, lastInput: { now })
        idle.keep(audio)
        check(idle.isArmed, "前提：图开着，计时器上着")
        started = Flag()
        done = Flag()
        handOff(run, times: handoffs, started: started, done: done)
        var looks = 0, disarmed = 0
        while !done.raised.load(ordering: .acquiring) {
            idle.reconcile()
            if !idle.isArmed { disarmed += 1 }
            looks += 1
        }
        print("  真并发：交接 \(handoffs) 次期间管空闲的看了 \(looks) 眼，计时器被撤 \(disarmed) 次")
        check(looks > 1_000, "前提：交接的同时管空闲的真的在看（看了 \(looks) 眼）")
        check(disarmed == 0, "starting → running 交接期间：计时器一次都没被撤（撤了 \(disarmed) 次）")
        idle.reconcile()
        check(idle.isArmed && !audio.isSuspended, "交接完：图开着，计时器还上着")
        idle.release()
    } catch {
        check(false, "交接回归失败：\(error)")
    }
}
