import Foundation

// 「拿掉谁涨多少」：最该动的那层排第一、134 Hz 以下的那层几乎不涨但 20–150 Hz 报得出来、太轻的层不算、
// 每个数就是「拿掉 / 压低以后的 ESTOI − 原来的」、长度不一样回 nil。和 Python 版逐数对账在 ParityChecks.swift。

func runMaskerChecks() {
    let rate = ESTOIAnalysis.sampleRate
    let clean = normalized(TestSignals.speechLike(seconds: 4, rate: rate, seed: 31), rms: 0.1)
    let babble = TestSignals.noise(TestSignals.speechLike(seconds: 4, rate: rate, seed: 32), atSNR: -3, against: clean)
    let music = TestSignals.noise(TestSignals.musicLike(count: clean.count, rate: rate, seed: 33), atSNR: 6, against: clean)
    let sub = TestSignals.noise(TestSignals.subBass(count: clean.count, rate: rate), atSNR: -6, against: clean)
    let quiet = normalized(TestSignals.whiteNoise(count: clean.count, seed: 34), rms: 1e-4)   // −80 dBFS
    let layers = [("babble", babble), ("music", music), ("sub", sub), ("quiet", quiet)].map {
        MaskerAttribution.Layer(id: $0.0, samples: TestSignals.floats($0.1))
    }
    let cleanFloats = TestSignals.floats(clean)
    guard let result = MaskerAttribution.rank(clean: cleanFloats, others: layers, sampleRate: rate) else {
        return check(false, "四层的那一句算不出")
    }
    checkEqual(result.gains.map(\.id), ["babble", "music", "sub"], "按拿掉涨多少排：别人说话、音乐、重低音；−80 dBFS 的那层不算")
    if let top = result.gains.first {
        check(top.whenRemoved > top.whenLowered && top.whenLowered > 0.02, "拿掉比压低 6 dB 涨得多，压低也真涨 \(top)")
    }
    if let sub = result.gains.first(where: { $0.id == "sub" }) {
        check(abs(sub.whenRemoved) < 0.02, "134 Hz 以下的那层拿掉几乎不涨（ESTOI 看不见它）：\(sub.whenRemoved)")
    }
    // 看不见的那一截另报：别的声音在 20–150 Hz 比人声整句还响。
    check(result.othersLowBandDBFS > result.voiceDBFS, "20–150 Hz 报得出重低音：\(result.othersLowBandDBFS) 对人声 \(result.voiceDBFS)")
    checkClose(result.voiceDBFS, -20, "人声整句 −20 dBFS（RMS 0.1）", tolerance: 0.05)
    checkConsistency(result, clean: clean, layers: layers)
    let short = layers.map { MaskerAttribution.Layer(id: $0.id, samples: Array($0.samples.dropLast())) }
    check(MaskerAttribution.rank(clean: cleanFloats, others: short, sampleRate: rate) == nil, "层和人声长度不一样回 nil")
}

/// 每个数都能从头复算：基准 = ESTOI(人声, 人声 + 各层)；涨多少 = ESTOI(人声, 混音 − 这一层（× 1 或 × (1 − 10^(−6/20))）) − 基准。
private func checkConsistency(_ result: MaskerAttribution.Result, clean: [Double], layers: [MaskerAttribution.Layer]) {
    let doubles = layers.map { ListeningResample.doubles($0.samples) }
    let cleanD = ListeningResample.doubles(TestSignals.floats(clean))
    var mix = cleanD
    for layer in doubles { for i in mix.indices { mix[i] += layer[i] } }
    let reference = ESTOIReference(clean10k: cleanD)
    checkClose(reference?.score(mix10k: mix)?.score, result.estoi.score, "基准就是人声对整条混音", tolerance: 1e-12)
    for gain in result.gains {
        guard let index = layers.firstIndex(where: { $0.id == gain.id }) else { continue }
        let without = zip(mix, doubles[index]).map { $0 - $1 }
        let softer = zip(mix, doubles[index]).map { $0 - $1 * (1 - pow(10, -6.0 / 20)) }
        checkClose(reference?.score(mix10k: without).map { $0.score - result.estoi.score }, gain.whenRemoved,
                   "\(gain.id)：拿掉涨多少", tolerance: 1e-12)
        checkClose(reference?.score(mix10k: softer).map { $0.score - result.estoi.score }, gain.whenLowered,
                   "\(gain.id)：压低 6 dB 涨多少", tolerance: 1e-12)
        checkClose(gain.levelDBFS, ListeningLevel.decibels(rms: ListeningLevel.rms(doubles[index])), "\(gain.id)：电平", tolerance: 1e-12)
    }
}
