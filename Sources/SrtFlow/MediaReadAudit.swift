import Foundation

// MARK: - 一次调用里要过哪些媒体读取（自检的观察点，task-local）
//
// 管什么：自检把一本账绑在被测的那一次调用上（`MediaReadAudit.$current.withValue(账) { 被测的调用 }`），这次调用自己的 task 树里
// 要过的读取就记在这本账上 —— 整文件波形（`WaveformStore.peaks(for:)`）、listen 的有界窗（`AIListenAudioWindow` 的 reader：
// 它自己的 `timeRange`、原生交出多少帧）、节拍的整首读取（`AIBeats`）。每一笔都带着是哪个文件。
// 不管什么：读取本身、取消和截止时间、统计。它只记，不改任何行为。
//
// **平时没人绑定**（`current` 是 nil），登记点是一次可选链、什么都不做；不在实时音频的路径上。
//
// 为什么是 task-local、不是往下传的参数（docs/bugfixes/2026-11-13-listen-range-checks-timed-out-under-load.md「后续」）：
// 要证明的是「这一次调用没多读」。参数只看得见交到它手上的那次读取 —— 入口里另起一次不带参数的读取，照样看不见。
// task-local 跟着调用走，这次调用的 task（和它用 `Task { }` 起的）里任何一处登记点都记到同一本账上。
// 够不着的：`Task.detached` 里另起的读取（不继承 task-local）、没经过这三个登记点的读法。
//
// **登记要在「要」的那一刻同步记**：`WaveformStore` 是先回一条流、之后才异步找音轨、往 overview 队列上排活，
// 数队列上排了几件活会漏掉还没排上的那一件。读取体在 `MediaReadQueue` 的线程上跑，task-local 带不过去：
// 调用方在 async 那一头取出 `current`、交给读取体（`AIListenAudioWindow.read`）。

final class MediaReadAudit: @unchecked Sendable {
    @TaskLocal static var current: MediaReadAudit?

    enum Entry: Sendable, Equatable {
        /// 要了一次整文件波形；`startsDecode` = 这一次新起了整条音轨的解码（以前没人要过这个文件）。
        case wholeFileWaveform(URL, startsDecode: Bool)
        /// listen 的有界窗开读了：`from` / `to` 是 reader 自己的 `timeRange`（源秒），不是调用方说的。
        case windowStarted(URL, from: Double, to: Double)
        /// 同一个 reader 收尾：原生一共交出多少帧、盖到哪（一帧没交时两头是 ±∞）。
        case windowFinished(URL, decodedFrames: Int, decodedFrom: Double, decodedTo: Double)
        /// 节拍要读的那一段（整首窗，最多 15 分钟）。
        case beats(URL, from: Double, to: Double)
    }

    private let lock = NSLock()
    private var log: [Entry] = []
    private let onEntry: (@Sendable (Entry) -> Void)?

    /// `onEntry`：每记一笔当场叫一次（在登记的那条线程上），自检用它一看见不该有的读取就停掉被测的调用。
    init(onEntry: (@Sendable (Entry) -> Void)? = nil) { self.onEntry = onEntry }

    var entries: [Entry] { lock.withLock { log } }

    func note(_ entry: Entry) {
        lock.withLock { log.append(entry) }
        onEntry?(entry)
    }
}
