import Foundation

/// 把原声特征说成几个词：低沉长音 / 宽频噪声 / 有音高 / 有拍子 / 像说话（docs/architecture/listening-engine.md 第 3 步）。
///
/// 管什么：每 3 秒一窗的特征 → 这几个词里占了哪几个（可以几个一起、也可以一个都不占）。
/// 不管什么：**不判「是不是音乐」**（研究的结论：这几样特征够描述、不够分类）；这个声音是什么东西（风、船、雨）——
/// 那要苹果 SoundAnalysis 每个标签自己的分数，留给接线的任务；人声有没有字（SpeechTranscriber）同上。
///
/// 每个词的线是照研究时量过的那一批声音（一部片子的 104 个 3 秒窗：镜头原声、风、雨、船、地铁、两条长音效果、
/// 四条生成的音乐、旁白）挑的，**没有留出来的样本验过**，只当「大概是这样」的描述给 AI；改线先改架构文档里那张表。
enum SourceSoundTrait: String, CaseIterable {
    /// 低沉长音：300 Hz 以下占六成以上、电平稳（每 0.1 秒的起伏 ≤ 6 dB）、没有拍子。南极 `Shot4` 那层被听成「背景乐」的轰鸣。
    case lowDrone = "low_drone"
    /// 宽频噪声（风、雨、水、碎冰）：频谱平坦度 ≥ 0.05。研究里的音乐最高 0.045、人声 ≤ 0.003、雨打伞面 0.32。
    case broadbandNoise = "broadband_noise"
    /// 有音高：音高强度 ≥ 0.6，或者最强 3 个音级占 ≥ 0.75（和弦、持续的音）。高架那段「有稳定音高的嗡声」是 0.71。
    case pitched
    /// 有拍子：拍子清不清楚 ≥ 0.5，而且电平起伏 ≥ 1 dB。后一条防的是一动不动的声音（合成的纯音）：它的频谱通量
    /// 全是数值噪声，每带除以自己的平均以后照样能有很高的自相关（实测 220 Hz 的纯正弦 0.78）；研究里拍子 ≥ 0.5 的音乐窗，
    /// 电平起伏最小也有 1.3 dB。
    case rhythmic
    /// 像说话：2–8 Hz 的起伏占 ≥ 0.3、电平起伏 ≥ 5.5 dB、相邻半秒的音级不稳（< 0.9）、音高强度 < 0.65。
    /// 最后一条是因为唱的、乐器的长音比说话的周期性强（说话有清音、有抖动）：研究里人声 0.42–0.63；
    /// 前三条都占了的音乐窗（12 个）音高强度 0.64–0.82，11 个在 0.65 以上。
    case speechLike = "speech_like"

    static let lowShare = 0.6
    static let steadyAtMostDB = 6.0
    static let rhythmAtLeast = 0.5
    static let rhythmSpreadAtLeastDB = 1.0
    static let flatnessAtLeast = 0.05
    static let pitchAtLeast = 0.6
    static let chromaAtLeast = 0.75
    static let syllabicAtLeast = 0.3
    static let speechSpreadAtLeastDB = 5.5
    static let speechChromaBelow = 0.9
    static let speechPitchBelow = 0.65

    /// 特征 → 词（按 `allCases` 的顺序）。音高强度、拍子、音级稳不稳是 nil（窗太短、太轻）时，按「不占」算。
    static func traits(of f: SourceSoundFeatures) -> [SourceSoundTrait] {
        let pitch = f.pitchStrength ?? 0
        let rhythmic = (f.pulseClarity ?? 0) >= rhythmAtLeast && f.levelSpreadDB >= rhythmSpreadAtLeastDB
        return allCases.filter { trait in
            switch trait {
            case .lowDrone: return f.lowShare >= lowShare && f.levelSpreadDB <= steadyAtMostDB && !rhythmic
            case .broadbandNoise: return f.flatness >= flatnessAtLeast
            case .pitched: return pitch >= pitchAtLeast || f.chromaTop3 >= chromaAtLeast
            case .rhythmic: return rhythmic
            case .speechLike:
                guard let stability = f.chromaStability, let strength = f.pitchStrength else { return false }
                return f.syllabicShare >= syllabicAtLeast && f.levelSpreadDB >= speechSpreadAtLeastDB
                    && stability < speechChromaBelow && strength < speechPitchBelow
            }
        }
    }
}

/// 一段原声（一个镜头自带的声音）按 3 秒一窗说成话。
enum SourceSoundDescription {
    static let windowSeconds = 3.0
    /// 太轻的窗不说（RMS < 1e-3，约 −60 dBFS），和研究一样。
    static let quietRMS = 1e-3

    struct Window: Equatable {
        /// 这一窗从第几秒起（相对传进来的这段声音的开头）。
        let start: Double
        let features: SourceSoundFeatures
        let traits: [SourceSoundTrait]
    }

    /// samples：单声道（立体声先取 (L+R)/2），任意采样率。每 3 秒一窗（不满一窗的尾巴不要），各自重采样到 16 kHz 再量：
    /// 一窗一窗地做，整段很长也不会一次占几百 MB（重采样的代价见 `ListeningResample`）。
    static func describe(_ samples: [Float], sampleRate: Double) -> [Window] {
        let length = Int((windowSeconds * sampleRate).rounded())
        guard length > 0 else { return [] }
        let plan = ListeningResample.Plan(inputLength: length, from: sampleRate, to: SourceSoundFeatures.sampleRate)
        return (0..<(samples.count / length)).compactMap { index in
            let window = plan.apply(ListeningResample.doubles(Array(samples[(index * length)..<((index + 1) * length)])))
            guard ListeningLevel.rms(window) >= quietRMS, let features = SourceSoundFeatures.measure(window) else { return nil }
            return Window(start: Double(index) * windowSeconds, features: features, traits: SourceSoundTrait.traits(of: features))
        }
    }
}
