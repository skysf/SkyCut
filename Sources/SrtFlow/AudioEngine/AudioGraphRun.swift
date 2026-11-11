import Foundation
import Synchronization

// MARK: - 渲染图此刻在不在跑、是谁停的，和后台起图的那条队列
//
// 管什么：`TimelineAudioEngine` 的渲染图的四种状态，和「用户回来了、先把故意停着的图起好」时不占调用方线程的那一次
// `start`（冷的声卡起一次要 0.15–0.3 秒：2026-11-11 在 M1 的内置扬声器上量的，docs/architecture/audio-engine.md
// 第二节第 11 条）。状态是原子的：后台那一次起完自己写结果。
// 不管什么：图本身（TimelineAudioEngine）、什么时候该停该起（AudioEngineIdlePolicy / AudioEngineIdleKeeper）。
//
// 读的规矩：**一个判断只读一次 `state`**，取出来的值上再比（要问「在跑或者正在起」用 `State.isUp`）。后台那一次起完
// 随时会把 starting 改成 running；同一句里读两次，两次读到的可以不是同一个状态。
//
// 串行的规矩：动图的入口（换配置、改总推子、停、再停一次、时钟要出声了）先 `settle()` 等后台那一次做完，再碰
// `AVAudioEngine` —— 它不是线程安全的，两条线程同时动它不行。`settle()` 平时立刻回来；只有正好撞上那 0.15–0.3 秒才等。

final class AudioGraphRun: @unchecked Sendable {
    enum State: Int, Sendable {
        /// 没在跑，也不是故意停的：从没起过、整个引擎收掉了。
        case stopped
        case running
        /// 故意停的（空闲）：节点、流、播放头都留着，只是声卡放手了。
        case suspended
        /// 后台正在起。
        case starting

        /// 图在跑或者正在起。**在取出来的这一个值上判**：状态是原子的、后台那一次起完会改它，同一句里读两次
        /// （`state == .running || state == .starting`）会在 starting → running 交接的那一下两头都比不上、答成「没在跑」——
        /// 2026-11-11 复审：30 万次交接里答错 786 次，管空闲的据此把计时器撤了，图就一直开着没人停。
        var isUp: Bool { self == .running || self == .starting }
    }

    private let raw = Atomic<Int>(State.stopped.rawValue)
    private let queue = DispatchQueue(label: "srtflow.audio-engine.start", qos: .userInteractive)

    var state: State {
        get {
            let value = State(rawValue: raw.load(ordering: .acquiring)) ?? .stopped
            didReadState?()
            return value
        }
        set { raw.store(newValue.rawValue, ordering: .releasing) }
    }

    /// 只有自检设它（生产里一直是 nil；只在读状态的那条线程上设和叫）：每读完一次状态叫一下。自检拿它把「主线程刚读到
    /// starting、后台正好写成 running」这一下原样造出来 —— 那个窗只有几纳秒，两条线程去撞一百万次才中一两次，当不了回归。
    var didReadState: (() -> Void)?

    /// 在后台起图：马上回来，状态先记成「正在起」，起完记成在跑。没起来（没有能用的输出设备）：状态回到「故意停着」
    /// —— 图本来就是那个样子，时钟再要声音时照常当场起、拿到真的错误 —— 再到主线程上叫一次 `failed`（收拾喂样线程、
    /// 告诉管空闲的那一位别一直重试）。2026-11-11 审查之前记成 `stopped`：既不算停着也不算在跑，管空闲的每 5 秒记一句
    /// 「停图」、喂样线程回到每 50 ms 轮询。
    func startInBackground(_ start: @escaping @Sendable () throws -> Void, failed: @escaping @Sendable () -> Void) {
        state = .starting
        queue.async { [self] in
            do {
                try start()
                state = .running
            } catch {
                state = .suspended
                // 回主线程：经主 RunLoop（不经主队列）—— 嵌套着泵 RunLoop 的地方（模态、自检）也收得到。
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, failed)
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
        }
    }

    /// 等后台那一次起图做完（没有在起就立刻回来）。
    func settle() {
        queue.sync {}
    }
}
