import Foundation

// Kokoro 的语速按时长对准（KokoroSpeedCalibration）：模型读出来的长短对 speed 的反应比 1 ÷ speed 弱（时长按 25 毫秒一格取整、
// 段间停顿不跟着变），直接给要的 speed 常常只慢一点点（2026-10-14 实测：0.95 → 0.85 只慢了 4.7%，
// docs/bugfixes/2026-10-14-kokoro-speed-barely-changes.md）。
// 这里照实测的样子造一句：固定的停顿 + 说话的部分对 speed 的反应比 1 ÷ speed 弱（真模型要 0.85 只慢 5–7%）、按 25 毫秒一格取整。
// 要的语速几次之内对到 3% 以内；直接给要的 speed（不校准）差得远 —— 这就是症状。真模型的数字在案例里（CI 上没有模型）。
// 编法见 scripts/check-mcp.sh。

func runKokoroSpeedChecks() {
    // 一句：两段停顿共 0.45 秒，30 个音，每个 4–8 格；说话的部分按 speed 的 0.6 次方缩放（比线性弱），再取整到整格。
    let pause = 0.45
    let tokens = (0..<30).map { 4 + ($0 * 7) % 5 }
    func duration(_ speed: Double) -> Double {
        pause + Double(tokens.reduce(0) { $0 + max(1, Int((Double($1) / pow(speed, 0.6)).rounded())) }) * 0.025
    }
    for wanted in [0.85, 0.9, 1.15, 1.3] {
        let target = duration(1) / wanted
        check(!KokoroSpeedCalibration.isClose(duration(wanted), to: target),
              "giving the model the wanted speed \(wanted) as is misses the target (that is the bug)")
        var tried: [(speed: Double, duration: Double)] = [(1, duration(1))]
        var model = wanted
        var reached = false
        for _ in 0..<KokoroSpeedCalibration.attempts {
            let got = duration(model)
            if KokoroSpeedCalibration.isClose(got, to: target) { reached = true; break }
            tried.append((model, got))
            model = KokoroSpeedCalibration.next(target: target, tried: tried)
        }
        check(reached, "speed \(wanted) is reached within 3% in \(KokoroSpeedCalibration.attempts) reads (tried \(tried.map { String(format: "%.3f", $0.speed) }))")
    }
    // 两边都有了就夹在中间：一次比目标长、一次比目标短，下一次的 speed 在两次之间。
    let between = KokoroSpeedCalibration.next(target: 3, tried: [(1, 2.5), (0.7, 3.4), (0.8, 2.9)])
    check(between > 0.7 && between < 0.8, "with one read too long and one too short, the next speed lies between them: \(between)")
    // 夹住：怎么推都不出模型的范围。
    checkEqual(KokoroSpeedCalibration.next(target: 100, tried: [(1, 2)]), KokoroSpeedCalibration.modelRange.lowerBound,
               "an impossible target is clamped to the slowest the model is given")
    check(KokoroSpeedCalibration.isClose(1.02, to: 1) && !KokoroSpeedCalibration.isClose(1.05, to: 1), "3% is close enough, 5% is not")
}
