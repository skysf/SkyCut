import AVFoundation
import Foundation
import SrtFlowCore

// MARK: - 云端配音回到本机之后的音频适配
// 管什么：解码成单声道 PCM、本机转写定位克隆的句界、统一经 AIAudioFileWriter 写每句；阻塞读写都走 MediaReadQueue.voice。
// 不管什么：HTTP、积分、入轨；批次怎么装 / 句界怎么算由纯值类型管。

enum SkyStudioVoiceAudio {
    struct PCM: Sendable {
        let samples: [Float]
        let sampleRate: Double
        var duration: Double { Double(samples.count) / sampleRate }
    }

    static func decode(_ url: URL) async throws -> PCM {
        try await MediaReadQueue.run(on: MediaReadQueue.voice) { Result { try decodeFile(url) } }.get()
    }

    private static func decodeFile(_ url: URL) throws -> PCM {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AIToolError("Sky Studio's voice file was empty or could not be decoded.")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData, format.sampleRate > 0 else {
            throw AIToolError("Sky Studio's voice file could not be decoded.")
        }
        let count = max(1, Int(format.channelCount))
        var samples = [Float](repeating: 0, count: Int(buffer.frameLength))
        for channel in 0..<count {
            for index in samples.indices { samples[index] += channels[channel][index] / Float(count) }
        }
        return PCM(samples: samples, sampleRate: format.sampleRate)
    }

    static func write(_ pcm: PCM, words: [TimedWord], to url: URL) async throws -> AISpeechSynthesis.Output {
        let samples = try await MediaReadQueue.run(on: MediaReadQueue.voice) {
            Result { try AIAudioFileWriter.writeVoiceover(pcm.samples, sampleRate: pcm.sampleRate, to: url) }
        }.get()
        let duration = Double(samples.count) / pcm.sampleRate
        return AISpeechSynthesis.Output(url: url, duration: duration, words: words.filter { $0.start < duration }.map {
            TimedWord(text: $0.text, start: max(0, $0.start), end: min(duration, $0.end), confidence: $0.confidence)
        })
    }

    /// 多句克隆需要已装好的转写模型；先查这一点，再交付费任务。这里不偷偷下载模型、不弹系统框。
    static func splitLocale(language: String) async throws -> Locale {
        guard #available(macOS 26.0, *), SpeechTranscriptionService.isAvailable,
              let locale = await SpeechTranscriptionService.matchedLocale(for: language),
              await SpeechTranscriptionService.installedLocales().contains(where: { $0.identifier == locale.identifier }) else {
            throw AIToolError("Splitting several cloned lines needs this Mac's speech transcription model for \(language) (macOS 26 or later). "
                + "Run generate_subtitles on the reference clip first to prepare that language, or give the whole narration as one line. Nothing was charged.")
        }
        return locale
    }

    static func transcribe(_ url: URL, locale: Locale) async throws -> [TimedWord] {
        guard #available(macOS 26.0, *) else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlow-voice-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pcm = try await decode(url)
        let caf = try await AudioWindowReader.extract(assetURL: url, range: SourceRange(start: 0, end: pcm.duration),
                                                      into: folder, isCancelled: { Task.isCancelled })
        let service = SpeechTranscriptionService()
        try await service.ensureModel(locale: locale) { _ in }
        do {
            let words = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await service.transcribe(fileURL: caf, locale: locale, sourceOffset: 0)
            } onCancel: {
                service.cancelCurrent()
            }
            await service.releaseModel(locale: locale)
            return words
        } catch {
            await service.releaseModel(locale: locale)
            throw error
        }
    }
}
