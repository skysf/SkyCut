import Foundation
import SrtFlowCore

// MARK: - 这段参考录音说的是哪种语言（界面上预选，用户可改）
//
// 管什么（SkyCut 声音方案 4.6、5.3）：新建声音对话框里「语言」那一行先替用户选好：macOS 26 上用生成字幕那套两段式检测
// （SpokenLanguageProbe：只在已装的语言里裁决，不下载模型），探针是做好的参考录音的前 20 秒（它本来就是从开口处起、人声最密的一段）。
// 检测不出来、一个转写模型都没装、macOS 15：回 nil，界面上那一行空着、要用户手选（不许猜一个：语言记错了，服务器选模型就跟着错）。
// 能选的语言是一份常用的名单；检测出名单外的也照样能用（对话框把它加进去）。
// 不管什么：参考录音怎么做（VoiceReferenceSample）、语言的名字怎么写（VoiceLibraryText）。

@MainActor
enum VoiceSampleLanguage {
    /// 对话框里能选的语言（ISO 639-1），中文、英文在前。
    static let choices = ["zh", "en", "ja", "ko", "es", "fr", "de", "pt", "it", "ru", "ar", "hi", "id", "vi", "th", "tr", "nl", "pl"]

    /// `sample`：做好的参考录音（WAV），`seconds`：它多长。检测不出来是 nil。
    static func detect(sample: URL, seconds: Double) async -> String? {
        guard #available(macOS 26.0, *), SpeechTranscriptionService.isAvailable else { return nil }
        let candidates = await SpokenLanguageProbe.candidates(metadataTag: nil)
        guard !candidates.isEmpty, !Task.isCancelled else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SkyCut-voice-language-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let range = SourceRange(start: 0, end: min(seconds, TranscriptHarvester.detectionProbeSeconds))
            let stop = StopFlag()
            return try await withTaskCancellationHandler {
                let probe = try await AudioWindowReader.extract(assetURL: sample, range: range, into: folder, isCancelled: { stop.stopped })
                let winner = try await SpokenLanguageProbe.verdict(
                    probeFile: probe, probeStart: 0, candidates: candidates, service: SpeechTranscriptionService(),
                    isCancelled: { stop.stopped })
                return winner.flatMap(code)
            } onCancel: { stop.stop() }
        } catch {
            return nil
        }
    }

    /// `zh_CN` → `zh`，`en_US` → `en`。
    static func code(_ locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier.lowercased(),
              (try? SkyStudioVoiceNaming.checkedLanguage(code)) != nil else { return nil }
        return code
    }
}

/// 取消只置一个标记（读采样的循环自己看它）。
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func stop() { lock.lock(); flag = true; lock.unlock() }
}
