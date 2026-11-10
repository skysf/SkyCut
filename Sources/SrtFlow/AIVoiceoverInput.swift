import Foundation

// MARK: - 一次配旁白的输入快照
// 管什么：调用刚到时核对全部参数、分出这次要不要先问 Sky Studio（`ask`）还是直接用本机的声音、落点；云端任务等几分钟时不再读后来变掉的
// 文件夹 / 选项。认 Sky Studio 的声音要先读 `/models`（SkyStudioVoiceoverStart），这里只按字分类（SkyStudioVoicePick.ask）。
// 不管什么：生成、报价、入轨。本机挑哪个声音由 AIVoiceChoice 负责。
// 2026-11-10（声音 PR 3）去掉了 clone_from：克隆一律先进声音库（决定第七节第 8 条）；声音库的声音（`voice_…`）是声音 PR 6：
// 要 Sky Studio 的 Key、不退本机，`skip_one_time` / `confirm_token` 管它的一次性费用（SkyStudioVoiceOneTimeStep）。

struct VoiceoverLine {
    var text: String
    var start: Double?
}

struct AIVoiceoverInput {
    let lines: [VoiceoverLine]
    let speed: Double
    let language: String
    let requestedVoice: String?
    /// 要 Sky Studio 的哪个声音（还没读目录）；nil = 本机的声音，或者恢复出来的云端任务（声音已经定了，在 `choice` 里）。
    var ask: SkyStudioVoiceAsk?
    /// add_voiceover 的 `model`：nil = auto，否则是点名的模型 id。只对 Sky Studio 的声音有用。
    let model: String?
    var choice: AIVoiceChoice
    let target: TrackDropTarget
    let subtitles: Bool
    let maxLines: Int?
    let generation: Int
    let folder: URL
    /// 声音库的声音：用户不肯花一次性费用（建 MiniMax 版）时，照报价里不花钱的那个读（SkyCut 声音方案 4.2、4.5）。
    var skipOneTime = false
    /// 一次性费用的确认码（请求批准模式；读别处的恢复文件那一问也用它，在别处收）。
    var confirmToken: String?

    /// 本机转写这段旁白用哪种语言：`language` 只留了 `zh`，繁体稿要 `zh-Hant`（不然交给简体模型，AITextLanguage.speechLanguage）。
    var speechLanguage: String { AITextLanguage.speechLanguage(language, texts: lines.map(\.text)) }

    @MainActor
    static func read(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIVoiceoverInput {
        guard let values = try args.array("lines"), !values.isEmpty, values.count <= 50 else {
            throw AIToolError("lines is required: give 1–50 voiceover lines.")
        }
        let lines = try values.enumerated().map { index, value in
            let entry = AIToolArguments(value)
            let text = try entry.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 1_000 else { throw AIToolError("lines[\(index)]: give 1–1000 characters.") }
            return VoiceoverLine(text: text, start: try entry.double("start").map { max(0, $0) })
        }
        let language = AITextLanguage.dominant(in: lines.map(\.text)).map(AIVoiceChoice.baseLanguage) ?? "en"
        let requested = try args.string("voice").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let model = try args.string("model").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0.lowercased() == SkyStudioVoiceRequests.autoModel ? nil : $0 }
        let ask = SkyStudioVoicePick.ask(requested)
        let hasKey = SkyStudioAccount.shared.hasKey
        var cloud: SkyStudioVoiceAsk?
        var choice: AIVoiceChoice
        switch ask {
        case .none:
            // Kokoro 的音色名：本机，照点名。
            choice = try local(requested, language: language)
        case .name(let name)? where !hasKey:
            // 没有 Sky Studio：不带前缀的名字只能是这台 Mac 的声音（找不到就报错，和以前一样）。
            choice = try local(name, language: language)
        case .library(let id)? where !hasKey:
            // 声音库的声音没有本机退档（4.3）。
            throw AIToolError("\(id) is a voice from the user's Sky Studio voice library, which needs a Sky Studio key "
                + "(SkyCut Settings > Sky Studio). Nothing was charged.")
        case let wanted? where hasKey:
            cloud = wanted
            choice = AIVoiceChoice(engine: .skyStudio(voice: ""))
        case let wanted?:
            choice = try localChoice(for: wanted, catalog: nil, language: language)
            if case .preset = wanted { choice.note = joined(choice.note, noKeyNote) }
            if case .eleven = wanted { choice.note = joined(choice.note, noKeyNote) }
        }
        if let model, cloud == nil {
            choice.note = joined(choice.note, "model \(model) only applies to Sky Studio voices, so it was not used.")
        }
        let skipOneTime = try args.bool("skip_one_time") ?? false
        if skipOneTime, cloud?.isLibrary != true {
            choice.note = joined(choice.note, "skip_one_time only applies to voice_… voices from the user's library, so it was not used.")
        }
        let target = try args.string("track").map { try AITrackName.target($0, in: project.state) } ?? .newAudioBottom
        switch target {
        case .audio, .newAudioBottom: break
        default: throw AIToolError("A voiceover goes on an audio track (A1, A2… or new_audio).")
        }
        let subtitles = try args.bool("subtitles") ?? false
        let maxLines = try AISubtitleLines.parse(args)
        if maxLines != nil, !subtitles { throw AIToolError("\(AISubtitleLines.key) only applies with subtitles=true.") }
        return AIVoiceoverInput(
            lines: lines, speed: min(max(try args.double("speed") ?? 1, 0.5), 2), language: language, requestedVoice: requested,
            ask: cloud, model: model, choice: choice, target: target, subtitles: subtitles, maxLines: maxLines,
            generation: project.documentGeneration, folder: AIWorkspace.shared.outputFolder(.voiceovers, project: project),
            skipOneTime: skipOneTime && cloud?.isLibrary == true, confirmToken: try args.string("confirm_token")
        )
    }

    static let noKeyNote = "The Sky Studio voice was not used because no Sky Studio key is configured."

    /// Sky Studio 这次用不了（读不到 Key / 目录、报价时服务不答）：在付费请求之前当场退本机（决定第七节第 4 条），
    /// 角色照旧用它本机的声音、预设按它在这种语言里的性别挑角色（4.3），`note` 说为什么。
    @MainActor
    func localFallback(_ note: String, catalog: SkyStudioVoiceCatalog? = nil) throws -> AIVoiceoverInput {
        guard let ask else { throw AIToolError(note) }
        var copy = self
        copy.choice = try Self.localChoice(for: ask, catalog: catalog, language: language)
        copy.choice.note = Self.joined(Self.joined(copy.choice.note, note), choice.note)
        copy.ask = nil
        return copy
    }

    /// 这台 Mac 装了这个名字的声音：用它（Sky Studio 的目录里没有这个预设时，不带前缀的名字再按本机找）。
    @MainActor
    func usingLocal(named name: String) throws -> AIVoiceoverInput {
        var copy = self
        copy.choice = try Self.local(name, language: language)
        copy.ask = nil
        return copy
    }

    @MainActor
    private static func localChoice(for ask: SkyStudioVoiceAsk, catalog: SkyStudioVoiceCatalog?, language: String) throws -> AIVoiceChoice {
        if case .name(let name) = ask, AIVoiceChoice.isInstalled(name, in: AISpeechSynthesis.installedVoices()) {
            return try local(name, language: language)
        }
        return try local(SkyStudioVoicePick.localRole(for: ask, catalog: catalog, language: language)?.name, language: language)
    }

    @MainActor
    private static func local(_ requested: String?, language: String) throws -> AIVoiceChoice {
        let kokoro = KokoroVoicePack.shared.isInstalled ? KokoroVoiceSpeech.voiceNames(in: KokoroVoicePack.directory) : nil
        return try AIVoiceChoice.choose(requested, textLanguage: language, kokoroVoices: kokoro, installed: AISpeechSynthesis.installedVoices())
    }

    private static func joined(_ first: String?, _ second: String?) -> String? {
        let parts = [first, second].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
