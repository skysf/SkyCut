import Foundation

// MARK: - 一段旁白的各批：按顺序领槽、同时交（SkyCut 声音方案 8.2、8.4）
// 管什么：
// - 要交的批（新的一段，或恢复时 generate_missing 补的）按原来的顺序在池里领槽（SkyStudioJobSlots：声音池，服务器还没有声音池时是共用池），
//   领到一个交一个，几批同时跑；有原单的只 GET、已经下好的直接用，都不领槽。
// - 回来的顺序不管：每批的音频按批号收好；切句和落地由调用方按原来的顺序做（SkyStudioVoiceoverRun），全部好了一次落地。
// - **一批出了事**（没做成、结果说不准、下载失败、工程换了）：后面还没交的不再交（留成 missing、预留退回），已经交出去的等它们做完、
//   音频照样存进恢复记录，然后整件以第一件事结束（可恢复，不重新花钱）。先记下出了事、再还这一批的槽：排在后面的批领到槽时一定看得见。
//   用户停：在等槽的离队，交上的照 SkyStudioJobRun 的规矩停（排队中的取消退钱，开始了的照实说）。
// - 进度（SkyStudioVoiceBatchBoard）：几批好了 / 共几批、几批在跑、几批等空位，每变一次交给 `onChange`。
// 不管什么：一批怎么交 / 等 / 下载、中途换备用（SkyStudioVoiceCloudBatches）；切句、落地（SkyStudioVoiceoverRun）。

@MainActor
final class SkyStudioVoiceBatchQueue {
    private let cloud: SkyStudioVoiceCloudBatches
    private let slots: SkyStudioJobSlots
    private let kind: String
    private(set) var board: SkyStudioVoiceBatchBoard
    /// 第一件出了事的批（从 0 起）和那件事。
    private(set) var failure: (index: Int, error: Error)?
    private var audio: [Int: SkyStudioVoiceCloudBatches.Audio] = [:]
    var onChange: @MainActor (SkyStudioVoiceBatchBoard) -> Void = { _ in }

    /// `count`：这一段一共几批（不在这一次要做的那几批照恢复记录算好了没有）。
    init(cloud: SkyStudioVoiceCloudBatches, slots: SkyStudioJobSlots, kind: String, count: Int) {
        self.cloud = cloud
        self.slots = slots
        self.kind = kind
        board = SkyStudioVoiceBatchBoard(count: count)
    }

    /// 这几批（原来的顺序）各拿到音频；`done` 是这一次不用做的（本机已经切好的）。出了事抛第一件事（`failure` 记着是哪一批）。
    func gather(_ sources: [(index: Int, source: SkyStudioVoiceCloudBatches.Source)], done: [Int]) async throws
        -> [Int: SkyStudioVoiceCloudBatches.Audio] {
        for index in done { board.advance(index, to: .done) }
        for (index, source) in sources {
            switch source {
            case .ready:
                if let saved = cloud.saved(index) { audio[index] = saved }
                board.advance(index, to: .done)
            case .skip: board.advance(index, to: .stopped)
            case .unknown: record(index, SkyStudioVoiceCloudBatches.unknownOutcome(index))
            case .fetch, .submit: break
            }
        }
        onChange(board)
        let submits = sources.filter { $0.source == .submit }.map(\.index)
        if let first = submits.first, failure == nil {
            do { try await cloud.prepareMissing() } catch { record(first, error) }
        }
        await withTaskGroup(of: Void.self) { group in
            for (index, source) in sources where source == .fetch {
                group.addTask { await self.fetch(index) }
            }
            for index in submits {
                guard failure == nil, !Task.isCancelled else { break }
                let lease: SkyStudioJobSlots.Lease
                do { lease = try await slots.acquire(kind: kind) } catch { break }
                // 领到槽时先看一眼：前面的批出了事、或者用户停了，就不再交（这一批留成 missing，预留退回）。
                guard failure == nil, !Task.isCancelled else {
                    lease.release()
                    break
                }
                group.addTask { await self.submit(index, lease: lease) }
            }
            await group.waitForAll()
        }
        for index in submits where board.states[index] == .waiting { board.advance(index, to: .stopped) }
        onChange(board)
        if let failure { throw failure.error }
        try Task.checkCancellation()
        return audio
    }

    private func submit(_ index: Int, lease: SkyStudioJobSlots.Lease) async {
        do {
            try await cloud.generate(index, lease: lease) { [weak self] state in self?.advance(index, state) }
        } catch {
            record(index, error)
            lease.release()
            return
        }
        lease.release()
        await collect(index)
    }

    private func fetch(_ index: Int) async {
        do {
            try await cloud.recover(index) { [weak self] state in self?.advance(index, state) }
        } catch {
            return record(index, error)
        }
        await collect(index)
    }

    private func collect(_ index: Int) async {
        do {
            audio[index] = try await cloud.download(index) { [weak self] state in self?.advance(index, state) }
            advance(index, .done)
        } catch {
            record(index, error)
        }
    }

    private func advance(_ index: Int, _ state: SkyStudioVoiceBatchBoard.State) {
        let before = board
        board.advance(index, to: state)
        if board != before { onChange(board) }
    }

    private func record(_ index: Int, _ error: Error) {
        if failure == nil { failure = (index, error) }
        advance(index, .stopped)
    }
}
