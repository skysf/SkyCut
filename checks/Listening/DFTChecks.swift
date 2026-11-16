import Foundation

// 地基：任意长度的 DFT（vDSP 直接认的长度和 Bluestein 两条路）对朴素 DFT；rfft / irfft 的 numpy 口径；
// 整段 FFT 截断的重采样；新长度「一半取偶」；电平和 20–150 Hz 那一截的口径。

func runDFTChecks() {
    checkDFTAgainstNaive()
    checkRealRoundTrip()
    checkResample()
    checkLevels()
}

/// O(n²) 的定义式，只拿来对照。指数 −2πi·kt/n。
private func naiveDFT(_ re: [Double], _ im: [Double]) -> ([Double], [Double]) {
    let n = re.count
    var outRe = [Double](repeating: 0, count: n)
    var outIm = [Double](repeating: 0, count: n)
    for k in 0..<n {
        for t in 0..<n {
            let angle = -2 * Double.pi * Double((k * t) % n) / Double(n)
            outRe[k] += re[t] * cos(angle) - im[t] * sin(angle)
            outIm[k] += re[t] * sin(angle) + im[t] * cos(angle)
        }
    }
    return (outRe, outIm)
}

private func checkDFTAgainstNaive() {
    var random = SignalRandom(seed: 11)
    // 1、2、8、512：vDSP 直接认；3、7、31、100、300、1000：Bluestein。
    for n in [1, 2, 3, 7, 8, 31, 100, 300, 512, 1000] {
        let re = (0..<n).map { _ in random.uniform(-1, 1) }
        let im = (0..<n).map { _ in random.uniform(-1, 1) }
        let fast = ListeningDFT(length: n).forward(re: re, im: im)
        let slow = naiveDFT(re, im)
        var gap = 0.0
        for k in 0..<n { gap = max(gap, abs(fast.re[k] - slow.0[k]), abs(fast.im[k] - slow.1[k])) }
        check(gap <= 1e-11 * Double(n), "长度 \(n) 的 DFT 和定义式差 \(gap)")
    }
}

private func checkRealRoundTrip() {
    var random = SignalRandom(seed: 12)
    for n in [5, 6, 300, 301, 1488] {
        let x = (0..<n).map { _ in random.uniform(-1, 1) }
        let dft = ListeningDFT(length: n)
        let spectrum = dft.realForward(x)
        checkEqual(spectrum.re.count, n / 2 + 1, "长度 \(n) 的 rfft 有 n/2+1 个频点")
        let back = dft.realInverse(re: spectrum.re, im: spectrum.im)
        let gap = zip(back, x).map { abs($0 - $1) }.max() ?? 1
        check(gap <= 1e-12, "长度 \(n)：irfft(rfft(x)) 回到 x，差 \(gap)")
    }
    // numpy 的 irfft：直流、偶数长度的最高频点只取实部（虚部给什么都一样）。
    let re = [1.0, 0.5, -0.25, 0.75]
    let plain = ListeningDFT(length: 6).realInverse(re: re, im: [0, 0.3, -0.2, 0])
    let noisy = ListeningDFT(length: 6).realInverse(re: re, im: [9, 0.3, -0.2, -7])
    check(zip(plain, noisy).allSatisfy { abs($0 - $1) <= 1e-15 }, "irfft 不看直流和最高频点的虚部")
}

private func checkResample() {
    // 一个窗里正好整数个周期的正弦：FFT 截断重采样是精确的。
    let rate = 48_000.0
    let tone = (0..<48_000).map { sin(2 * Double.pi * 1000 * Double($0) / rate) }
    let down = ListeningResample.resample(tone, from: rate, to: 10_000)
    checkEqual(down.count, 10_000, "1 秒 48 kHz → 10 kHz 是 10000 个采样")
    let downGap = down.indices.map { abs(down[$0] - sin(2 * Double.pi * 1000 * Double($0) / 10_000)) }.max() ?? 1
    check(downGap <= 1e-9, "1 kHz 正弦降到 10 kHz 以后还是同一个正弦，差 \(downGap)")
    // 新奈奎斯特（5 kHz）以上的一刀切掉：7 kHz 的正弦降到 10 kHz 以后什么都不剩。
    let high = (0..<48_000).map { sin(2 * Double.pi * 7000 * Double($0) / rate) }
    let alias = ListeningResample.resample(high, from: rate, to: 10_000).map(abs).max() ?? 1
    check(alias <= 1e-9, "7 kHz 降到 10 kHz 不折回来，剩 \(alias)")
    // 先升再降回原样（10 kHz 的内容 48 kHz 装得下）。
    var random = SignalRandom(seed: 13)
    let x = (0..<997).map { _ in random.gaussian() }
    let round = ListeningResample.resample(ListeningResample.resample(x, from: 10_000, to: 48_000), from: 48_000, to: 10_000)
    checkEqual(round.count, x.count, "升到 48 kHz 再降回来长度不变")
    let roundGap = zip(round, x).map { abs($0 - $1) }.max() ?? 1
    check(roundGap <= 1e-9, "升了再降回到原样，差 \(roundGap)")
    // 新长度一半取偶：12 × 10000 / 48000 = 2.5 → 2，60 → 12.5 → 12，36 → 7.5 → 8；和 Python 的 round 一样。
    checkEqual(ListeningResample.outputLength(inputLength: 12, from: 48_000, to: 10_000), 2, "2.5 取偶是 2")
    checkEqual(ListeningResample.outputLength(inputLength: 60, from: 48_000, to: 10_000), 12, "12.5 取偶是 12")
    checkEqual(ListeningResample.outputLength(inputLength: 36, from: 48_000, to: 10_000), 8, "7.5 取偶是 8")
}

private func checkLevels() {
    // 满刻度的正弦是 −3.01 dBFS（RMS 口径，不加 AES 的 +3 dB）。
    let rate = 10_000.0
    let tone = (0..<20_000).map { 0.5 * sin(2 * Double.pi * 100 * Double($0) / rate) }
    let expected = 20 * log10(0.5 / 2.0.squareRoot())
    checkClose(ListeningLevel.decibels(rms: ListeningLevel.rms(tone)), expected, "0.5 幅度正弦的电平", tolerance: 1e-6)
    // 20–150 Hz 那一截：100 Hz 全算进去，1 kHz 一点都不算。
    checkClose(ListeningLevel.bandDecibels(tone, sampleRate: rate, low: 20, high: 150), expected,
               "100 Hz 正弦全在 20–150 Hz 里", tolerance: 1e-6)
    let kilo = (0..<20_000).map { 0.5 * sin(2 * Double.pi * 1000 * Double($0) / rate) }
    check(ListeningLevel.bandDecibels(kilo, sampleRate: rate, low: 20, high: 150) < -150, "1 kHz 正弦不在 20–150 Hz 里")
    checkClose(ListeningLevel.decibels(rms: ListeningLevel.rms([0, 0, 0])), -240, "全是 0 是 −240 dBFS", tolerance: 1e-9)
}
