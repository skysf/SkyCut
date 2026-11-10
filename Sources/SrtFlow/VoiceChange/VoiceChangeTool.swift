import Foundation
import SrtFlowMCPKit

// MARK: - 工具：change_voice（把一段的人声换成另一个声音）
//
// 管什么（SkyCut 声音方案 4.8）：参数读成一次变声，和片段右键的面板同一条路（VoiceChangeSource 截声音、VoiceChangeOrder 定语言和报价、
// VoiceChangeJob 做和落地）：
// 1. 核对：这一段有声音、没静音；源秒数不超过 `/models` 的上限（超了拒、叫它先 split_clip）；目标声音是声音库的 `voice_…`（向
//    Sky Studio 问一次，拿名字和有哪几种语言的录音）或预设（`gemini:<名字>`、不带前缀的预设名）。
// 2. 收费之前：截出这一段的声音（几乎没声音的拒）、定这段说的是什么语言（`language` 给了就用它，否则本机检测）、`POST /quote`。
// 3. 把关：只判每日硬预算（不是一次性费用，两种权限模式都不问；超了回 daily_budget_exceeded、什么都不起）。
// 4. 起任务、**回任务号**；做完那一刻的落地是异步落账，任务里自己包一层 `AIUndoGrouping.step`（VoiceChangeJob.land）。
// Key 只静默读（AI 起的，没人在看）；声音库用不了（503 voice_library_unavailable）照实说、一分不花。
// 不管什么：说明文字（MCPVoiceChangeTool / MCPGuideVoiceChangeTopic）、面板（VoiceChangePanelModel）。

@MainActor
enum VoiceChangeTool {
    static func change(_ args: AIToolArguments, _ project: VideoEditProject, services: VoiceChangeServices? = nil) async throws -> AIToolResult {
        let services = services ?? VoiceChangeServices()
        let state = project.state
        let ids = AIShortIDs(state: state)
        let id = try ids.resolve(try args.requiredString("clip_id"))
        guard let clip = state.clip(with: id) else {
            throw AIToolError("\(ids.short(id)) is not a clip; change_voice works on a video or audio clip that has sound.")
        }
        if let problem = VoiceChangeSource.refusal(for: clip) { throw AIToolError(problem.message) }
        let requested = try args.requiredString("voice").trimmingCharacters(in: .whitespacesAndNewlines)
        let given = try args.string("language")
        guard !VoiceChangeActivity.shared.isChanging(id) else {
            throw AIToolError("\(clip.name) is already having its voice changed; wait for that job with get_job.")
        }
        let generation = project.documentGeneration

        // Sky Studio：Key（不弹框）、一次最长多少秒、目标声音。
        let key = try await services.voice.key()
        let catalog: SkyStudioCatalog
        do { catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(error)) }
        if let problem = VoiceChangeSource.tooLong(clip, limit: VoiceChangeOrder.maxSourceSeconds(in: catalog)) {
            throw AIToolError(problem.message)
        }
        let target = try await target(requested, catalog: catalog, key: key, services: services)

        // 收费之前：截声音、定语言、报价。截好的那段只在起了任务之后留着。
        let folder = services.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var started = false
        defer { if !started { try? FileManager.default.removeItem(at: folder) } }
        let source: VoiceChangeSource.Prepared
        do { source = try await VoiceChangeSource.prepare(clip, folder: folder) }
        catch let problem as VoiceChangeProblem { throw AIToolError(problem.message) }
        let spoken = try await VoiceChangeOrder.spokenLanguage(given: given, source: source, services: services)
        let draft: SkyStudioJobRequest
        do { draft = try VoiceChangeOrder.draft(target: target, seconds: source.seconds, spoken: spoken) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message + " Nothing was sent.") }
        let quote: SkyStudioQuote
        do { quote = try await services.api.quote(draft, key: key) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(error)) }

        // 问 Sky Studio 的这几秒里工程可能换了、这一段可能没了、别的调用可能已经起了这一段。
        guard project.documentGeneration == generation, let current = project.state.clip(with: id),
              !VoiceChangeActivity.shared.isChanging(id) else {
            throw AIToolError("The project changed while SkyCut prepared the voice change; nothing was started or charged. Call change_voice again.")
        }
        // 花钱：只判每日硬预算（不是一次性费用，不问）。
        guard let reservation = SkyStudioJobGate.reserveWithoutAsking(credits: quote.credits) else {
            return SkyStudioJobGate.budgetBlocked(credits: quote.credits, store: SkyStudioSpendStore.shared)
        }
        let job = VoiceChangeOrder.start(clip: current, source: source, draft: draft, quote: quote, target: target, key: key,
                                         reservation: reservation, project: project, notifies: false, services: services)
        started = true

        let spend = SkyStudioSpendStore.shared
        let minutes = quote.typicalSeconds.map { CloudJobProgress.minutes($0) }
        var result: [String: JSONValue] = [
            "status": "started", "job_id": .string(job.id), "kind": .string(AIJobs.Kind.voiceChange.rawValue), "provider": "Sky Studio",
            "clip_id": .string(ids.short(id)), "voice": .string(target.id), "voice_name": .string(target.name),
            "seconds_sent": AIFormat.seconds(source.seconds),
            "credits": .number(SkyStudioCredits.number(quote.credits)),
            "daily_limit_credits": .number(spend.dailyLimit), "spent_today_credits": .number(SkyStudioCredits.number(spend.spentToday())),
            "next_step": .string(
                "Tell the user it costs up to \(SkyStudioCredits.text(quote.credits)) Sky Studio credits"
                    + (minutes.map { " and usually takes about \($0) min" } ?? "") + ". Wait with get_job. When it is done the changed voice "
                    + "and the separated background are on two new linked audio tracks and the original clip is muted (one undo step)."
            )
        ]
        if let expected = quote.creditsExpected { result["credits_expected"] = .number(SkyStudioCredits.number(expected)) }
        if let minutes { result["typical_minutes"] = .number(Double(minutes)) }
        if let spoken { result["spoken_language"] = .string(spoken) }
        if let language = draft.params["target_language"]?.stringValue { result["target_language"] = .string(language) }
        let notes = notes(target: target, spoken: spoken, given: given != nil)
        if !notes.isEmpty { result["note"] = .string(notes.joined(separator: " ")) }
        return .ok(.object(result))
    }

    /// 目标声音：声音库的问 Sky Studio 一次（名字、有哪几种语言的录音），预设从目录里认（`gemini:charon`、`Charon` 都行）。
    private static func target(_ requested: String, catalog: SkyStudioCatalog, key: String, services: VoiceChangeServices) async throws -> VoiceChangeTarget {
        if SkyStudioVoice.isVoiceID(requested) {
            do { return VoiceChangeTarget(voice: try await services.api.voice(requested, key: key)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(error)) }
        }
        guard !requested.lowercased().hasPrefix("eleven:"), let voices = catalog.voices,
              let preset = SkyStudioVoicePick.preset(named: requested, in: voices) else {
            throw AIToolError("voice must be a voice from the user's library (voice_… id, see list_voices mine) or a Sky Studio preset "
                + "(gemini:Name, see list_voices presets); \"\(requested)\" is neither. Nothing was charged.")
        }
        return VoiceChangeTarget(preset: preset)
    }

    /// 要转告用户的话：用的不是同语言的参考、不知道这段说什么语言、拿预设当目标。
    private static func notes(target: VoiceChangeTarget, spoken: String?, given: Bool) -> [String] {
        var notes: [String] = []
        if let spoken, !target.languages.contains(spoken) {
            notes.append("\(target.name) has no \(SkyStudioVoicePick.languageName(spoken)) recording, so Sky Studio uses another of its "
                + "recordings; the result may sound less like the voice.")
        } else if spoken == nil, target.languages.count > 1 {
            notes.append("SkyCut could not tell which language this clip is in, so Sky Studio picks the recording itself; pass language "
                + "to use the matching one.")
        }
        if !target.isLibraryVoice {
            notes.append("A preset as the target is untested (its sample is only a few seconds); the user's own voice from list_voices "
                + "mine usually works better.")
        }
        return notes
    }
}
