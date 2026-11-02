import AVFoundation
import Foundation

// 检查任务的混音和短试听；只复用正式混音，不另建增益/场景算法。所有同步文件操作在媒体队列上。
enum AIInspectionAudio {
    static func mix(_ state: TimelineState, into folder: URL, cancellation: ExportCancellationToken) async throws -> URL? {
        let raw = folder.appendingPathComponent("mix.f32")
        let result = try await ExportAudioMixdown.render(state: state, duration: state.duration, to: raw, cancellation: cancellation)
        guard case .written = result else { return nil }
        let wave = folder.appendingPathComponent("mix.wav")
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try wrap(raw, as: wave, cancellation: cancellation) }
        }.get()
        return wave
    }

    /// 给已有的 f32 数据加标准 IEEE-float WAV 容器；不改样本、不重编码。
    private static func wrap(_ raw: URL, as wave: URL, cancellation: ExportCancellationToken) throws {
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close(); try? FileManager.default.removeItem(at: raw) }
        let size = try input.seekToEnd()
        guard size <= UInt32.max - 36 else { throw AIToolError("Inspection audio exceeds the WAV size limit; inspect a shorter project.") }
        try input.seek(toOffset: 0)
        var header = Data()
        func chars(_ value: String) { header.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        chars("RIFF"); long(UInt32(size) + 36); chars("WAVEfmt "); long(16)
        word(3); word(2); long(48_000); long(48_000 * 8); word(8); word(32); chars("data"); long(UInt32(size))
        try header.write(to: wave, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: wave)
        defer { try? output.close() }
        try output.seekToEnd()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            if cancellation.isCancelled { throw CancellationError() }
            try output.write(contentsOf: chunk)
        }
    }

    /// 原生按位置解码最多 3 秒，保住声道、音量，不做旁白的响度归一。
    static func audition(_ input: URL, from: Double, to: Double, output: URL) async throws {
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try writeAudition(input, from: from, to: to, output: output) }
        }.get()
    }

    private static func writeAudition(_ input: URL, from: Double, to: Double, output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let start = min(file.length, AVAudioFramePosition((max(0, from) * format.sampleRate).rounded()))
        let count = min(file.length - start, AVAudioFramePosition((min(3, to - from) * format.sampleRate).rounded()))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw AIToolError("Could not allocate the short audition.")
        }
        file.framePosition = start
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard buffer.frameLength == count else { throw AIToolError("The short audition was incomplete.") }
        let target = try AVAudioFile(forWriting: output, settings: format.settings)
        try target.write(from: buffer)
    }
}
