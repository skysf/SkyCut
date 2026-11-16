import Foundation

// ESTOI 自己的性质（照 STOI / ESTOI 论文该有的样子，不靠 Python 版）：同一个信号 = 1、只是变轻 = 1、整体增益不变、
// 加噪随信噪比单调、走 48 kHz 和直接给 10 kHz 一样、134 Hz 以下看不见、太短 / 长度不一样回 nil、最差 1 秒的算法。

func runESTOIChecks() {
    let rate = ESTOIAnalysis.sampleRate
    let clean = normalized(TestSignals.speechLike(seconds: 4, rate: rate, seed: 21), rms: 0.1)
    checkIdentityAndGain(clean, rate: rate)
    checkMonotone(clean, rate: rate)
    checkRatePath(clean)
    checkBlindBelow134(clean, rate: rate)
    checkRejects(clean, rate: rate)
    checkWorstWindow()
    checkBandLayout()
}

func normalized(_ x: [Double], rms: Double) -> [Double] {
    TestSignals.scaled(x, by: rms / ListeningLevel.rms(x))
}

private func estoi(_ clean: [Double], _ mix: [Double], rate: Double) -> Double? {
    ESTOI.score(clean: TestSignals.floats(clean), mix: TestSignals.floats(mix), sampleRate: rate)?.score
}

private func checkIdentityAndGain(_ clean: [Double], rate: Double) {
    checkClose(estoi(clean, clean, rate: rate), 1, "干净对干净 = 1", tolerance: 1e-9)
    checkClose(estoi(clean, TestSignals.scaled(clean, by: 0.1), rate: rate), 1, "只是变轻（× 0.1）= 1", tolerance: 1e-9)
    let noise = TestSignals.noise(TestSignals.whiteNoise(count: clean.count, seed: 22), atSNR: 0, against: clean)
    let mix = TestSignals.sum(clean, noise)
    guard let base = estoi(clean, mix, rate: rate) else { return check(false, "0 dB 白噪声算不出 ESTOI") }
    // 乘 2 的幂：存成 Float 也是精确的，所以两边是真正的同一个信号乘了增益。
    checkClose(estoi(clean, TestSignals.scaled(mix, by: 1.0 / 128), rate: rate), base, "混音整体 × 1/128，ESTOI 不变", tolerance: 1e-9)
    checkClose(estoi(TestSignals.scaled(clean, by: 8), mix, rate: rate), base, "干净人声整体 × 8，ESTOI 不变", tolerance: 1e-9)
}

/// 两种噪声（白噪声、人声形状的噪声），信噪比 −15 → +20 dB，ESTOI 一档比一档高；两头在该在的地方。
private func checkMonotone(_ clean: [Double], rate: Double) {
    let maskers = [("白噪声", TestSignals.whiteNoise(count: clean.count, seed: 23)),
                   ("人声形状的噪声", TestSignals.speechShaped(like: clean, seed: 24))]
    for (name, raw) in maskers {
        let scores = [-15.0, -10, -5, 0, 5, 10, 20].compactMap { snr in
            estoi(clean, TestSignals.sum(clean, TestSignals.noise(raw, atSNR: snr, against: clean)), rate: rate)
        }
        checkEqual(scores.count, 7, "\(name)：每一档都算得出")
        check(zip(scores, scores.dropFirst()).allSatisfy { $1 > $0 + 0.01 }, "\(name)：信噪比越高 ESTOI 越高 \(scores)")
        check((scores.first ?? 1) < 0.3 && (scores.last ?? 0) > 0.8, "\(name)：−15 dB 很低、+20 dB 很高 \(scores)")
    }
}

/// 10 kHz 的内容升到 48 kHz 交进来，和直接交 10 kHz 的结果一样（重采样那一步不改东西）。
private func checkRatePath(_ clean: [Double]) {
    let mix = TestSignals.sum(clean, TestSignals.noise(TestSignals.whiteNoise(count: clean.count, seed: 25), atSNR: 3, against: clean))
    let up = { (x: [Double]) in ListeningResample.resample(x, from: 10_000, to: 48_000) }
    // Float 存一次再算：两边都从同一份 Float 出发。
    let direct = ESTOI.score(clean: TestSignals.floats(clean), mix: TestSignals.floats(mix), sampleRate: 10_000)?.score
    let viaHigh = ESTOI.score(clean: TestSignals.floats(up(clean)), mix: TestSignals.floats(up(mix)), sampleRate: 48_000)?.score
    checkClose(viaHigh, direct, "48 kHz 交进来和 10 kHz 一样（只差 Float 存一次的舍入）", tolerance: 1e-6)
}

/// 134 Hz 以下 ESTOI 看不见：40 / 50 Hz 的重低音开到比人声还响 6 dB，ESTOI 几乎不动；同样响的人声形状噪声能把它压下去一大截。
/// 「几乎」：256 点的汉宁窗主瓣有 ±78 Hz 宽，50 Hz 的能量会漏一点进最低一带（136–168 Hz），所以不是正好 1（实测约 0.96）。
private func checkBlindBelow134(_ clean: [Double], rate: Double) {
    let sub = TestSignals.noise(TestSignals.subBass(count: clean.count, rate: rate), atSNR: -6, against: clean)
    let shaped = TestSignals.noise(TestSignals.speechShaped(like: clean, seed: 26), atSNR: -6, against: clean)
    guard let withSub = estoi(clean, TestSignals.sum(clean, sub), rate: rate),
          let withShaped = estoi(clean, TestSignals.sum(clean, shaped), rate: rate) else {
        return check(false, "重低音 / 人声形状噪声算不出 ESTOI")
    }
    check(withSub > 0.9, "134 Hz 以下的重低音比人声响 6 dB，ESTOI 还是 \(withSub)（看不见）")
    check(withShaped < 0.4, "一样响的人声形状噪声把 ESTOI 压到 \(withShaped)")
}

private func checkRejects(_ clean: [Double], rate: Double) {
    let short = TestSignals.floats(Array(clean[1_500..<5_000]))   // 0.35 秒：去静音以后不到 30 帧
    check(ESTOI.score(clean: short, mix: short, sampleRate: rate) == nil, "不到 30 帧回 nil")
    let floats = TestSignals.floats(clean)
    check(ESTOI.score(clean: floats, mix: Array(floats.dropLast()), sampleRate: rate) == nil, "长度不一样回 nil")
    // 干净人声全是 0（调用方不该这么调，但不能出 NaN）：每帧都一样「响」，全留下；包络全是 0，归一成 0，分数是 0。
    checkEqual(ESTOI.score(clean: [Float](repeating: 0, count: floats.count), mix: floats, sampleRate: rate)?.score, 0,
               "干净人声全是 0：ESTOI 是 0，不是 NaN")
}

/// 最差 1 秒：前缀和的做法和逐段平均一样；段数不够就是整句。
private func checkWorstWindow() {
    var random = SignalRandom(seed: 27)
    let scores = (0..<200).map { _ in random.uniform(0, 1) }
    let result = ESTOI.Result(score: scores.reduce(0, +) / 200, segmentScores: scores, speechFrames: 229)
    let brute = (0...(200 - 78)).map { start in scores[start..<(start + 78)].reduce(0, +) / 78 }.min() ?? 0
    checkClose(result.worstWindow(), brute, "最差 78 段 = 逐段平均里最低的", tolerance: 1e-12)
    let few = ESTOI.Result(score: 0.5, segmentScores: [0.4, 0.6], speechFrames: 31)
    checkEqual(few.worstWindow(), 0.5, "段数不够 78 就是整句")
}

/// 15 个带的频点和 numpy 版算出来的一样（最低一带从第 7 个频点 = 136.7 Hz 起，最高一带到第 218 个 = 4258 Hz）。
private func checkBandLayout() {
    checkEqual(ESTOIAnalysis.bandBins.count, 15, "15 个带")
    checkEqual(ESTOIAnalysis.bandBins.first, 7...8, "最低一带是第 7–8 个频点")
    checkEqual(ESTOIAnalysis.bandBins.last, 174...218, "最高一带是第 174–218 个频点")
    checkEqual(ESTOIAnalysis.window.count, 256, "256 点的窗")
    check(ESTOIAnalysis.window.first! > 0 && abs(ESTOIAnalysis.window[127] - ESTOIAnalysis.window[128]) < 1e-15, "窗两头不是 0、左右对称")
}
