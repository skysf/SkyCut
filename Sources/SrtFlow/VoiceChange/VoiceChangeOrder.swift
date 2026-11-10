import Foundation
import SrtFlowMCPKit

// MARK: - 一次变声怎么下单：AI 的 change_voice 和片段右键的面板共用的那几步
//
// 管什么（SkyCut 声音方案 4.8）：
// - 目标声音是谁（VoiceChangeTarget）：声音库的 `voice_…` 或预设 `gemini:<名字>`，以及它有哪几种语言的参考（声音库看有录音的语言，
//   预设看有样音的语言）。
// - 一次最长多少秒：只读 `/models` 的 `limits.max_source_seconds`（现在 5 分钟），SkyCut 不写死。
// - **用哪种语言的参考**（`params.target_language`）：知道这段说的是什么语言、目标声音又有这种语言的参考时才带；不知道、或者没有这种
//   参考就不带，照服务器的默认（中文参考，没有中文就随便一段）。实测都是同语言参考，拿中文参考去变英文片段没测过。
// - 这段说的是什么语言：调用方给了就用它（AI 的 `language`）；否则本机检测（和新建声音的对话框、manage_voices 同一份：
//   `SkyStudioVoiceServices.detectLanguage`，只在已装的语言里裁决、不下载模型，收费之前做），等太久、检测不出来、macOS 15 都算不知道。
// - 报价用的那一份（kind `voice_convert`、`model: auto`、`params.target_voice`、`params.source.seconds`）；钱的事过了之后拿记上账的
//   那一笔起任务（VoiceChangeJob）。花钱只判每日硬预算：不是一次性费用，两种权限模式都不问；面板上的报价就是确认。
// 不管什么：截声音（VoiceChangeSource）、任务怎么跑和落地（VoiceChangeJob / VoiceChangeLanding）、参数怎么读（VoiceChangeTool）、界面。

/// 变声的目标声音。
struct VoiceChangeTarget: Equatable, Sendable {
    /// 交给 `params.target_voice` 的 id：`voice_…` 或 `gemini:<名字>`。
    let id: String
    /// 给人看的名字（文件名、提示条、任务浮层）。
    let name: String
    /// 这个声音有哪几种语言的参考（ISO 639-1）。
    let languages: Set<String>

    var isLibraryVoice: Bool { SkyStudioVoice.isVoiceID(id) }

    init(id: String, name: String, languages: Set<String>) {
        self.id = id
        self.name = name
        self.languages = languages
    }

    /// 声音库里的声音：有录音（或设计样音）的那几种语言。
    init(voice: SkyStudioVoice) {
        self.init(id: voice.id, name: voice.name, languages: Set(voice.languages.map(\.language)))
    }

    /// 预设：有样音的那几种语言（预设当变声目标用的就是它的样音）。
    init(preset: SkyStudioVoicePreset) {
        self.init(id: preset.id, name: preset.name, languages: Set(preset.languages.filter { $0.value.sampleURL != nil }.keys))
    }
}

/// 变声要用的外部适配：生产默认是真的 Sky Studio、本机检测、全 App 一份的槽；回归换成假的。
@MainActor
struct VoiceChangeServices {
    var voice = SkyStudioVoiceServices()
    /// 这段（截好的 WAV、多长）说的是什么语言；检测不出来是 nil。和新建声音的对话框、manage_voices 同一份
    /// （`SkyStudioVoiceServices.detectLanguage`），这里不另调一遍识别。
    var detectLanguage: @MainActor (URL, Double) async -> String? {
        get { voice.detectLanguage }
        set { voice.detectLanguage = newValue }
    }
    /// 本机检测最多等多久（秒）：AI 的一次调用只等得起一分钟。
    var detectionTimeout: Double = 20
    /// 两个文件放哪个文件夹之外的退路（原素材的文件夹写不进去时）：nil = 工程的家、下载。
    var fallbackFolders: [URL]?
    /// 截声音、下载用的临时文件夹。
    var workFolder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlowVoiceChange", isDirectory: true)

    var api: SkyStudioAPI { voice.api }
}

@MainActor
enum VoiceChangeOrder {
    /// 一次最长多少秒（`/models` 的 `voice_convert` 几个模型里最小的那个）；读不到是 nil（本机不拦，服务器照样会拦）。
    nonisolated static func maxSourceSeconds(in catalog: SkyStudioCatalog) -> Double? {
        catalog.models(kind: SkyStudioVoiceKind.convert).compactMap { $0.limit("max_source_seconds") }.filter { $0 > 0 }.min()
    }

    /// 带不带 `params.target_language`：知道这段的语言、目标声音又有这种语言的参考才带。
    nonisolated static func targetLanguage(spoken: String?, target: VoiceChangeTarget) -> String? {
        guard let spoken, target.languages.contains(spoken) else { return nil }
        return spoken
    }

    /// 报价用的那一份（还没传，`inputs` 空着）。拼不出来抛 `SkyStudioVoiceRequestProblem`：一分不花、不碰服务器。
    nonisolated static func draft(target: VoiceChangeTarget, seconds: Double, spoken: String?) throws -> SkyStudioJobRequest {
        try SkyStudioVoiceRequests.convert(targetVoice: target.id, sourceSeconds: seconds,
                                           targetLanguage: targetLanguage(spoken: spoken, target: target))
    }

    /// 这段说的是什么语言：给了就用（核对成 ISO 639-1），没给就本机检测、最多等 `detectionTimeout` 秒。
    static func spokenLanguage(given: String?, source: VoiceChangeSource.Prepared, services: VoiceChangeServices) async throws -> String? {
        if let given {
            do { return try SkyStudioVoiceNaming.checkedLanguage(given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message) }
        }
        let detect = services.detectLanguage
        let seconds = services.detectionTimeout
        let found = Task { @MainActor in await detect(source.url, source.seconds) }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            found.cancel()
        }
        defer { timer.cancel() }
        let language = await withTaskCancellationHandler { await found.value } onCancel: { found.cancel() }
        try Task.checkCancellation()
        return found.isCancelled ? nil : language
    }

    /// 记上账之后起任务：`max_credits` 就是报价的那个数。`notifies`：做完在工程的提示条上说一句（面板起的；AI 起的由 AI 转告）。
    static func start(clip: EditClip, source: VoiceChangeSource.Prepared, draft: SkyStudioJobRequest, quote: SkyStudioQuote,
                      target: VoiceChangeTarget, key: String, reservation: SkyStudioJobGate.Reservation, project: VideoEditProject,
                      notifies: Bool, services: VoiceChangeServices) -> AIJobs.Job {
        let origin = VoiceChangeLanding.Origin(clipID: clip.id, sourceURL: source.sourceURL, sourceStart: source.sourceStart,
                                               sourceDuration: source.seconds)
        return VoiceChangeJob(
            origin: origin, source: source, draft: draft, quote: quote, target: target, clipName: clip.name, key: key,
            reservation: reservation, project: project, notifies: notifies, services: services
        ).start()
    }

    /// 两个文件放哪：原素材的文件夹，写不进去退到工程的家、再退到下载（同 upscale）。
    static func fallbackFolders(for project: VideoEditProject, services: VoiceChangeServices) -> [URL] {
        if let given = services.fallbackFolders { return given }
        var folders: [URL] = []
        if let home = project.documentURL?.deletingLastPathComponent() { folders.append(home) }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { folders.append(downloads) }
        return folders
    }
}
