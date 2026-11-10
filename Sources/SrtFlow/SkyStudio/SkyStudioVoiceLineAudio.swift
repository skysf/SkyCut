import AVFoundation
import Foundation

// MARK: - 一句配音的几片声音接成一条
//
// 管什么：一句太长、拆成几批读时（SkyStudioVoiceBatch），几片按原来的顺序接回一句。几片的采样率可以不一样 —— 一片是默认模型读的、
// 另一片在服务器上换了备用：Gemini 回 24 kHz 的 WAV、Eleven 回 44.1 kHz 的 MP3（几批同时交，换备用只管得到还没交的批）。
// 不一样就都换到**高的那个**再接（不丢任何一片的高频），时长不变，所以词的时间（秒）不用动。
// 2026-11-10 之前采样率不一样直接报错，两批的钱都花了、怎么恢复都接不起来
// （docs/bugfixes/2026-11-10-long-line-halves-with-different-sample-rates.md）。
// 换采样率是一口气算完的活（几十毫秒），调用方放在 MediaReadQueue.voice 上（SkyStudioVoiceRender）。
// 不管什么：解码、切句、写文件；两片听起来是不是同一个声音（那是 line_models / voice.note 的事）。

struct SkyStudioVoiceLineAudio: Sendable {
    private(set) var samples: [Float] = []
    private(set) var sampleRate: Double = 0

    var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    /// 接上下一片（`rate` 是这一片自己的采样率）；回这一片在整句里从第几秒开始。
    mutating func append(_ piece: [Float], sampleRate rate: Double) throws -> Double {
        guard rate > 0 else { throw AIToolError("Sky Studio's voice file could not be decoded.") }
        if sampleRate == 0 { sampleRate = rate }
        var piece = piece
        if abs(rate - sampleRate) > 0.01 {
            if rate > sampleRate {
                samples = try Self.resampled(samples, from: sampleRate, to: rate)
                sampleRate = rate
            } else {
                piece = try Self.resampled(piece, from: rate, to: sampleRate)
            }
        }
        let offset = duration
        samples.append(contentsOf: piece)
        return offset
    }

    /// 单声道的采样换一个采样率：出来的帧数正好是「原来的时长 × 新采样率」（差的一两帧补零 / 去掉），开头对着开头。
    static func resampled(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        guard from > 0, to > 0 else { throw AIToolError("Sky Studio's voice file could not be decoded.") }
        guard !samples.isEmpty, abs(from - to) > 0.01 else { return samples }
        guard samples.count <= Int(UInt32.max),
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = source.floatChannelData else {
            throw AIToolError("SkyCut could not match the sample rates of this line's parts.")
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { target[0].update(from: $0.baseAddress!, count: samples.count) }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let expected = Int((Double(samples.count) * to / from).rounded())
        var result: [Float] = []
        result.reserveCapacity(expected + 64)
        // 拉式喂：整段只交一次，之后说到头了（流式转换器不能推式喂，docs/bugfixes/2026-10-01-resampler-reset-every-chunk.md）。
        var fed = false
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16_384) else {
                throw AIToolError("SkyCut could not match the sample rates of this line's parts.")
            }
            var failure: NSError?
            let status = converter.convert(to: chunk, error: &failure) { _, state in
                if fed { state.pointee = .endOfStream; return nil }
                fed = true
                state.pointee = .haveData
                return source
            }
            if status == .error {
                throw AIToolError("SkyCut could not match the sample rates of this line's parts"
                    + (failure.map { " (\($0.localizedDescription))." } ?? "."))
            }
            if chunk.frameLength > 0, let data = chunk.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(chunk.frameLength)))
            }
            if status != .haveData || chunk.frameLength == 0 { break }
        }
        if result.count > expected { result.removeLast(result.count - expected) }
        if result.count < expected { result.append(contentsOf: [Float](repeating: 0, count: expected - result.count)) }
        return result
    }
}
