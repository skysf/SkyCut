import Foundation

// 和研究时 numpy 版对账的输入（docs/architecture/listening-engine.md「和 Python 版对」）。
// 这里只造输入；`--dump <目录>` 把它们原样写成小端 float32 给 Python 版读（ListeningDump），自检拿同一份 Float 算，
// 再和 PythonReference.swift 里 Python 版算好的数比（ParityChecks.swift）。改了这里的任何一个信号，对照值就要重算。

enum ListeningParity {
    /// |Swift − Python| ≤ 1e-9 × max(1, |Python|)。为什么是这个数见架构文档：两边同一份输入、同一套算法，
    /// 差只来自 FFT 的实现和加法的先后（实测 ESTOI 和「拿掉谁涨多少」在 1e-15 上下，原声特征最大 2.6e-11）；
    /// 离 ESTOI 线的分辨率（盲听的档距 0.03–0.04）差七个数量级，留的余量给不同版本的系统数学库。
    static let tolerance = 1e-9

    struct ESTOICase {
        let name: String
        let rate: Double
        let clean: [Float]
        let mix: [Float]
    }

    struct MaskerCase {
        let name: String
        let rate: Double
        let clean: [Float]
        let layers: [MaskerAttribution.Layer]
    }

    /// 10 kHz 的五种背景 + 一句长的（够 78 段，最差 1 秒有意义）+ 两句 48 kHz 的（走重采样那条路）。
    static func estoiCases() -> [ESTOICase] {
        let rate = ESTOIAnalysis.sampleRate
        let clean = normalized(TestSignals.speechLike(seconds: 4, rate: rate, seed: 1), rms: 0.1)
        let n = clean.count
        let long = normalized(TestSignals.speechLike(seconds: 9, rate: rate, seed: 7), rms: 0.1)
        let high = 48_000.0
        let clean48 = normalized(TestSignals.speechLike(seconds: 4, rate: high, seed: 9), rms: 0.1)
        let maskers: [(String, Double, [Double], [Double])] = [
            ("white_0dB", rate, clean, TestSignals.noise(TestSignals.whiteNoise(count: n, seed: 2), atSNR: 0, against: clean)),
            ("shaped_-5dB", rate, clean, TestSignals.noise(TestSignals.speechShaped(like: clean, seed: 3), atSNR: -5, against: clean)),
            ("rumble_0dB", rate, clean, TestSignals.noise(TestSignals.rumble(count: n, rate: rate, seed: 4), atSNR: 0, against: clean)),
            ("babble_0dB", rate, clean,
             TestSignals.noise(TestSignals.speechLike(seconds: 4, rate: rate, seed: 5), atSNR: 0, against: clean)),
            ("music_-3dB", rate, clean, TestSignals.noise(TestSignals.musicLike(count: n, rate: rate, seed: 6), atSNR: -3, against: clean)),
            ("long_babble_3dB", rate, long,
             TestSignals.noise(TestSignals.speechLike(seconds: 9, rate: rate, seed: 8), atSNR: 3, against: long)),
            ("48k_music_0dB", high, clean48,
             TestSignals.noise(TestSignals.musicLike(count: clean48.count, rate: high, seed: 10), atSNR: 0, against: clean48)),
            ("48k_white_5dB", high, clean48,
             TestSignals.noise(TestSignals.whiteNoise(count: clean48.count, seed: 11), atSNR: 5, against: clean48))
        ]
        return maskers.map { name, rate, clean, noise in
            ESTOICase(name: name, rate: rate, clean: TestSignals.floats(clean), mix: TestSignals.floats(TestSignals.sum(clean, noise)))
        }
    }

    /// 48 kHz 的一句、五层：别人说话（比人声响 2 dB）、音乐（轻 3 dB）、轰鸣（一样响）、134 Hz 以下的重低音（响 6 dB）、−80 dBFS 的一层（不算）。
    static func maskerCase() -> MaskerCase {
        let rate = 48_000.0
        let clean = normalized(TestSignals.speechLike(seconds: 4, rate: rate, seed: 12), rms: 0.1)
        let n = clean.count
        let layers: [(String, [Double])] = [
            ("babble", TestSignals.noise(TestSignals.speechLike(seconds: 4, rate: rate, seed: 13), atSNR: -2, against: clean)),
            ("music", TestSignals.noise(TestSignals.musicLike(count: n, rate: rate, seed: 14), atSNR: 3, against: clean)),
            ("rumble", TestSignals.noise(TestSignals.rumble(count: n, rate: rate, seed: 15), atSNR: 0, against: clean)),
            ("sub", TestSignals.noise(TestSignals.subBass(count: n, rate: rate), atSNR: -6, against: clean)),
            ("quiet", normalized(TestSignals.whiteNoise(count: n, seed: 16), rms: 1e-4))
        ]
        return MaskerCase(name: "48k_five_layers", rate: rate, clean: TestSignals.floats(clean),
                          layers: layers.map { MaskerAttribution.Layer(id: $0.0, samples: TestSignals.floats($0.1)) })
    }
}
