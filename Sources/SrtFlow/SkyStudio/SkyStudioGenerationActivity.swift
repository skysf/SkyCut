import Foundation

// MARK: - 素材生成 / 云端配音的活动与待处理提示
//
// 管什么：任务起手登记，成功 / 明确无扣费的取消结束时拿掉；失败和未知扣费保留到用户关闭提示。
// 结局 AI 仍从 `get_job` 读取；工具栏入口与浮层订阅这份清单
// （docs/architecture/preview-perf-ratchet.md 第十节：只有一个小视图关心的状态不放在工程上发）。2026-10-28 起（之前是 fal 的那一份）。
// 不管什么：任务怎么跑（SkyStudioMediaStatus）、upscale 的任务（UpscaleActivity）。

@MainActor
final class SkyStudioGenerationActivity: ObservableObject {
    static let shared = SkyStudioGenerationActivity()
    @Published private(set) var runs: [SkyStudioMediaStatus] = []

    func add(_ run: SkyStudioMediaStatus) {
        guard !runs.contains(where: { $0 === run }) else { return }
        runs.append(run)
    }

    func remove(_ run: SkyStudioMediaStatus) {
        guard run.issue == nil else { return }
        runs.removeAll { $0 === run }
    }

    /// 关闭提示不会再取消或重交任务，也不改变积分账。
    func dismiss(_ run: SkyStudioMediaStatus) {
        guard run.issue != nil else { return }
        runs.removeAll { $0 === run }
    }
}
