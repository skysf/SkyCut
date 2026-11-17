import AVFoundation
import Foundation
import SoundAnalysis

// MARK: - macOS's sound classifier: every label's own score, per window (blocking)
//
// What: one channel of samples → SoundAnalysis's built-in classifier (`SNClassifySoundRequest(.version1)`, on this Mac, no
// download) over `window`-second analysis windows without overlap → for each window its start and the labels with their own
// confidences. The classifier scores each of its ~300 labels on its own (they don't add up to 1), so "music 0.62, wind 0.21"
// says more than the top label: it called the South Pole shot's low drone and our wind bed "music" (up to 0.97, MCP-44), and
// the runner-up is part of the description. Words, never a verdict: listen reports these next to SkyCut's own measures.
// Why a temp-free stream analyzer: the samples are already in memory (AIListenSourceSound's bounded read).
// Not here: reading the sound, SkyCut's traits (SourceSoundDescription), words (the speech recogniser), the report.
// Blocking (the analyzer works on its own queue and `completeAnalysis` waits for it): only on a MediaReadQueue queue.

enum SoundLabelScores {
    struct Label: Sendable, Equatable {
        let name: String
        let score: Double
    }

    struct Window: Sendable, Equatable {
        /// Seconds from the first sample.
        let start: Double
        let duration: Double
        /// Every label with a score, strongest first.
        let labels: [Label]
    }

    struct ClassifierError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    /// The windows of `samples` (one channel at `sampleRate`), classified. Only whole windows come back.
    static func classify(_ samples: [Float], sampleRate: Double, window seconds: Double = 3) throws -> [Window] {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw ClassifierError(detail: "SkyCut could not describe this sound's format to the sound classifier.")
        }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(sampleRate.rounded()))
        request.overlapFactor = 0
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = Observer()
        try analyzer.add(request, withObserver: observer)
        let chunk = 16_384
        var position = 0
        while position < samples.count {
            let count = min(chunk, samples.count - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw ClassifierError(detail: "SkyCut could not hand this sound to the sound classifier.")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + position, count: count)
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
            position += count
        }
        analyzer.completeAnalysis()
        if let failure = observer.failure { throw ClassifierError(detail: "The sound classifier failed: \(failure.localizedDescription)") }
        return observer.windows.sorted { $0.start < $1.start }
    }

    /// Collects the classifier's results (they arrive on its own queue).
    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [Window] = []
        private var error: Error?

        var windows: [Window] { lock.withLock { collected } }
        var failure: Error? { lock.withLock { error } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let labels = result.classifications.map { Label(name: $0.identifier, score: $0.confidence) }.sorted { $0.score > $1.score }
            let window = Window(start: result.timeRange.start.seconds, duration: result.timeRange.duration.seconds, labels: labels)
            lock.withLock { collected.append(window) }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.withLock { self.error = error }
        }
    }
}
