import Foundation

// MARK: - 停下几批的旁白：结果那句话逐批说清（纯值）
//
// 管什么（docs/bugfixes/2026-11-10-voiceover-stop-reports-one-batch.md）：用户停下一段分几批交的旁白时，以前结果只有最先出事的那一批的话
// （常常是「Sky Studio 已经开始了、取消不了」，句子里的 it 指哪一批都说不清），另外几批做好了没有、退没退钱、交没交一个字都没有。
// 现在每一批都说：做好了（恢复直接用、不再花钱）、在 Sky Studio 已经开始了取消不了（积分可能花了，恢复只取回原单）、Sky Studio 开始之前停下
// （积分退了）、还没交（没花钱）、交了却没拿到任务号（结果不明、不会再交）。批号照 get_job 的 batch_index（从 0 起），结构化的字段（每批的
// state、几个 *_indices）在 SkyStudioVoiceCheckpoint.detail。只有一批的旁白照旧用那一批自己的话（本来就说清了）。
// 不管什么：怎么停（SkyStudioVoiceBatchQueue / SkyStudioJobRun）、结果的其余字段。

enum SkyStudioVoiceStopSummary {
    enum State: CaseIterable, Equatable {
        case done, started, refunded, notSent, unknown
    }

    /// 停下那一刻第 `index` 批（从 0 起）在哪：看恢复记录（成品、交没交、退没退、有没有任务号）。
    static func state(of index: Int, in checkpoint: SkyStudioVoiceCheckpoint) -> State {
        let batch = checkpoint.batches[index]
        let linesDone = checkpoint.plan.batches[index].speech.parts.allSatisfy { checkpoint.outputs[$0.line] != nil }
        if batch.generated || linesDone { return .done }
        if !batch.submitted { return .notSent }
        if batch.retryable { return .refunded }
        return batch.serverID == nil ? .unknown : .started
    }

    /// 停下之后结果里的那句话；只有一批时是 nil（用那一批自己的话）。
    static func message(_ checkpoint: SkyStudioVoiceCheckpoint) -> String? {
        guard checkpoint.batches.count > 1, checkpoint.batches.count == checkpoint.plan.batches.count else { return nil }
        var groups: [State: [Int]] = [:]
        for index in checkpoint.batches.indices { groups[state(of: index, in: checkpoint), default: []].append(index) }
        let parts = State.allCases.compactMap { state -> String? in
            guard let indices = groups[state] else { return nil }
            return indices.map(String.init).joined(separator: ", ") + " " + phrase(state)
        }
        return "Stopped. By batch_index (from 0): " + parts.joined(separator: "; ") + ". Nothing was added to the timeline."
    }

    private static func phrase(_ state: State) -> String {
        switch state {
        case .done: return "finished (resume uses the audio without paying again)"
        case .started: return "had already started on Sky Studio and could not be cancelled (credits may be spent; resume only fetches the result)"
        case .refunded: return "stopped before Sky Studio started (credits returned)"
        case .notSent: return "never sent (nothing charged)"
        case .unknown: return "sent without a job id coming back (outcome unknown; never sent again)"
        }
    }
}
