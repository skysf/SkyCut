import Foundation

// MARK: - 正在跑的 generate_media 任务（给编辑器顶上的状态行看）
//
// 管什么：此刻有哪几个生成任务在跑（`SkyStudioGenerationRun`），起手登记、结束（做完 / 失败 / 取消）就拿掉：
// 结局 AI 自己会从 `get_job` 拿到并告诉用户，状态行只管「正在做、做到哪一步、能停」。只有状态行订阅它
// （docs/architecture/preview-perf-ratchet.md 第十节：只有一个小视图关心的状态不放在工程上发）。2026-10-28 起（之前是 fal 的那一份）。
// 不管什么：任务怎么跑（SkyStudioGenerationRun）、upscale 的任务（UpscaleActivity）。

@MainActor
final class SkyStudioGenerationActivity: ObservableObject {
    static let shared = SkyStudioGenerationActivity()
    @Published private(set) var runs: [SkyStudioGenerationRun] = []

    func add(_ run: SkyStudioGenerationRun) {
        guard !runs.contains(where: { $0 === run }) else { return }
        runs.append(run)
    }

    func remove(_ run: SkyStudioGenerationRun) {
        runs.removeAll { $0 === run }
    }
}
