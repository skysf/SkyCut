import Foundation

// 和研究时的 numpy 版逐数对账：同一份输入（ParityCases.swift，`--dump` 写给 Python 的就是它），
// Python 版算好的数在 PythonReference.swift。每个数差不过 ListeningParity.tolerance；对不上的、少了对照值的都红。

func runParityChecks() {
    checkESTOIParity()
    checkMaskerParity()
    checkFeatureParity()
}

private func checkESTOIParity() {
    let cases = ListeningParity.estoiCases()
    checkEqual(Set(cases.map(\.name)), Set(PythonReference.estoi.keys), "每个 ESTOI 案子都有 Python 版的对照值")
    for item in cases {
        guard let expected = PythonReference.estoi[item.name] else { continue }
        guard let result = ESTOI.score(clean: item.clean, mix: item.mix, sampleRate: item.rate) else {
            check(false, "\(item.name)：Swift 版算不出")
            continue
        }
        checkParity(result.score, expected.score, "\(item.name)：整句 ESTOI")
        checkParity(result.worstWindow(), expected.worst, "\(item.name)：最差 1 秒")
        checkEqual(result.speechFrames, expected.frames, "\(item.name)：去静音以后的帧数")
        checkEqual(result.segmentScores.count, expected.segments, "\(item.name)：段数")
        guard result.segmentScores.count == expected.segments, expected.segments > 0 else { continue }
        let scores = result.segmentScores
        checkParity(scores[0], expected.first, "\(item.name)：第一段")
        checkParity(scores[scores.count / 2], expected.middle, "\(item.name)：中间那段")
        checkParity(scores[scores.count - 1], expected.last, "\(item.name)：最后一段")
    }
}

private func checkMaskerParity() {
    let item = ListeningParity.maskerCase()
    guard let result = MaskerAttribution.rank(clean: item.clean, others: item.layers, sampleRate: item.rate) else {
        return check(false, "\(item.name)：Swift 版算不出")
    }
    checkParity(result.estoi.score, PythonReference.maskerBase, "\(item.name)：基准 ESTOI")
    checkEqual(result.gains.map(\.id), PythonReference.maskerGains.map(\.id), "\(item.name)：排序和不算的层一样")
    for (gain, expected) in zip(result.gains, PythonReference.maskerGains) {
        checkParity(gain.whenRemoved, expected.removed, "\(item.name) / \(gain.id)：拿掉涨多少")
        checkParity(gain.whenLowered, expected.lowered, "\(item.name) / \(gain.id)：压低 6 dB 涨多少")
        checkParity(gain.levelDBFS, expected.level, "\(item.name) / \(gain.id)：电平")
    }
}

private func checkFeatureParity() {
    let signals = featureSignals()
    checkEqual(Set(signals.map(\.name)), Set(PythonReference.features.keys), "每种原声都有 Python 版的对照值")
    for (name, samples) in signals {
        guard let expected = PythonReference.features[name] else { continue }
        guard let f = SourceSoundFeatures.measure(samples) else {
            check(false, "\(name)：Swift 版算不出特征")
            continue
        }
        checkParity(f.centroidHz, expected.centroid, "\(name)：频谱重心")
        checkParity(f.flatness, expected.flat, "\(name)：平坦度")
        checkParity(f.lowShare, expected.low, "\(name)：300 Hz 以下占比")
        checkParity(f.chromaTop3, expected.chroma3, "\(name)：音级集中度")
        checkParity(f.chromaStability, expected.chromaStab, "\(name)：音级稳不稳")
        checkParity(f.pitchStrength, expected.pitch, "\(name)：音高强度")
        checkParity(f.pulseClarity, expected.pulse, "\(name)：拍子清不清楚")
        checkParity(f.levelSpreadDB, expected.steady, "\(name)：电平起伏")
        checkParity(f.syllabicShare, expected.mod4, "\(name)：2–8 Hz 起伏")
    }
}
