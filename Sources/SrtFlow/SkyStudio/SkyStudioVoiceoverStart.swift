import Foundation
import SrtFlowMCPKit

// MARK: - 云端配旁白：回任务号之前做完的那几步（整段报价挪到这里）
// 管什么（SkyCut 声音方案 4.2 第 1–4 步、第七节）：静默读 Key → 读 `/models`（缓存 10 分钟）→ 认声音（SkyStudioVoicePick）→
// 量这台 Mac 转写不转写得了这种语言（SkyStudioVoiceTranscription，不下载）→ 定怎么读（SkyStudioVoiceReading：合不合批、交哪个 model、
// 字幕时间从哪来）→ 分批 → **整段 `POST /quote` 一次**（`params.batches`，`model` 是 auto、点名的、或为了字幕时间整段点名的 eleven-v4）→
// 核对报价（voice_plan、批数、不要一次性费用）→ 要转写的记下语言、模型没装的交给任务在花钱之前明着装 → 按每批的 credits 整体预留
// （每日硬预算：不够当场回 daily_budget_exceeded，什么都不起）→ 起任务、回 job_id，同时回 voice_plan 和要转告的 voice.note。
// 任务里装不上转写模型（还一分没花）：`withoutTranscription` 按「转写不了」再定一次、再报一次价（下载失败当作不能转写）。
// 为什么挪到回任务号之前：一次性费用要在花钱之前问（声音 PR 6 接上），generate_media 本来就是先报价、过关再起任务；一段旁白只多一个请求。
// **退本机只在付费请求之前**（决定第七节第 4 条）：Key / 目录 / 报价读不到（断网、5xx、Key 不认）就当场换本机的声音；
// 服务器明说这个请求不行（4xx：模型和声音配不上、语言不支持……）原话转给 AI、一分不花、不换声音；额度不够也不换声音（2026-11-01 定）。
// 用户声音库里的声音（`voice_…`，声音 PR 6）读稿是 `voice_clone`，**从不退本机**：Sky Studio 用不了就报错（声音库用不了的那句在
// SkyStudioVoiceLibraryErrors）；报价要一次性费用（建 MiniMax 版）时交给 SkyStudioVoiceOneTimeStep 问 / 跳过 / 起建的任务。
// 不管什么：交、等、下载、切句、落地（SkyStudioVoiceoverRun）；本机的那条路（AIVoiceoverTool）。

/// 回任务号之前做完的：每批的请求（整段报价定下的）、预留好的积分、Key、本机转写的语言。交给 SkyStudioVoiceoverRun。
@MainActor
struct SkyStudioVoiceoverPrepared {
    var plan: SkyStudioVoicePlan
    var quote: SkyStudioQuote
    var budget: SkyStudioVoiceBudget
    let key: String
    var locale: Locale?
    /// 交第一批之前先装 `locale` 的转写模型（这台 Mac 支持、还没装，又要转写）。
    var installsTranscription = false
    var modelTitle: String
    /// 报价时读的目录：装不上转写模型时按「转写不了」再定一次。
    var catalog: SkyStudioCatalog?
}

@MainActor
enum SkyStudioVoiceoverStart {
    enum Outcome {
        /// 起了任务（回 job_id），或者额度不够什么都没起：原样回给 AI。
        case result(AIToolResult)
        /// Sky Studio 这次用不了：付费请求之前当场退本机（`note` 说为什么，`catalog` 读到了就按预设的性别挑角色），
        /// 调用方换成本机的声音（AIVoiceoverInput.localFallback）照本机那条路合成、落地。
        case local(note: String, catalog: SkyStudioVoiceCatalog?)
        /// 不带前缀的名字不是 Sky Studio 的预设、是这台 Mac 的声音：照点名用它。
        case macVoice(String)
    }

    /// 读到的 Key、目录、认出来的声音：报价那一步要的。
    private struct Resolved {
        let key: String
        let catalog: SkyStudioCatalog
        let voices: SkyStudioVoiceCatalog
        let pick: SkyStudioVoicePick
        let kind: String
    }

    static func start(_ input: AIVoiceoverInput, project: VideoEditProject, services: SkyStudioVoiceServices? = nil) async throws -> Outcome {
        let services = services ?? SkyStudioVoiceServices()
        guard let ask = input.ask else { return .local(note: "", catalog: nil) }
        let key: String
        let catalog: SkyStudioCatalog
        do {
            key = try await services.key()
            catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if ask.isLibrary { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(error)) }
            return .local(note: unavailable(error), catalog: nil)
        }
        guard let voices = catalog.voices else {
            if ask.isLibrary { throw AIToolError("Sky Studio does not offer voice library reading yet. Nothing was charged.") }
            return .local(note: "Sky Studio does not list its voices yet, so a voice on this Mac read it.", catalog: nil)
        }
        let pick: SkyStudioVoicePick
        switch SkyStudioVoicePick.resolve(ask, in: voices, language: input.language) {
        case .cloud(let found): pick = found
        case .incomplete(let why): return .local(note: why + " A voice on this Mac read it instead.", catalog: voices)
        case .notPreset(let name):
            if case .name = ask, AIVoiceChoice.isInstalled(name, in: AISpeechSynthesis.installedVoices()) { return .macVoice(name) }
            throw AIToolError("There is no voice called \(name). Sky Studio's \(languageName(input.language)) presets: "
                + "\(SkyStudioVoicePick.listedNames(in: voices, language: input.language)); roles: \(AIVoiceRole.names); "
                + "or a SkyCut or Mac voice name. Nothing was charged.")
        }
        let kind = ask.kind
        if let named = input.model, catalog.model(named, kind: kind) == nil {
            throw AIToolError("Sky Studio has no narration model called \(named). Use model=auto or one of: "
                + "\(catalog.models(kind: kind).map(\.id).joined(separator: ", ")). Nothing was charged.")
        }
        guard catalog.voiceCharacterLimit(kind: kind, language: input.language) != nil else {
            if ask.isLibrary { throw AIToolError("Sky Studio gave no length limit for reading with library voices. Nothing was charged.") }
            return .local(note: "Sky Studio gave no length limit for \(languageName(input.language)) narration, "
                + "so a voice on this Mac read it.", catalog: voices)
        }
        let resolved = Resolved(key: key, catalog: catalog, voices: voices, pick: pick, kind: kind)
        return try await quoteAndStart(input, project: project, resolved: resolved, services: services)
    }

    /// 定怎么读 → 整段报价一次 → 核对 → 要转写的记下语言 → 整体预留 → 起任务。从这里往后不再换声音；花钱之前任何一步不行都停下、一分不花。
    private static func quoteAndStart(_ input: AIVoiceoverInput, project: VideoEditProject, resolved: Resolved,
                                      services: SkyStudioVoiceServices) async throws -> Outcome {
        let catalog = resolved.catalog
        let transcription = await services.transcription(input.speechLanguage)
        let reading = SkyStudioVoiceReading.decide(kind: resolved.kind, voice: resolved.pick.voice, model: input.model,
            subtitles: input.subtitles, language: input.language, transcribes: transcription.transcribes, catalog: catalog)
        let draft = try planned { try SkyStudioVoicePlan.draft(
            lines: input.lines.map(\.text), kind: resolved.kind, voice: resolved.pick.voice,
            reading: reading, language: input.language, catalog: catalog) }
        let quote: SkyStudioQuote
        do { quote = try await services.api.quote(draft.segment, key: resolved.key) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as SkyStudioFailure {
            if let refusal = refusal(failure) { throw AIToolError(refusal) }
            if resolved.kind == SkyStudioVoiceKind.clone { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(failure)) }
            return .local(note: unavailable(failure), catalog: resolved.voices)
        }
        var skippingOneTime = false
        if let voiceQuote = quote.voice, !voiceQuote.oneTime.isEmpty {
            switch try SkyStudioVoiceOneTimeStep.decide(input, quote: voiceQuote, key: resolved.key, catalog: catalog, project: project,
                                                         api: services.api) {
            case .readWithoutFee: skippingOneTime = true
            case .result(let result): return .result(result)
            }
        }
        let plan = try planned { try SkyStudioVoicePlan.quoted(draft, quote: quote, skippingOneTime: skippingOneTime) }
        guard project.isCurrentGeneration(input.generation), OpenProjects.shared.all.contains(where: { $0 === project }) else {
            throw AIToolError("The project changed while Sky Studio was quoting the voiceover; nothing was charged.")
        }
        var locale: Locale?
        var installs = false
        if plan.needsTranscription(subtitles: input.subtitles, catalog: catalog) {
            // 定的时候以为不用转写（报字时间的模型），服务器却选了不报的：切不开，花钱之前停下。
            guard let supported = transcription.locale else { throw AIToolError(transcriptionMissing(plan, language: input.language)) }
            locale = supported
            if case .downloadable = transcription { installs = true }
        }
        var ready = input
        ready.choice = AIVoiceChoice(engine: .skyStudio(voice: resolved.pick.voice),
                                     note: notes(resolved.pick, plan: plan, input: input, catalog: catalog))
        ready.ask = nil
        // 预留放在最后：从这里到交给任务之间不再有会失败的步骤，预留的积分不会落在半路（任务结束时没花出去的退回）。
        guard let budget = SkyStudioVoiceBudget.reserve(plan.batchCredits) else {
            return .result(SkyStudioJobGate.budgetBlocked(credits: plan.batchCredits.reduce(0, +), store: .shared))
        }
        let prepared = SkyStudioVoiceoverPrepared(plan: plan, quote: quote, budget: budget, key: resolved.key, locale: locale,
            installsTranscription: installs, modelTitle: modelTitle(plan, catalog: catalog), catalog: catalog)
        return .result(SkyStudioVoiceoverRun(input: ready, project: project, prepared: prepared, services: services).start())
    }

    /// 任务里装不上本机转写模型（交第一批之前，还一分没花）：照「这台 Mac 转写不了」重新定怎么读、分批、整段报价（声音方案第七节：
    /// 下载失败当作不能转写）。声音、kind、点名的模型不变；预留由调用方换（先退旧的、再留新的）。回新的计划、报价和要转告的话。
    static func withoutTranscription(_ prepared: SkyStudioVoiceoverPrepared, input: AIVoiceoverInput, failure: String,
                                     services: SkyStudioVoiceServices) async throws -> (plan: SkyStudioVoicePlan, quote: SkyStudioQuote, note: String) {
        let before = prepared.plan
        let language = languageName(input.language)
        let failure = failure.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        guard let catalog = prepared.catalog else {
            throw AIToolError("SkyCut could not install this Mac's speech model for \(language) (\(failure)); nothing was charged.")
        }
        let reading = SkyStudioVoiceReading.decide(kind: before.kind, voice: before.voice, model: input.model, subtitles: input.subtitles,
                                                   language: input.language, transcribes: false, catalog: catalog)
        let draft = try planned { try SkyStudioVoicePlan.draft(lines: input.lines.map(\.text), kind: before.kind, voice: before.voice,
                                                               reading: reading, language: input.language, catalog: catalog) }
        let quote: SkyStudioQuote
        do { quote = try await services.api.quote(draft.segment, key: prepared.key) }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw AIToolError("SkyCut could not install this Mac's speech model for \(language) (\(failure)), and asking Sky Studio "
                + "again for a price without it failed (\(reason(error))). Nothing was charged; try again.")
        }
        let plan = try planned { try SkyStudioVoicePlan.quoted(draft, quote: quote) }
        guard !plan.needsTranscription(subtitles: input.subtitles, catalog: catalog) else {
            throw AIToolError(transcriptionMissing(plan, language: input.language))
        }
        let why = "SkyCut could not install this Mac's speech model for \(language) (\(failure))."
        let timing = timingNote(reading, voice: before.voice, language: input.language, catalog: catalog, why: false)
        return (plan, quote, [why, timing].compactMap { $0 }.joined(separator: " "))
    }

    static func modelTitle(_ plan: SkyStudioVoicePlan, catalog: SkyStudioCatalog) -> String {
        plan.voicePlan.model.flatMap { model in catalog.models.first { $0.id == model }?.title } ?? "Sky Studio"
    }

    /// 服务器明说这个请求不行（4xx，除了 Key / 授权 / 版本 / 限流这几种「这次用不了」）：原话转给 AI，不换声音。
    static func refusal(_ failure: SkyStudioFailure) -> String? {
        guard case .server(let error) = failure, (400..<500).contains(error.status), ![401, 403, 426, 429].contains(error.status) else {
            return nil
        }
        return "Sky Studio refused this voiceover: \(error.message) Nothing was charged."
    }

    /// 定的时候以为不用转写，服务器却选了不报字时间的模型（几句一批切不开）：花钱之前停下。
    private static func transcriptionMissing(_ plan: SkyStudioVoicePlan, language: String) -> String {
        "Sky Studio chose \(plan.voicePlan.model ?? "a model") for this voiceover, which does not report when each word is spoken, "
            + "and this Mac cannot transcribe \(languageName(language)) speech to split its batches (macOS 26 or later, with that "
            + "language). Nothing was charged. Try again; if it happens again, name the model."
    }

    /// 字幕时间要转告的话（声音方案第七节）：整段换了报字时间的模型（声音换成这个预设的 Eleven 声音）、或者要按字数估。
    /// `why`：开头说不说「这台 Mac 转写不了这种语言」（装不上模型的那次由调用方另说原因）。
    static func timingNote(_ reading: SkyStudioVoiceReading, voice: String, language: String, catalog: SkyStudioCatalog,
                           why: Bool = true) -> String? {
        let cannot = why ? "This Mac cannot transcribe \(languageName(language)) speech, so " : "So "
        if reading.switchedForTiming {
            let stand = catalog.voices?.preset(voice)?.fallback?.voice ?? "its Eleven voice"
            return cannot + "\(reading.model) reads the whole script with \(voice)'s Eleven voice (\(stand)), which reports when "
                + "each word is spoken, for the subtitles. It sounds different from \(voice); tell the user."
        }
        if reading.timing == .estimated {
            return cannot + "this voice's subtitle timing will be estimated from character counts (it does not report when each word "
                + "is spoken) and may be off by about half a second; tell the user."
        }
        return nil
    }

    /// voice.note：认声音时的话、服务器的 warnings、跨语言、字幕时间、语速（Sky Studio 的声音按自己的语速读）。
    private static func notes(_ pick: SkyStudioVoicePick, plan: SkyStudioVoicePlan, input: AIVoiceoverInput,
                              catalog: SkyStudioCatalog) -> String? {
        var notes = pick.notes
        let language = languageName(input.language)
        for warning in plan.voicePlan.warnings {
            switch warning {
            case SkyStudioVoiceModelPlan.notListedForLanguage:
                notes.append("\(pick.voice) is not one of Sky Studio's recommended \(language) voices; it reads the text anyway, so listen first.")
            case SkyStudioVoiceModelPlan.modelNotTestedForLanguage:
                notes.append("\(plan.voicePlan.model ?? "The model") was not tested in \(language); listen before keeping it.")
            default:
                notes.append("Sky Studio warns: \(warning).")
            }
        }
        if plan.voicePlan.crossLanguage {
            notes.append("This voice has no \(language) recording, so it reads from a recording in another language; it may sound "
                + "less like the voice. Tell the user before they listen.")
        }
        if let reading = plan.reading, let timing = timingNote(reading, voice: pick.voice, language: input.language, catalog: catalog) {
            notes.append(timing)
        }
        // 点名的模型读不了这个预设自己的声音（Gemini 的预设点名 eleven-v4）：服务器换成它在那个模型上的替身，voice.name 还是点的那个
        // 预设 —— 说清楚实际是谁读的、听起来不一样（为了字幕时间整段换的那种，上面那句已经说了）。
        if plan.reading?.switchedForTiming != true, let reads = plan.voicePlan.voice, reads.lowercased() != pick.voice.lowercased() {
            notes.append("\(plan.voicePlan.model ?? "The named model") reads this with \(reads), the voice that stands in for "
                + "\(pick.voice) on that model. It sounds different from \(pick.voice); tell the user.")
        }
        if input.speed != 1 { notes.append("Sky Studio voices read at their own pace; speed was ignored.") }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private static func unavailable(_ error: Error) -> String {
        "Sky Studio could not be used (\(reason(error))), so a voice on this Mac read it."
    }

    private static func reason(_ error: Error) -> String {
        if let failure = error as? SkyStudioFailure { return SkyStudioJobError.request(failure).message }
        if let error = error as? AIToolError { return error.message }
        return error.localizedDescription
    }

    private static func planned<T>(_ make: () throws -> T) throws -> T {
        do { return try make() }
        catch let problem as SkyStudioVoicePlan.Problem { throw AIToolError(problem.message) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message + " Nothing was charged.") }
    }

    private static func languageName(_ language: String) -> String { SkyStudioVoicePick.languageName(language) }
}
