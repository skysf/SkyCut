import Foundation
import SrtFlowMCPKit

// MARK: - 云端配旁白：回任务号之前做完的那几步（整段报价挪到这里）
// 管什么（SkyCut 声音方案 4.2 第 1–4 步）：静默读 Key → 读 `/models`（缓存 10 分钟）→ 认声音（SkyStudioVoicePick）→ 分批 →
// **整段 `POST /quote` 一次**（`params.batches`，`model` 是 auto 或点名的）→ 核对报价（voice_plan、批数、不要一次性费用）→
// 要字幕却拿不到字的时间时先确认本机能转写 → 按每批的 credits 整体预留（每日硬预算：不够当场回 daily_budget_exceeded，什么都不起）→
// 起任务、回 job_id，同时回 voice_plan 和要转告的 voice.note。
// 为什么挪到回任务号之前：一次性费用要在花钱之前问（声音 PR 6 接上），generate_media 本来就是先报价、过关再起任务；一段旁白只多一个请求。
// **退本机只在付费请求之前**（决定第七节第 4 条）：Key / 目录 / 报价读不到（断网、5xx、Key 不认）就当场换本机的声音；
// 服务器明说这个请求不行（4xx：模型和声音配不上、语言不支持……）原话转给 AI、一分不花、不换声音；额度不够也不换声音（2026-11-01 定）。
// 不管什么：交、等、下载、切句、落地（SkyStudioVoiceoverRun）；本机的那条路（AIVoiceoverTool）。

/// 回任务号之前做完的：每批的请求（整段报价定下的）、预留好的积分、Key、本机转写的语言。交给 SkyStudioVoiceoverRun。
@MainActor
struct SkyStudioVoiceoverPrepared {
    let plan: SkyStudioVoicePlan
    let quote: SkyStudioQuote
    let budget: SkyStudioVoiceBudget
    let key: String
    let locale: Locale?
    let modelTitle: String
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
        catch { return .local(note: unavailable(error), catalog: nil) }
        guard let voices = catalog.voices else {
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
        let kind = SkyStudioVoiceKind.narration
        if let named = input.model, catalog.model(named, kind: kind) == nil {
            throw AIToolError("Sky Studio has no narration model called \(named). Use model=auto or one of: "
                + "\(catalog.models(kind: kind).map(\.id).joined(separator: ", ")). Nothing was charged.")
        }
        guard catalog.voiceCharacterLimit(kind: kind, language: input.language) != nil else {
            return .local(note: "Sky Studio gave no length limit for \(languageName(input.language)) narration, "
                + "so a voice on this Mac read it.", catalog: voices)
        }
        let resolved = Resolved(key: key, catalog: catalog, voices: voices, pick: pick, kind: kind)
        return try await quoteAndStart(input, project: project, resolved: resolved, services: services)
    }

    /// 整段报价一次 → 核对 → 要转写的先确认转写得了 → 整体预留 → 起任务。从这里往后不再换声音；花钱之前任何一步不行都停下、一分不花。
    private static func quoteAndStart(_ input: AIVoiceoverInput, project: VideoEditProject, resolved: Resolved,
                                      services: SkyStudioVoiceServices) async throws -> Outcome {
        let catalog = resolved.catalog
        let draft = try planned { try SkyStudioVoicePlan.draft(
            lines: input.lines.map(\.text), kind: resolved.kind, voice: resolved.pick.voice,
            model: input.model ?? SkyStudioVoiceRequests.autoModel, language: input.language, catalog: catalog) }
        let quote: SkyStudioQuote
        do { quote = try await services.api.quote(draft.segment, key: resolved.key) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as SkyStudioFailure {
            if let refusal = refusal(failure) { throw AIToolError(refusal) }
            return .local(note: unavailable(failure), catalog: resolved.voices)
        }
        let plan = try planned { try SkyStudioVoicePlan.quoted(draft, quote: quote) }
        guard project.isCurrentGeneration(input.generation), OpenProjects.shared.all.contains(where: { $0 === project }) else {
            throw AIToolError("The project changed while Sky Studio was quoting the voiceover; nothing was charged.")
        }
        var locale: Locale?
        if plan.needsTranscription(subtitles: input.subtitles, catalog: catalog) {
            do { locale = try await services.locale(input.language) }
            catch is CancellationError { throw CancellationError() }
            catch { throw AIToolError(transcriptionMissing(plan, subtitles: input.subtitles, catalog: catalog, language: input.language)) }
        }
        var ready = input
        ready.choice = AIVoiceChoice(engine: .skyStudio(voice: resolved.pick.voice), note: notes(resolved.pick, plan: plan, input: input))
        ready.ask = nil
        // 预留放在最后：从这里到交给任务之间不再有会失败的步骤，预留的积分不会落在半路（任务结束时没花出去的退回）。
        guard let budget = SkyStudioVoiceBudget.reserve(plan.batchCredits) else {
            return .result(SkyStudioJobGate.budgetBlocked(credits: plan.batchCredits.reduce(0, +), store: .shared))
        }
        let title = plan.voicePlan.model.flatMap { model in catalog.models.first { $0.id == model }?.title } ?? "Sky Studio"
        let prepared = SkyStudioVoiceoverPrepared(plan: plan, quote: quote, budget: budget, key: resolved.key, locale: locale, modelTitle: title)
        return .result(SkyStudioVoiceoverRun(input: ready, project: project, prepared: prepared, services: services).start())
    }

    /// 服务器明说这个请求不行（4xx，除了 Key / 授权 / 版本 / 限流这几种「这次用不了」）：原话转给 AI，不换声音。
    static func refusal(_ failure: SkyStudioFailure) -> String? {
        guard case .server(let error) = failure, (400..<500).contains(error.status), ![401, 403, 426, 429].contains(error.status) else {
            return nil
        }
        return "Sky Studio refused this voiceover: \(error.message) Nothing was charged."
    }

    /// 转写不了时的话（声音 PR 5 起改成：明着下载转写模型、预设整段改点名报字时间的模型、克隆的按字数估）。
    private static func transcriptionMissing(_ plan: SkyStudioVoicePlan, subtitles: Bool, catalog: SkyStudioCatalog, language: String) -> String {
        let model = plan.voicePlan.model ?? "This voice"
        let timed = catalog.models(kind: plan.kind).first { $0.givesWordTimes == true }?.id
        var text = (subtitles ? "Subtitles for this voiceover" : "Splitting several lines out of one batch")
            + " need this Mac's speech transcription for \(languageName(language)) (macOS 26 or later, with that language's model "
            + "installed), because \(model) does not report when each word is spoken. Nothing was charged. Run generate_subtitles "
            + "once on a clip in that language to install it"
        if subtitles { text += ", or call again with subtitles=false" }
        if subtitles, let timed { text += ", or name model=\(timed)" }
        return text + "."
    }

    /// voice.note：认声音时的话、服务器的 warnings、跨语言、语速（Sky Studio 的声音按自己的语速读）。
    private static func notes(_ pick: SkyStudioVoicePick, plan: SkyStudioVoicePlan, input: AIVoiceoverInput) -> String? {
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
        if input.speed != 1 { notes.append("Sky Studio voices read at their own pace; speed was ignored.") }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private static func unavailable(_ error: Error) -> String {
        let reason: String
        if let failure = error as? SkyStudioFailure { reason = SkyStudioJobError.request(failure).message }
        else if let error = error as? AIToolError { reason = error.message }
        else { reason = error.localizedDescription }
        return "Sky Studio could not be used (\(reason)), so a voice on this Mac read it."
    }

    private static func planned<T>(_ make: () throws -> T) throws -> T {
        do { return try make() }
        catch let problem as SkyStudioVoicePlan.Problem { throw AIToolError(problem.message) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message + " Nothing was charged.") }
    }

    private static func languageName(_ language: String) -> String { SkyStudioVoicePick.languageName(language) }
}
