import AppKit

// MARK: - 用户此刻在不在用 SkyCut
//
// 管什么：用户上一次在 SkyCut 里动鼠标 / 按键是什么时候（`lastInput`），以及「安静了一阵之后又动了一下」这件事
// （`whenReturned`）。只算 SkyCut 在前台的时候：在别的 App 里干活、指针从 SkyCut 的窗口上扫过不算；切回 SkyCut 那一下算。
// 谁在用：预览的音频引擎（PreviewAudioEngineHost）—— 人回来了就先在后台把停着的图起好，等他按播放时和一直开着一样
// （冷的声卡起一次要 0.1–0.2 秒，docs/architecture/audio-engine.md 第二节第 11 条）；30 秒没人动、也没在播就停。
// 不管什么：拿这个信号做什么（AudioEngineIdlePolicy / AudioEngineIdleKeeper）。
//
// 代价：全 App 一个本地事件监视器，每个事件只记一个时间、比一次大小；通知最多 `quietGap` 秒一次。

@MainActor
final class AppUserPresence {
    static let shared = AppUserPresence()

    /// 两次动作隔了这么久，后一次才算「回来了」（连着动鼠标一秒几十个事件，不必每个都叫人）。
    nonisolated static let quietGap: TimeInterval = 1
    /// 算「在用」的事件：指针动、点、拖、滚、捏、按键。
    private static let inputs: NSEvent.EventTypeMask = [
        .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .scrollWheel, .magnify, .keyDown,
    ]

    /// 用户上一次在 SkyCut 里动鼠标 / 按键的时刻（系统开机以来的秒，和 `ProcessInfo.systemUptime` 同一个钟）；从没动过是 nil。
    private(set) var lastInput: TimeInterval?
    private var monitor: Any?
    private var activation: NSObjectProtocol?
    private var listeners: [(owner: () -> AnyObject?, action: () -> Void)] = []

    private init() {}

    /// 开始看（第一次有人要用时调；重复调没事）。
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.inputs) { event in
            let time = event.timestamp
            MainActor.assumeIsolated { AppUserPresence.shared.note(at: time, appIsActive: NSApp.isActive) }
            return event
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppUserPresence.shared.note(at: ProcessInfo.processInfo.systemUptime, appIsActive: true)
            }
        }
    }

    /// 用户安静了一阵之后又动了一下就叫 `action`；`owner` 没了就不再叫（不用自己摘）。
    func whenReturned(_ owner: AnyObject, _ action: @escaping () -> Void) {
        listeners.append((owner: { [weak owner] in owner }, action: action))
    }

    /// 记一次动作。`appIsActive` 为 false 的不算（SkyCut 不在前台）；进程内冒烟没有真用户，由步骤表直接调、传 true。
    func note(at time: TimeInterval, appIsActive: Bool) {
        guard appIsActive else { return }
        let returned = Self.isReturn(previous: lastInput, now: time)
        lastInput = time
        guard returned else { return }
        listeners.removeAll { $0.owner() == nil }
        for listener in listeners { listener.action() }
    }

    /// 上一次动作是 `previous`，这一次算不算「回来了」。
    nonisolated static func isReturn(previous: TimeInterval?, now: TimeInterval) -> Bool {
        guard let previous else { return true }
        return now - previous > quietGap
    }
}
