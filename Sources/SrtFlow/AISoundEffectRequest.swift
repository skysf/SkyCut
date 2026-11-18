import Foundation
import SrtFlowMCPKit

// MARK: - add_clips 里的 sound_effect 条目（纯值）
//
// 管什么：把 clips[i] 里的 `sound_effect` 对象读成合成器的参数（预设名对着词表、范围检查）、`hit_at` 和段的默认音量；
// 落点怎么算开头（start = hit_at − 声音里的落点；算出来在 0 之前就从声音中间开始放、源内偏移补上，落点照样压在 hit_at 上）。
// 不管什么：渲染和写文件（AISoundEffectTool）、放上时间线（AITimelineTools.addClips → AITimelineEdits.place）。

struct AISoundEffectRequest: Equatable {
    var parameters: SoundEffectParameters
    /// 时间线上落点（最响那一刻）要压在哪一秒；nil = 用 start，都没给就是播放头。
    var hitAt: Double?
    /// 段的音量（dB）。默认 −8：文件是 −1 dBFS / −9 LUFS 的，原样放会盖过人声。
    var volumeDB: Double

    static let defaultVolumeDB = SoundEffectClipGain.defaultDB

    /// clips[i] 里没有 sound_effect 就 nil。
    static func parse(_ entry: AIToolArguments, index: Int) throws -> AISoundEffectRequest? {
        guard let raw = entry.raw["sound_effect"], !raw.isNull else { return nil }
        guard case .object = raw else { throw AIToolError("clips[\(index)].sound_effect must be an object with a preset.") }
        let object = AIToolArguments(raw)
        guard let name = try object.choice("preset", from: MCPVocabulary.soundEffectPresets), let preset = SoundEffectPreset(rawValue: name) else {
            throw AIToolError("clips[\(index)].sound_effect.preset is required: one of \(MCPVocabulary.soundEffectPresets.joined(separator: ", ")).")
        }
        let parameters = SoundEffectParameters(
            preset: preset, duration: try object.double("duration"), pitch: try object.double("pitch") ?? 1,
            brightness: try object.double("brightness") ?? 0.5, size: try object.double("size"), variation: try object.int("variation") ?? 0
        )
        if let problem = parameters.problem { throw AIToolError("clips[\(index)].sound_effect: \(problem)") }
        return AISoundEffectRequest(
            parameters: parameters, hitAt: try entry.double("hit_at"), volumeDB: try object.double("volume_db") ?? defaultVolumeDB
        )
    }

    /// 开头放在哪：落点减去声音里的落点；在 0 之前就从声音中间开始（源内偏移 = 差的那一截），落点照样压在 hit_at 上。
    /// The rule has one copy, AIClipHit.placement (add_clips lands files and library music by their hit too, MCP-43).
    static func placement(hitAt requested: Double, renderedHit: Double) -> (start: Double, sourceIn: Double) {
        AIClipHit.placement(hitAt: requested, hit: renderedHit, sourceIn: 0)
    }

    /// Until when a made sound is heard (file seconds): the end of the last window that is not silent by listen's rule (the same
    /// ~43 ms windows, louder than its default −45 dB silence floor) at the clip's volume. The file runs on past it: the preset's
    /// tail past duration (an impact of duration 1 is a 2.7 s clip, heard for 1.2 s at -8 dB) and the silence a short sound is padded
    /// with. The reply reports it as audible_duration next to the clip's start / end (MCP-8,
    /// docs/bugfixes/2026-11-17-new-audio-effects-land-on-voice-and-music-tracks.md).
    static func audibleEnd(_ audio: SFXBuffer, volumeDB: Double) -> Double {
        let gain = AudioGain.linear(fromDecibels: AudioGain.clampedDecibels(volumeDB))
        let window = AIAudioLevels.bucketsPerWindow * WaveformPowerBuilder.bucket
        var end = 0
        var start = 0
        while start < audio.count {
            let stop = min(audio.count, start + window)
            var power = 0.0
            for i in start..<stop { power += (audio.left[i] * audio.left[i] + audio.right[i] * audio.right[i]) / 2 }
            let level = AudioGain.decibels(fromLinear: (power / Double(stop - start)).squareRoot() * gain)
            if level >= AIAudioLevels.defaultSilenceDB { end = stop }
            start = stop
        }
        return Double(end) / SFX.sampleRate
    }
}
