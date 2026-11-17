import Foundation
import SrtFlowCore

// MARK: - listen describe=true: does the on-device speech recogniser find words in this sound?
//
// What: the stretch's sound as a 16 kHz window file (QueuedAudioWindow, the reader for callers outside subtitle generation,
// on MediaReadQueue.analysis), transcribed with an already installed speech model (`SpeechTranscriptionService.screeningLocale`:
// the system's first installed language — only "is someone speaking", not which language), returning each word's start in
// source seconds and its text. Never downloads a model (no model, or macOS before 26: says why it did not check), never
// touches a transcript cache (listen is read-only).
// Not here: the window reading's rules (QueuedAudioWindow), transcription itself (SpeechTranscriptionService), the report.

enum AIListenSourceWords {
    static func words(_ url: URL, from: Double, to: Double) async -> AIListenSourceReport.Words {
        guard #available(macOS 26.0, *) else { return .notChecked("this Mac's speech recogniser needs macOS 26") }
        guard SpeechTranscriptionService.isAvailable else { return .notChecked("speech recognition is not available on this Mac") }
        guard let locale = await SpeechTranscriptionService.screeningLocale() else {
            return .notChecked("no speech model is installed on this Mac (transcribe installs one)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkyCut-listen-words-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SpeechTranscriptionService()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let window = try await QueuedAudioWindow.extract(
                assetURL: url, range: SourceRange(start: from, end: to), into: directory, on: MediaReadQueue.analysis
            )
            // Reserve first and recheck availability without an installation fallback: the model may have been removed
            // since screeningLocale. Every successful reservation is returned on both transcription paths.
            try await service.reserveInstalledModel(locale: locale)
            let found: [TimedWord]
            do {
                try Task.checkCancellation()
                found = try await service.transcribe(fileURL: window, locale: locale, sourceOffset: from)
            } catch {
                await service.releaseModel(locale: locale)
                throw error
            }
            await service.releaseModel(locale: locale)
            return .found(found.map { AIListenSourceReport.Word(start: $0.start, text: $0.text) })
        } catch {
            return .notChecked("the speech recogniser failed (\(error.localizedDescription))")
        }
    }
}
