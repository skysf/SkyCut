import Foundation

// 自检用的合成信号：类语音（按音节开合的浊音 + 清音）、白噪声、人声形状的噪声、低沉轰鸣、类音乐（和弦 + 每 0.5 秒一下）、
// 敲击、只在 134 Hz 以下的重低音。不提交任何真录音（仓库是公开的）。全是确定的：同一个种子永远同一份采样，
// 所以 `--dump` 写给 Python 版的那份和自检里算的那份逐位一样（见 ParityChecks.swift）。

/// SplitMix64。只要求同一个种子每次一样，不要求和 Python 的随机数对得上（Python 读的是写出来的文件）。
struct SignalRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * uniform() }

    /// Box–Muller。
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

enum TestSignals {
    /// 类语音：0.15 秒起，一个个音节（120–320 ms，中间隔 40–160 ms，过半时停 0.4 秒），每个音节响度不一样（−12–0 dB）。
    /// 每个音节：基频 100–210 Hz 慢慢滑、带一点随机游走的抖动，谐波到 4.5 kHz、按三个「共振峰」加重，混一点气声；
    /// 三成多的音节尾巴带一截清音（白噪声）。开合各 20 ms 升余弦。抖动和气声是为了不像纯的乐音（研究里旁白的音高强度 0.42–0.63）。
    static func speechLike(seconds: Double, rate: Double, seed: UInt64) -> [Double] {
        var random = SignalRandom(seed: seed)
        var out = [Double](repeating: 0, count: Int(seconds * rate))
        var t = 0.15
        var paused = false
        while t < seconds - 0.3 {
            let length = min(random.uniform(0.12, 0.32), seconds - 0.15 - t)
            addSyllable(into: &out, rate: rate, start: t, length: length, random: &random)
            t += length + random.uniform(0.04, 0.16)
            if !paused, t > seconds / 2 { t += 0.4; paused = true }
        }
        return out
    }

    private static func addSyllable(into out: inout [Double], rate: Double, start: Double, length: Double,
                                    random: inout SignalRandom) {
        let f0Start = random.uniform(100, 210)
        let f0End = f0Start * random.uniform(0.85, 1.15)
        let formants = [random.uniform(300, 800), random.uniform(900, 2200), random.uniform(2300, 3200)]
        let fricative = random.uniform() < 0.35
        let loudness = pow(10, random.uniform(-12, 0) / 20)
        let ceiling = min(4500, 0.45 * rate)
        let meanF0 = (f0Start + f0End) / 2
        // 每个谐波的增益按这个音节的平均基频算一次（逐采样算太慢，也没必要）。
        let gains = (1...Int(ceiling / 90)).map { k -> Double in
            let frequency = Double(k) * meanF0
            var gain = 0.08
            for (j, formant) in formants.enumerated() {
                let w = (frequency - formant) / (90 + 60 * Double(j))
                gain += exp(-w * w)
            }
            return gain / Double(k).squareRoot()
        }
        let first = Int(start * rate)
        let count = Int(length * rate)
        let ramp = max(1, Int(0.02 * rate))
        var phase = 0.0
        // 基频抖动：一阶自回归，相关时间 20 ms、标准差 5%（系数按采样率换算，几种采样率下一个样）。
        let memory = exp(-1 / (0.02 * rate))
        let kick = 0.05 * (1 - memory * memory).squareRoot()
        var jitter = 0.0
        for i in 0..<count where first + i < out.count {
            let progress = Double(i) / Double(count)
            jitter = memory * jitter + kick * random.gaussian()
            let f0 = (f0Start + (f0End - f0Start) * progress) * (1 + jitter)
            phase += 2 * Double.pi * f0 / rate
            var voiced = 0.0
            for k in gains.indices where Double(k + 1) * f0 < ceiling {
                voiced += gains[k] * sin(Double(k + 1) * phase)
            }
            var sample = 0.25 * voiced + 0.01 * random.gaussian()
            if fricative, progress > 0.6 { sample += 0.12 * random.gaussian() }
            let edge = min(i, count - 1 - i)
            let envelope = edge < ramp ? 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(ramp)) : 1
            out[first + i] += loudness * sample * envelope
        }
    }

    static func whiteNoise(count: Int, seed: UInt64) -> [Double] {
        var random = SignalRandom(seed: seed)
        return (0..<count).map { _ in random.gaussian() }
    }

    /// 和 x 一样的长时幅度谱、随机相位（研究自检里「人声形状的噪声」的做法）。
    static func speechShaped(like x: [Double], seed: UInt64) -> [Double] {
        var random = SignalRandom(seed: seed)
        let dft = ListeningDFT(length: x.count)
        let spectrum = dft.realForward(x)
        var re = spectrum.re
        var im = spectrum.im
        for k in re.indices {
            let magnitude = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            let angle = random.uniform(0, 2 * Double.pi)
            re[k] = magnitude * cos(angle)
            im[k] = magnitude * sin(angle)
        }
        return dft.realInverse(re: re, im: im)
    }

    /// 低沉轰鸣：只留 40–400 Hz 的白噪声（七成多能量在 300 Hz 以下），0.3 Hz 慢慢起伏 ±20%。
    /// 不带纯音（带一个稳定的嗡声就成了「有音高」），也不用一阶低通（6 dB 一倍频程的尾巴拖到几 kHz，平坦度就像宽频噪声了）：
    /// 研究里南极 `Shot4` 那层轰鸣，平坦度 0.001–0.002、音高强度 0.23。
    static func rumble(count: Int, rate: Double, seed: UInt64) -> [Double] {
        let noise = whiteNoise(count: count, seed: seed)
        let dft = ListeningDFT(length: count)
        var spectrum = dft.realForward(noise)
        for k in spectrum.re.indices {
            let frequency = Double(k) * rate / Double(count)
            if frequency < 40 || frequency > 400 { spectrum.re[k] = 0; spectrum.im[k] = 0 }
        }
        let band = dft.realInverse(re: spectrum.re, im: spectrum.im)
        return band.indices.map { i in (1 + 0.2 * sin(2 * Double.pi * 0.3 * Double(i) / rate)) * band[i] }
    }

    /// 只在 134 Hz 以下（ESTOI 看不见的那一截）：40 Hz 和 50 Hz，各自 0.5 Hz、0.7 Hz 慢慢起伏。
    static func subBass(count: Int, rate: Double) -> [Double] {
        (0..<count).map { i in
            let t = Double(i) / rate
            return (1 + 0.3 * sin(2 * Double.pi * 0.5 * t)) * sin(2 * Double.pi * 40 * t)
                + 0.7 * (1 + 0.3 * sin(2 * Double.pi * 0.7 * t)) * sin(2 * Double.pi * 50 * t)
        }
    }

    /// 类音乐：三个和弦每 1.5 秒换一个（每个音四个谐波），每 0.5 秒一下鼓（60 Hz 的闷响 + 1.5 kHz 的短敲击）、
    /// 和弦跟着拍子一涨一落，底下 −50 dB 的噪声。
    static func musicLike(count: Int, rate: Double, seed: UInt64) -> [Double] {
        let chords: [[Double]] = [[220, 277.18, 329.63], [196, 246.94, 293.66], [174.61, 220, 261.63]]
        let floor = whiteNoise(count: count, seed: seed)
        return (0..<count).map { i in
            let t = Double(i) / rate
            let chord = chords[Int(t / 1.5) % chords.count]
            let sinceBeat = t.truncatingRemainder(dividingBy: 0.5)
            var sample = 0.0
            for note in chord {
                for h in 1...4 { sample += 0.12 / Double(h) * sin(2 * Double.pi * note * Double(h) * t) }
            }
            sample *= 0.6 + 0.4 * exp(-sinceBeat / 0.15)
            sample += 0.8 * exp(-sinceBeat / 0.06) * sin(2 * Double.pi * 60 * sinceBeat)
            sample += 0.4 * exp(-sinceBeat / 0.03) * sin(2 * Double.pi * 1500 * sinceBeat)
            return sample + 0.003 * floor[i]
        }
    }

    /// 敲击：每 0.5 秒一下（120 BPM），每下是 20 ms 衰减的白噪声；底下 −46 dB 的噪声。
    static func clicks(count: Int, rate: Double, seed: UInt64) -> [Double] {
        let noise = whiteNoise(count: count, seed: seed)
        return (0..<count).map { i in
            let sinceBeat = (Double(i) / rate).truncatingRemainder(dividingBy: 0.5)
            return 0.5 * exp(-sinceBeat / 0.02) * noise[i] + 0.005 * noise[(i * 7 + 3) % count]
        }
    }

    /// 持续的和弦（一个和弦不换），−40 dB 的噪声垫底（一点噪声都没有的纯音，特征全是数值噪声，对不了账）。
    static func chord(count: Int, rate: Double, seed: UInt64) -> [Double] {
        let floor = whiteNoise(count: count, seed: seed)
        return (0..<count).map { i in
            let t = Double(i) / rate
            var sample = 0.0
            for note in [220.0, 277.18, 329.63] {
                for h in 1...3 { sample += 0.15 / Double(h) * sin(2 * Double.pi * note * Double(h) * t) }
            }
            return sample * (1 + 0.05 * sin(2 * Double.pi * 0.4 * t)) + 0.01 * floor[i]
        }
    }

    /// x × gain。
    static func scaled(_ x: [Double], by gain: Double) -> [Double] { x.map { $0 * gain } }

    /// 把 noise 调到相对 clean 的信噪比（整段功率比，dB）以后的那一份（只返回调好的 noise）。
    static func noise(_ noise: [Double], atSNR snr: Double, against clean: [Double]) -> [Double] {
        let cleanPower = clean.reduce(0) { $0 + $1 * $1 } / Double(clean.count)
        let noisePower = noise.reduce(0) { $0 + $1 * $1 } / Double(noise.count)
        return scaled(noise, by: (cleanPower / noisePower / pow(10, snr / 10)).squareRoot())
    }

    static func sum(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { $0 + $1 } }

    static func floats(_ x: [Double]) -> [Float] { x.map { Float($0) } }
}
