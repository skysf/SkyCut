import Foundation

/// 「主要是谁盖住了这句」：把别的某一层拿掉、或压低 6 dB，这句的 ESTOI 涨多少（docs/architecture/listening-engine.md）。
/// 涨得最多的那层就是最该动的那层 —— 南极第三稿最后一句，拿掉镜头原声涨 0.40、拿掉音乐只涨 0.02，第一次量就指向原声。
///
/// 管什么：一句话的干净人声 + 其余每一层（同一个时间窗、同一采样率、单声道）→ 整句 ESTOI、每层涨多少、每层多响，
/// 和 ESTOI 看不见的 150 Hz 以下（别的声音在 20–150 Hz 多响、人声整句多响，同一个窗、同一个口径，两个数放一起看）。
/// 不管什么：层从哪来（第 1 步按层离线渲）、句子从哪到哪、哪层算人声（来路已知：旁白轨、对口型的轨，接线的任务定）；线和报告。
///
/// 混音 = 干净人声 + 各层之和（限幅之前），所以「拿掉」就是不加它：调用方别传限幅以后的成片，不然减出来的不是「没有这一层」。
/// 照研究的 numpy 版：每层先重采样到 10 kHz（线性，等于先混后重采样）；这一窗里 RMS 低于 −60 dBFS 的层不算；
/// 按「拿掉涨多少」从大到小排（一样大再看压低 6 dB 的，再一样按 id 倒序，和 Python 的元组倒序排一致）。
enum MaskerAttribution {
    /// 低于这个电平的层不算（这一窗里几乎没有声音）。
    static let quietLayerDBFS = -60.0
    /// 「压低」压多少。
    static let loweredDB = 6.0
    /// ESTOI 看不见的那一截：20–150 Hz（最低一带的下沿约 134 Hz，取整到 150；20 Hz 以下听不见）。
    static let lowBandHz = 20.0..<150.0

    struct Layer {
        let id: String
        let samples: [Float]
    }

    struct Gain: Equatable {
        let id: String
        /// 拿掉这一层，ESTOI 涨多少（可能是负的：这层反倒让人声更「像自己」，少见）。
        let whenRemoved: Double
        /// 这一层压低 6 dB，ESTOI 涨多少。
        let whenLowered: Double
        /// 这一层在这一窗里多响（10 kHz 上的 RMS，dBFS）。
        let levelDBFS: Double
    }

    struct Result: Equatable {
        let estoi: ESTOI.Result
        /// 每层一行，从「最该动的」排起。
        let gains: [Gain]
        /// 别的声音（各层之和）在 20–150 Hz 多响：ESTOI 看不见的低频，一层重低音能靠「往上盖」盖住人声。
        let othersLowBandDBFS: Double
        /// 干净人声整句多响（全频，同一个窗的 RMS）：和上面那个数放一起比。
        let voiceDBFS: Double
    }

    static func rank(clean: [Float], others: [Layer], sampleRate: Double) -> Result? {
        guard others.allSatisfy({ $0.samples.count == clean.count }) else { return nil }
        let rate = ESTOIAnalysis.sampleRate
        let plan = ListeningResample.Plan(inputLength: clean.count, from: sampleRate, to: rate)
        let clean10k = plan.apply(ListeningResample.doubles(clean))
        let layers10k = others.map { plan.apply(ListeningResample.doubles($0.samples)) }
        var mix = clean10k
        var othersSum = [Double](repeating: 0, count: clean10k.count)
        for layer in layers10k {
            for i in 0..<mix.count {
                mix[i] += layer[i]
                othersSum[i] += layer[i]
            }
        }
        guard let reference = ESTOIReference(clean10k: clean10k), let base = reference.score(mix10k: mix) else { return nil }
        let lowered = 1 - pow(10, -loweredDB / 20)
        var gains: [Gain] = []
        let quietRMS = pow(10, quietLayerDBFS / 20)
        for (layer, samples) in zip(others, layers10k) {
            let rms = ListeningLevel.rms(samples)
            guard rms >= quietRMS else { continue }
            let level = ListeningLevel.decibels(rms: rms)
            let without = zip(mix, samples).map { $0 - $1 }
            let quieter = zip(mix, samples).map { $0 - $1 * lowered }
            guard let removed = reference.score(mix10k: without), let softer = reference.score(mix10k: quieter) else { continue }
            gains.append(Gain(id: layer.id, whenRemoved: removed.score - base.score,
                              whenLowered: softer.score - base.score, levelDBFS: level))
        }
        gains.sort { a, b in
            if a.whenRemoved != b.whenRemoved { return a.whenRemoved > b.whenRemoved }
            if a.whenLowered != b.whenLowered { return a.whenLowered > b.whenLowered }
            return a.id > b.id
        }
        let low = ListeningLevel.bandDecibels(othersSum, sampleRate: rate, low: lowBandHz.lowerBound, high: lowBandHz.upperBound)
        let voice = ListeningLevel.decibels(rms: ListeningLevel.rms(clean10k))
        return Result(estoi: base, gains: gains, othersLowBandDBFS: low, voiceDBFS: voice)
    }
}
