import Foundation

// 原声的描述：合成的几种声音各自该占哪几个词（低沉长音 / 宽频噪声 / 有音高 / 有拍子 / 像说话），不该占的不占；
// 按 3 秒一窗切、太轻的窗不说、任意采样率先换到 16 kHz。特征和 Python 版逐数对账在 ParityChecks.swift。

/// 自检和 `--dump` 共用的六种原声，16 kHz、3 秒、RMS 0.1。
func featureSignals() -> [(name: String, samples: [Double])] {
    let rate = SourceSoundFeatures.sampleRate
    let count = Int(3 * rate)
    let raw: [(String, [Double])] = [
        ("rumble", TestSignals.rumble(count: count, rate: rate, seed: 41)),
        ("noise", TestSignals.whiteNoise(count: count, seed: 42)),
        ("chord", TestSignals.chord(count: count, rate: rate, seed: 43)),
        ("clicks", TestSignals.clicks(count: count, rate: rate, seed: 44)),
        ("speech", TestSignals.speechLike(seconds: 3, rate: rate, seed: 45)),
        ("music", TestSignals.musicLike(count: count, rate: rate, seed: 46))
    ]
    return raw.map { (name: $0.0, samples: TestSignals.floats(normalized($0.1, rms: 0.1)).map(Double.init)) }
}

func runTraitChecks() {
    let expected: [String: Set<SourceSoundTrait>] = [
        "rumble": [.lowDrone],
        "noise": [.broadbandNoise],
        "chord": [.pitched],
        "clicks": [.broadbandNoise, .rhythmic],
        "speech": [.speechLike],
        "music": [.pitched, .rhythmic]
    ]
    for (name, samples) in featureSignals() {
        guard let features = SourceSoundFeatures.measure(samples) else {
            check(false, "\(name)：3 秒算不出特征")
            continue
        }
        let traits = Set(SourceSoundTrait.traits(of: features))
        checkEqual(traits, expected[name] ?? [], "\(name) 的描述（\(features)）")
    }
    checkWindowing()
}

/// 48 kHz 的 7 秒：前 3 秒轰鸣、中间 3 秒几乎没声音（−70 dBFS）、最后 1 秒不满一窗。只说第一窗。
private func checkWindowing() {
    let rate = 48_000.0
    let window = Int(3 * rate)
    let rumble = normalized(TestSignals.rumble(count: window, rate: rate, seed: 47), rms: 0.1)
    let hush = normalized(TestSignals.whiteNoise(count: window, seed: 48), rms: pow(10, -70.0 / 20))
    let tail = [Double](repeating: 0.1, count: Int(rate))
    let windows = SourceSoundDescription.describe(TestSignals.floats(rumble + hush + tail), sampleRate: rate)
    checkEqual(windows.map(\.start), [0], "只有第一窗：太轻的不说、不满 3 秒的尾巴不要")
    checkEqual(windows.first?.traits, [.lowDrone], "48 kHz 交进来的轰鸣还是低沉长音")
    check(SourceSoundFeatures.measure([Double](repeating: 0.1, count: 15_999)) == nil, "不到 1 秒不量")
}
