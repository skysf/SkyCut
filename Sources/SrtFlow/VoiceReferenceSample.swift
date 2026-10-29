import AVFoundation
import Foundation
import SrtFlowCore

// MARK: - 克隆用的参考音频
// 管什么：从用户点名的素材截一段、核对有足够声音，写成 16kHz 单声道 WAV 给 /uploads；序列化只有一份。
// 不管什么：读文件的授权、上传、克隆生成。

enum VoiceReferenceSample {
    static func file(from source: URL, start: Double, seconds: Double, folder: URL) async throws -> URL {
        let caf = try await AudioWindowReader.extract(assetURL: source, range: SourceRange(start: start, end: start + seconds),
                                                      into: folder, isCancelled: { Task.isCancelled })
        let samples = try await MediaReadQueue.run(on: MediaReadQueue.voice) { Result { try read(caf) } }.get()
        guard samples.count >= Int(AudioWindowReader.sampleRate * 3), (samples.map { abs(Int32($0)) }.max() ?? 0) > 300 else {
            throw AIToolError("That part of \(source.lastPathComponent) has no speech to clone. Pick one person talking clearly for at least 5 seconds.")
        }
        let url = folder.appendingPathComponent("reference.wav")
        let data = wavData(samples: samples, sampleRate: Int(AudioWindowReader.sampleRate))
        try await MediaReadQueue.run(on: MediaReadQueue.voice) { Result { try data.write(to: url) } }.get()
        return url
    }

    private static func read(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let data = buffer.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        let bytes = samples.count * 2
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); append32(UInt32(36 + bytes))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: "data".utf8); append32(UInt32(bytes))
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }
}
