import Foundation
import Synchronization

// MARK: - 渲染图此刻在不在跑、是谁停的，和后台起图的那条队列
//
// 管什么：`TimelineAudioEngine` 的渲染图的四种状态，和「用户回来了、先把故意停着的图起好」时不占调用方线程的那一次
// `start`（冷的声卡起一次要 0.1–0.25 秒：2026-11-11 在 M1 的内置扬声器上量的，docs/architecture/audio-engine.md
// 第二节第 11 条）。状态是原子的：后台那一次起完自己写结果。
// 不管什么：图本身（TimelineAudioEngine）、什么时候该停该起（AudioEngineIdlePolicy / AudioEngineIdleKeeper）。
//
// 串行的规矩：动图的入口（换配置、改总推子、停、再停一次、时钟要出声了）先 `settle()` 等后台那一次做完，再碰
// `AVAudioEngine` —— 它不是线程安全的，两条线程同时动它不行。`settle()` 平时立刻回来；只有正好撞上那 0.1–0.25 秒才等。

final class AudioGraphRun: @unchecked Sendable {
    enum State: Int, Sendable {
        /// 没在跑，也不是故意停的：从没起过、整个引擎收掉了、后台那一次没起来。时钟再要声音时当场起（起不来就报错）。
        case stopped
        case running
        /// 故意停的（空闲）：节点、流、播放头都留着，只是声卡放手了。
        case suspended
        /// 后台正在起。
        case starting
    }

    private let raw = Atomic<Int>(State.stopped.rawValue)
    private let queue = DispatchQueue(label: "srtflow.audio-engine.start", qos: .userInteractive)

    var state: State {
        get { State(rawValue: raw.load(ordering: .acquiring)) ?? .stopped }
        set { raw.store(newValue.rawValue, ordering: .releasing) }
    }

    /// 在后台起图：马上回来，状态先记成「正在起」，起完记成在跑；没起来记回 `stopped`（时钟下一拍当场再起一次、拿到真的错误）。
    func startInBackground(_ start: @escaping @Sendable () throws -> Void) {
        state = .starting
        queue.async { [self] in
            do {
                try start()
                state = .running
            } catch {
                state = .stopped
            }
        }
    }

    /// 等后台那一次起图做完（没有在起就立刻回来）。
    func settle() {
        queue.sync {}
    }
}
