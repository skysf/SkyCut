import AVFoundation
import Foundation
import SrtFlowCore

// 现造的信号（48 kHz、32 位浮点 WAV，逐采样精确，不过编码器）和用它们搭的时间线。

/// 写一个 WAV：`sample(帧, 声道)` 给出每个采样。
func writeWAV(_ name: String, channels: Int = 2, seconds: Double, _ sample: (Int, Int) -> Float) -> URL {
    let url = root.appendingPathComponent(name)
    let frames = Int((seconds * 48_000).rounded())
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels))!
    let file = try! AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = 48_000
    var written = 0
    while written < frames {
        let count = min(chunk, frames - written)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<channels {
            let data = buffer.floatChannelData![channel]
            for index in 0..<count { data[index] = sample(written + index, channel) }
        }
        try! file.write(from: buffer)
        written += count
    }
    return url
}

/// 恒定振幅的正弦。
func sineWAV(_ name: String, frequency: Double, amplitude: Float, seconds: Double, channels: Int = 2) -> URL {
    writeWAV(name, channels: channels, seconds: seconds) { frame, _ in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / 48_000))
    }
}

/// 可重复的「噪声」（线性同余），均匀分布在 ±amplitude。
struct CheckNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ amplitude: Float) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
    }
}

/// 一段纯音频的片段。
func audioClip(_ url: URL, at start: Double, duration: Double, sourceStart: Double = 0, volume: Double = 1) -> EditClip {
    var clip = EditClip(
        sourceURL: url, isAudioOnly: true, sourceStart: sourceStart, sourceDuration: duration,
        timelineStart: start, audioAssetDuration: sourceStart + duration
    )
    clip.volume = volume
    return clip
}

/// 主轨 / 上层轨上的「有画面」的段：引擎只读它的声音，画面的 info 让它被当成有声音的视频段。
func pictureClip(_ url: URL, at start: Double, duration: Double) -> EditClip {
    let info = MediaInfo(
        duration: duration, displaySize: CGSize(width: 320, height: 180), frameRate: 24,
        videoCodec: "h264", audioCodec: "pcm", hasAudio: true, audioCanCopyToMP4: false, fileBytes: 1
    )
    return EditClip(sourceURL: url, sourceDuration: duration, timelineStart: start, info: info)
}

func baseState(fps: ProjectFrameRate = .fps24) -> TimelineState {
    var state = TimelineState()
    state.frameRate = fps
    state.canvasRatio = .wide16x9
    return state
}
