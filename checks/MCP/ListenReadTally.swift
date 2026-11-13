import Foundation
import SrtFlowMCPKit

// 被测的那一次文件 listen（生产入口 AIListenFileAudio.listen）里要过哪些读取，数出来：起了几个有界 reader、各自的 timeRange、
// 原生一共交出多少帧、要没要整文件波形、起没起节拍的读取。账（MediaReadAudit）绑在这一次调用的 task 上，登记点在生产代码里
// 「要」的那一刻同步记 —— 不另起一次读取去数（那数的是另一次调用），也不数队列上排了几件活（活是之后才异步排上去的）。
// 一看见这次不该有的读取就停掉这次调用（不等它读完、不等截止时间）；判红靠的是数，不是它停没停。
// 由来：docs/bugfixes/2026-11-13-listen-range-checks-timed-out-under-load.md「后续」。
// 不管什么：结果对不对（ListenRangeChecks）、怎么结束（ListenReadEndChecks）。

/// 这一次文件 listen 该要哪些读取。
enum ListenReadPlan: Sendable {
    /// 显式区间：恰好一个有界 reader，timeRange 就是这一段（源秒）；不要整文件波形，不起节拍的读取。
    case window(from: Double, to: Double)
    /// 没给区间：走共享的整文件波形（`beats` = 还会起节拍的读取）；不起有界 reader。
    case wholeFile(beats: Bool)
}

/// 一次调用的账，只算被测的那个文件。
struct ListenReadTally {
    /// 每个开读的有界 reader 自己的 timeRange。
    var windows: [(from: Double, to: Double)] = []
    /// 收了尾的有界 reader 有几个：每个都得报原生交出的帧数，少报一个，下面的总帧数就是个空数。
    var finishedWindows = 0
    var decodedFrames = 0
    var decodedFrom = Double.infinity
    var decodedTo = -Double.infinity
    var wholeFileRequests = 0
    var wholeFileDecodes = 0
    var beatReads = 0

    init(_ entries: [MediaReadAudit.Entry], file: URL) {
        for entry in entries {
            switch entry {
            case .wholeFileWaveform(let url, let startsDecode) where listenSameFile(url, file):
                wholeFileRequests += 1
                if startsDecode { wholeFileDecodes += 1 }
            case .windowStarted(let url, let from, let to) where listenSameFile(url, file):
                windows.append((from, to))
            case .windowFinished(let url, let frames, let from, let to) where listenSameFile(url, file):
                finishedWindows += 1
                decodedFrames += frames
                decodedFrom = min(decodedFrom, from)
                decodedTo = max(decodedTo, to)
            case .beats(let url, _, _) where listenSameFile(url, file):
                beatReads += 1
            default: break
            }
        }
    }

    /// 恰好一个有界 reader，它自己的 timeRange 就是 [from, to]。
    func readsOnly(from: Double, to: Double) -> Bool {
        windows.count == 1 && listenSameSecond(windows[0].from, from) && listenSameSecond(windows[0].to, to)
    }
}

private func listenSameFile(_ one: URL, _ other: URL) -> Bool { one.standardizedFileURL == other.standardizedFileURL }

/// reader 的 timeRange 落在 1/600000 秒的格子上，和请求的秒数差不到一格。
private func listenSameSecond(_ one: Double, _ other: Double) -> Bool { abs(one - other) < 1e-5 }

@MainActor
func fileListen(_ url: URL, sourceIn: Double?, sourceOut: Double?, beats: Bool = false) async throws -> [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    if let sourceIn { values["source_in"] = .number(sourceIn) }
    if let sourceOut { values["source_out"] = .number(sourceOut) }
    return try await AIListenFileAudio.listen(
        url, args: AIToolArguments(.object(values)), display: url.lastPathComponent,
        silenceDB: -45, minSilence: 0.5, beats: beats, until: Date().addingTimeInterval(listenCheckHangBound)
    )
}

/// 一次文件 listen 连同它的账。`plan` 里没有的读取一登记，这次调用当场被停掉（整小时的文件不用等它读完）。
@MainActor
func talliedFileListen(
    _ url: URL, sourceIn: Double?, sourceOut: Double?, beats: Bool = false, plan: ListenReadPlan
) async -> (result: Result<[String: JSONValue], Error>, tally: ListenReadTally) {
    let stop = ListenCallStop(file: url, plan: plan)
    let audit = MediaReadAudit { stop.saw($0) }
    let call = Task {
        try await MediaReadAudit.$current.withValue(audit) {
            try await fileListen(url, sourceIn: sourceIn, sourceOut: sourceOut, beats: beats)
        }
    }
    stop.arm(call)
    let result = await call.result
    return (result, ListenReadTally(audit.entries, file: url))
}

/// 「一看见这次不该有的读取就停掉被测的调用」的那只手。登记发生在读取队列、别的 task 的线程上，所以带锁。
private final class ListenCallStop: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let plan: ListenReadPlan
    private var task: Task<[String: JSONValue], Error>?
    private var fired = false
    private var windows = 0

    init(file: URL, plan: ListenReadPlan) {
        self.file = file
        self.plan = plan
    }

    func arm(_ task: Task<[String: JSONValue], Error>) {
        let late = lock.withLock { () -> Bool in
            self.task = task
            return fired
        }
        if late { task.cancel() }
    }

    func saw(_ entry: MediaReadAudit.Entry) {
        let stray = lock.withLock { () -> Task<[String: JSONValue], Error>? in
            if planned(entry) { return nil }
            fired = true
            return task
        }
        stray?.cancel()
    }

    /// 这一笔在不在计划里（锁里调；别的文件的不管）。
    private func planned(_ entry: MediaReadAudit.Entry) -> Bool {
        switch (entry, plan) {
        case (.windowStarted(let url, let from, let to), .window(let wantFrom, let wantTo)) where listenSameFile(url, file):
            windows += 1
            return windows == 1 && listenSameSecond(from, wantFrom) && listenSameSecond(to, wantTo)
        case (.windowStarted(let url, _, _), .wholeFile) where listenSameFile(url, file): return false
        case (.wholeFileWaveform(let url, _), .window) where listenSameFile(url, file): return false
        case (.beats(let url, _, _), .window) where listenSameFile(url, file): return false
        case (.beats(let url, _, _), .wholeFile(let beats)) where listenSameFile(url, file): return beats
        default: return true
        }
    }
}
