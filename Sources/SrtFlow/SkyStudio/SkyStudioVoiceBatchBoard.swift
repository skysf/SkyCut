import Foundation
import SrtFlowMCPKit

// MARK: - 一段旁白的几批各走到哪一步（纯值）
// 管什么（SkyCut 声音方案 8.2）：状态行和 get_job 都照它说「几批好了 / 共几批、几批在跑、几批等空位」，不造百分比；
// 浮层那一行的阶段（CloudJobPhase）也从它合出来：只剩一批没好时照那一批说（排第几、下载了多少），几批同时在跑时报「处理中」。
// 每一批只往前走（等空位 → 排队 → 处理 → 下载 → 好了；没做成 / 停了 / 这次不做是另一头）：晚到的旧进度不会把它拉回去。
// 不管什么：谁去交 / 等（SkyStudioVoiceBatchQueue）、怎么画（CloudTaskRows）。

struct SkyStudioVoiceBatchBoard: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// 还没交：在等空位（本机的槽满了，或服务器回 429），或者还没轮到。
        case waiting
        /// 交上了，在 Sky Studio 排队（第几位，不知道是 nil）。
        case queued(position: Int?)
        case processing
        /// 做好了，在下到本机（收到的字节比例）。
        case downloading(fraction: Double?)
        /// 音频在本机了。
        case done
        /// 这一次不做了：没做成、停了，或者恢复时没让补（missing）。
        case stopped
    }

    private(set) var states: [State]

    init(count: Int) { states = Array(repeating: .waiting, count: max(0, count)) }

    var total: Int { states.count }
    var done: Int { states.filter { $0 == .done }.count }
    /// 交上了还没好：在 Sky Studio 排队、在做、在下载。
    var running: Int { states.filter(\.isRunning).count }
    var waiting: Int { states.filter { $0 == .waiting }.count }
    /// 第几批（从 0 起）还没好、排在最前面：状态里的「第几批」。都好了 / 都不做了是 nil。
    var first: Int? { states.firstIndex { $0 != .done && $0 != .stopped } }

    /// 往前走一步；往回走（晚到的旧进度）、已经好了 / 停了的都不动。
    mutating func advance(_ index: Int, to state: State) {
        guard states.indices.contains(index), !states[index].isFinal, state.rank >= states[index].rank else { return }
        states[index] = state
    }

    /// 浮层那一行的阶段。
    var phase: CloudJobPhase {
        let active = states.filter { !$0.isFinal }
        if active.isEmpty { return .finishing }
        if active.count == 1 { return active[0].phase }
        if active.contains(.processing) { return .processing }
        if active.contains(where: { if case .downloading = $0 { return true } else { return false } }) { return .downloading(fraction: nil) }
        return .queued(position: nil)
    }

    /// get_job 跑着时的那几个数。
    var json: [String: JSONValue] {
        ["batches_done": .number(Double(done)), "batches_running": .number(Double(running)),
         "batches_waiting": .number(Double(waiting))]
    }
}

extension SkyStudioVoiceBatchBoard.State {
    var isRunning: Bool {
        switch self {
        case .queued, .processing, .downloading: return true
        case .waiting, .done, .stopped: return false
        }
    }

    var isFinal: Bool { self == .done || self == .stopped }

    /// 先后：同一步里换个排队位置、换个下载比例照样能报。
    fileprivate var rank: Int {
        switch self {
        case .waiting: return 0
        case .queued: return 1
        case .processing: return 2
        case .downloading: return 3
        case .done, .stopped: return 4
        }
    }

    var phase: CloudJobPhase {
        switch self {
        case .waiting: return .queued(position: nil)
        case .queued(let position): return .queued(position: position)
        case .processing: return .processing
        case .downloading(let fraction): return .downloading(fraction: fraction)
        case .done, .stopped: return .finishing
        }
    }
}
