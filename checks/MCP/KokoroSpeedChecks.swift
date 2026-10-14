import Foundation

// Kokoro 的语速按时长对准（KokoroSpeedCalibration）：模型把每个音的时长除以 speed 再取整到 25 毫秒一格、停顿不跟着变，
// 直接给要的 speed 常常只慢一点点（2026-10-14 实测：要 0.85 只慢了 4.7%，docs/bugfixes/2026-10-14-kokoro-speed-barely-changes.md）。
// 这里照模型的样子造一句：固定的停顿 + 一串音，每个音按 speed 缩放后取整到整格、至少一格。要的语速几次之内对到 3% 以内；
// 直接给要的 speed（不校准）差得远 —— 这就是症状。真模型的数字在案例里（CI 上没有模型）。编法见 scripts/check-mcp.sh。

func runKokoroSpeedChecks() {
    // 一句：两段停顿共 0.55 秒，40 个音，每个 1–5 格（25 毫秒一格）。
    let pause = 0.55
    let tokens = (0..<40).map { 1 + ($0 * 7) % 5 }
    func duration(_ speed: Double) -> Double {
        pause + Double(tokens.reduce(0) { $0 + max(1, Int((Double($1) / speed).rounded())) }) * 0.025
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
