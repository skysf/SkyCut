import Foundation

// MARK: - 这台 Mac 能不能转写配音的语言、装它的转写模型（App 适配）
// 管什么（SkyCut 声音方案第七节）：「本机能转写」= macOS 26 及以上、SpeechTranscriber 能用、支持这种语言（`supportedLocales`），
// 模型没装也算能 —— 在任务里花钱之前**明着**装（状态行写「准备本机转写」），和生成字幕同一个 `ensureModel`；装完就还租约，转写的时候各自再拿。
// 装不上由调用方当「转写不了」（SkyStudioVoiceoverRun）。macOS 15 没有 SpeechTranscriber，什么语言都是「转写不了」。
// 不管什么：转写本身（SkyStudioVoiceAudio.transcribe）、转写得了 / 转写不了之后怎么读（SkyStudioVoiceReading）。

enum SkyStudioVoiceTranscription {
    enum Availability: Equatable, Sendable {
        /// macOS 15、SpeechTranscriber 用不了、或不支持这种语言。
        case unavailable
        case installed(Locale)
        /// 支持、模型还没装（任务里花钱之前装）。
        case downloadable(Locale)

        var transcribes: Bool { self != .unavailable }

        var locale: Locale? {
            switch self {
            case .unavailable: return nil
            case .installed(let locale), .downloadable(let locale): return locale
            }
        }
    }

    /// 报价之前量：只问系统支持哪些、装了哪些，不下载。
    static func availability(language: String) async -> Availability {
        guard #available(macOS 26.0, *), SpeechTranscriptionService.isAvailable,
              let locale = await SpeechTranscriptionService.matchedLocale(for: language) else { return .unavailable }
        let installed = await SpeechTranscriptionService.installedLocales().contains { $0.identifier == locale.identifier }
        return installed ? .installed(locale) : .downloadable(locale)
    }

    /// 本地的活要转写（恢复配音、sync_voiceover，不花钱）：支持就用，转写那一步自己会装模型；不支持说清楚。
    static func locale(for language: String) async throws -> Locale {
        try locale(await availability(language: language), language: language)
    }

    static func locale(_ availability: Availability, language: String) throws -> Locale {
        guard let locale = availability.locale else {
            throw AIToolError("This Mac cannot transcribe \(SkyStudioVoicePick.languageName(language)) speech "
                + "(it needs macOS 26 or later, with that language).")
        }
        return locale
    }

    /// 装这种语言的转写模型（装好了马上回来）；`progress` 报 0…1。任务取消就停下载。装完把租约还掉。
    @MainActor
    static func install(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else { throw AIToolError("This Mac's speech transcription needs macOS 26 or later.") }
        let service = SpeechTranscriptionService()
        let watch = ProgressWatch()
        defer { watch.stop() }
        try await withTaskCancellationHandler {
            try await service.ensureModel(locale: locale) { request in
                watch.start(request) { fraction in Task { @MainActor in progress(fraction) } }
            }
        } onCancel: {
            watch.cancel()
        }
        await service.releaseModel(locale: locale)
        if Task.isCancelled { throw CancellationError() }
    }
}

/// 下载的进度（KVO 在别的线程上回调）、取消时停下载。
private final class ProgressWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func start(_ progress: Progress, report: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.progress = progress
        observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in report(value.fractionCompleted) }
        if cancelled { progress.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        progress?.cancel()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        observation?.invalidate()
        observation = nil
    }
}
