import Foundation

/// 「听声音的引擎」的重采样和电平换算（docs/architecture/listening-engine.md）。
///
/// 管什么：把一段单声道采样整段换到 ESTOI 要的 10 kHz、原声特征要的 16 kHz；RMS → dBFS 的口径。
/// 不管什么：给播放、成片用的重采样（音频引擎里的 `AudioSegmentReader`，那是 `AVAudioConverter`）；声道怎么合
/// （调用方先取 (L+R)/2，和研究时一样）；分频段电平（第 1 步，按层量混音那一块）。
///
/// 重采样照研究时 numpy 版的做法：整段做一次 FFT，频点截到新长度的一半（升采样就补零），再反变换、乘 m/n。
/// 等于在新的奈奎斯特频率上一刀切的理想低通，零相位；代价是把这一段当成首尾相接的周期信号，开头结尾差得多时
/// 两头有一点振铃（按理想低通估，离开头结尾 0.2 秒处约是那一跳的 −76 dB）。ESTOI 的线是拿这种重采样量出来的，
/// 所以产品里也用它，不换成多相滤波：
/// 换了，同一段声音和研究里的数就差在第三位小数上，线就不再是同一把尺子。
/// 内存随段长走（Bluestein 要 ≥ 2n 点的卷积）：一句一窗（几秒到十几秒）是几 MB 到几十 MB，别拿整条片子一次做。
enum ListeningResample {
    /// 新长度 = round(n × 新采样率 / 旧采样率)，round 是「一半取偶」：和 Python 的 `round` 一样，不然 n × 比例正好
    /// 落在 .5 上时两边差一个采样（48 kHz → 10 kHz 时 n = 12、36、60…… 就是）。
    static func outputLength(inputLength n: Int, from inputRate: Double, to outputRate: Double) -> Int {
        Int((Double(n) * outputRate / inputRate).rounded(.toNearestOrEven))
    }

    static func resample(_ x: [Double], from inputRate: Double, to outputRate: Double) -> [Double] {
        Plan(inputLength: x.count, from: inputRate, to: outputRate).apply(x)
    }

    /// 同样长、同一对采样率的好几段（一句话的人声和每一层）：两个 DFT 只准备一次（Bluestein 的 chirp 和卷积核不便宜）。
    struct Plan {
        let inputLength: Int
        let outputLength: Int
        /// nil = 不用变（采样率一样，或者是空的）。
        private let transforms: (analysis: ListeningDFT, synthesis: ListeningDFT)?

        init(inputLength n: Int, from inputRate: Double, to outputRate: Double) {
            precondition(inputRate > 0 && outputRate > 0, "采样率要大于 0")
            inputLength = n
            let changes = inputRate != outputRate && n > 0
            let m = changes ? ListeningResample.outputLength(inputLength: n, from: inputRate, to: outputRate) : n
            outputLength = m
            transforms = changes && m > 0 ? (ListeningDFT(length: n), ListeningDFT(length: m)) : nil
        }

        func apply(_ x: [Double]) -> [Double] {
            precondition(x.count == inputLength, "长度和准备的不一样")
            guard let transforms else { return outputLength == 0 ? [] : x }
            let spectrum = transforms.analysis.realForward(x)
            let keep = min(outputLength / 2 + 1, spectrum.re.count)
            let scale = Double(outputLength) / Double(inputLength)
            return transforms.synthesis.realInverse(re: Array(spectrum.re.prefix(keep)), im: Array(spectrum.im.prefix(keep)))
                .map { $0 * scale }
        }
    }

    /// 引擎渲出来的是 `Float`；这里一律换成 `Double` 再算，和 numpy 版同一个精度。
    static func doubles(_ samples: [Float]) -> [Double] {
        samples.map { Double($0) }
    }
}

/// RMS 和 dBFS：20·log10(RMS + 1e-12)，和研究里每层电平的写法一样。满刻度的正弦是 −3.01 dBFS（不加 AES 的 +3 dB）；
/// 全是 0 的时候是 −240 dBFS，调用方按「没有声音」处理。
enum ListeningLevel {
    static func rms(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        var sum = 0.0
        for value in x { sum += value * value }
        return (sum / Double(x.count)).squareRoot()
    }

    static func decibels(rms: Double) -> Double {
        20 * log10(rms + 1e-12)
    }

    /// 一段声音在 [low, high) 赫兹里有多响（dBFS，按上面的口径）。整段做一次 DFT、按帕塞瓦尔定理只加这几个频点：
    /// 等于先用理想带通滤一遍、再算整段的 RMS。ESTOI 看不见 134 Hz 以下，所以每句另报 20–150 Hz（`MaskerAttribution`）；
    /// 20 Hz 以下听不见、也盖不住人声，不算。
    static func bandDecibels(_ x: [Double], sampleRate: Double, low: Double, high: Double) -> Double {
        let n = x.count
        guard n > 1 else { return decibels(rms: 0) }
        let spectrum = ListeningDFT(length: n).realForward(x)
        var energy = 0.0
        for k in 1..<spectrum.re.count {
            let frequency = Double(k) * sampleRate / Double(n)
            guard frequency >= low, frequency < high else { continue }
            let power = spectrum.re[k] * spectrum.re[k] + spectrum.im[k] * spectrum.im[k]
            // 正负频率成对，偶数长度的最高频点只有一个。
            energy += (2 * k == n) ? power : 2 * power
        }
        let meanSquare = energy / (Double(n) * Double(n))
        return decibels(rms: meanSquare.squareRoot())
    }
}
