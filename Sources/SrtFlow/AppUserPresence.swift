import AppKit

// MARK: - 用户此刻在不在用 SkyCut
//
// 管什么：用户上一次在 SkyCut 里有动作是什么时候（`lastInput`），以及「安静了一阵之后又回来了」这件事（`whenReturned`）。
// 哪些算回来了（2026-11-11 用户定）：SkyCut 变成活动的 App、它的窗口变成主窗口 / 键窗口、鼠标移进它的窗口、按键 ——
// 也就是 SkyCut 变成活动的那一下、它的窗口变成主窗口 / 键窗口的那一下、指针移进它的窗口的那一下（每个窗口挂一个
// 一直生效的跟踪区：SkyCut 还不在前台时也报，人多半就要点过来了），外加发给 SkyCut 的每一个鼠标 / 键盘事件。
// 谁在用：预览的音频引擎（PreviewAudioEngineHost）—— 人回来了就先在后台把停着的图起好，等他按播放时和一直开着一样
// （冷的声卡起一次要 0.15–0.3 秒，docs/architecture/audio-engine.md 第二节第 11 条）；2 分钟没人动、也没在播就停。
// 不管什么：拿这个信号做什么（AudioEngineIdlePolicy / AudioEngineIdleKeeper）。
//
// 代价：全 App 一个本地事件监视器 + 三个通知 + 每个窗口一个跟踪区，每次只记一个时间、比一次大小；叫人最多
// `quietGap` 秒一次。指针进不了看不见的窗口，所以跟踪区不会把藏起来的 SkyCut 叫醒（不碍着 App Nap）。

@MainActor
final class AppUserPresence {
    static let shared = AppUserPresence()

    /// 两次动作隔了这么久，后一次才算「回来了」（连着动鼠标一秒几十个事件，不必每个都叫人）。
    nonisolated static let quietGap: TimeInterval = 1
    /// 算「在用」的事件：指针动（含移进窗口里的区域）、点、拖、滚、捏、按键。**移出不算**（2026-11-11 审查）：指针离开
    /// 一块区域不是「回来了」，划过窗口就走的那一下不该把图多留两分钟。
    nonisolated static let inputs: NSEvent.EventTypeMask = [
        .mouseMoved, .mouseEntered, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .scrollWheel, .magnify, .keyDown,
    ]

    /// 用户上一次在 SkyCut 里有动作的时刻（系统开机以来的秒，和 `ProcessInfo.systemUptime` 同一个钟）；从没有过是 nil。
    private(set) var lastInput: TimeInterval?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// 「回来了」的三个通知：SkyCut 变成活动的、它的某个窗口变成键窗口 / 主窗口。
    private static let returns: [Notification.Name] = [
        NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
    ]
    private var listeners: [(owner: () -> AnyObject?, action: () -> Void)] = []

    /// 指针移进窗口时收消息的那一位（跟踪区的 owner）。
    private final class PointerWatcher: NSObject {
        @objc func mouseEntered(with event: NSEvent) {
            let time = event.timestamp
            MainActor.assumeIsolated { AppUserPresence.shared.note(at: time) }
        }

        @objc func mouseExited(with event: NSEvent) {}
    }
    private let pointerWatcher = PointerWatcher()
    private let watchedWindows = NSHashTable<NSWindow>.weakObjects()

    private init() {}

    /// 开始看。**App 一启动就调**（applicationDidFinishLaunching）：等第一次建音频引擎才开始看的话，打开工程的那一下
    /// 已经错过了，`lastInput` 还是 nil，刚起的图当场被当成没人用停掉、下一下动作再冷起一次（2026-11-11 审查）。
    /// 每次建预览的音频引擎时再调一次：重复调只给新开的窗口补上跟踪区。
    func start() {
        watchWindows()
        guard monitor == nil else { return }
        // 开始看的这一刻 SkyCut 已经在前台：人就在这儿。
        if NSApp?.isActive == true { note(at: ProcessInfo.processInfo.systemUptime) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.inputs) { event in
            let time = event.timestamp
            MainActor.assumeIsolated { AppUserPresence.shared.note(at: time) }
            return event
        }
        observers = Self.returns.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    AppUserPresence.shared.watchWindows()
                    AppUserPresence.shared.note(at: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
    }

    /// 给还没挂过的窗口（能当主窗口的那些：主窗口、工程窗口、设置；提示和浮层不算）挂一个「指针进来了」的跟踪区。
    /// `.activeAlways`：SkyCut 不在前台时也报。
    private func watchWindows() {
        for window in NSApp?.windows ?? [] where window.canBecomeMain && !watchedWindows.contains(window) {
            guard let view = window.contentView else { continue }
            view.addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: pointerWatcher, userInfo: nil
            ))
            watchedWindows.add(window)
        }
    }

    /// 用户安静了一阵之后又动了一下就叫 `action`；`owner` 没了就不再叫（不用自己摘）。
    func whenReturned(_ owner: AnyObject, _ action: @escaping () -> Void) {
        listeners.append((owner: { [weak owner] in owner }, action: action))
    }

    /// 记一次动作（进程内冒烟没有真用户，由步骤表的 `userInput` 直接调）。`lastInput` 只往后走：时间戳比已经记下的还早的
    /// 事件（合成事件带 0、排着队晚到的旧事件）不算数 —— 让它把「上一次」写回过去的话，图会被当成很久没人用、当场停掉。
    func note(at time: TimeInterval) {
        if let lastInput, time <= lastInput { return }
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
