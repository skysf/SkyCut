import Foundation
import SrtFlowMCPKit

// MARK: - 声音库的两种收费任务：设计声音、建 MiniMax 版
//
// 管什么（SkyCut 声音方案 4.5、4.7）：一次性费用点过头、记上账之后起的那一单：交给 Sky Studio（SkyStudioJobRun：满了等、不重放收费 POST、
// 只有排着队的能取消）、等做完、按服务器的结算证据改本机的账（多的退回、没花出去的退回），`get_job` 报新声音 / 建好的那种语言。
// 任务号立刻回（客户端对一次调用只等一分钟）；状态行和云端任务浮层沿用现有的（SkyStudioMediaStatus，挂在起它的那个工程上）。
// 做完的东西在服务器的声音库里（设计出来的声音、`minimax: true`），本机丢了这个任务也不丢成品；**丢不得的是本机的那一笔账**：
// 交之前落盘（SkyStudioVoiceLibraryOrders），SkyCut 中途退出、重启之后照它接着跟（`follow`，只 GET），按原来那一笔结账、只记一次
// （docs/bugfixes/2026-11-11-voice-library-job-after-restart.md）。
// **同一件事只开一单**（`identity`：同一份设计的订单、同一个声音 + 语言的 MiniMax 版）：还在跑就回那一单、这一笔预留退回，本机的账只记一次
// （服务器对同一个 key、对同一个声音 + 语言开着的建单本来就只扣一次，回的是原来那一单；本机再起一个任务跟它就把同一笔钱记成两笔。
// docs/bugfixes/2026-11-11-design-voice-ordered-twice.md）。调用方要在问用户、预留之前先看 `running`，这里是最后一道。
// 没做成时 `get_job` 带服务器的原因（`failure`）；改了价（`price_changed`）的把新价带上（`credits_now`），调用方给的 `onFailure` 说下一步。
// 不管什么：问不问（SkyStudioJobGate.voiceOneTime）、请求怎么拼（SkyStudioVoiceRequests.design / enroll）、配旁白（add_voiceover）。

@MainActor
final class SkyStudioVoiceLibraryJob {
    private let kind: AIJobs.Kind
    private let request: SkyStudioJobRequest
    private let key: String
    private let api: SkyStudioAPI
    /// 起任务时记上账的那一笔（落盘用；结账、退回走 `held`）。
    private let reservation: SkyStudioJobGate.Reservation
    private var held: SkyStudioHeldCredits
    private let status: SkyStudioMediaStatus?
    /// 做完那一刻写给 AI 的下一步（建 MiniMax 版：回去再调 add_voiceover）。
    private let nextStep: String
    private var serverID: String?
    private var accepted = false
    /// 重启之前交的那一单（SkyStudioVoiceLibraryOrders.resume）：只 GET 跟到底、不再交。
    private var resumed: String?
    private var task: Task<Void, Never>?
    private var job: AIJobs.Job?
    private let identity: String

    /// 服务器受理了这一单（回了任务号）那一刻，只叫一次：受理之后才算数的事放这里（旁白中途那笔费用的问题这时才清）。
    var onAccepted: (@MainActor () async -> Void)?
    /// 没做成时并进 get_job 的字段（下一步怎么办）；`credits`：`price_changed` 带的新价，别的失败是 nil。
    var onFailure: (@MainActor (_ code: String?, _ credits: Double?) async -> [String: JSONValue])?

    /// 问 Sky Studio 的间隔怎么等；自检换成不真睡的（生产是 nil：照 SkyStudioJobRun 的）。
    static var pollSleep: (@Sendable (Double) async throws -> Void)?

    /// 同一件事还开着的那一单（跑完的顺手忘掉）。
    private static var open: [String: AIJobs.Job] = [:]

    static func running(_ identity: String) -> AIJobs.Job? {
        guard let job = open[identity] else { return nil }
        if job.status == .running { return job }
        open[identity] = nil
        return nil
    }

    /// 一份设计的订单：报价对的那一份请求（它的 idempotency_key 在问价时就定了，同一份报价重按、重入都是同一单）。
    static func designIdentity(_ request: SkyStudioJobRequest) -> String { "design:" + request.idempotencyKey }

    /// 给这个账户的这个声音建这种语言的 MiniMax 版（服务器按声音 + 语言去重，不看 key）。
    static func enrollIdentity(voice: String, language: String, account: String) -> String {
        "enroll:" + account + ":" + voice + ":" + language.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 落了盘的那一单在这次运行里的身份（重启之后照它认「同一件事」；和上面两个同一份算法）。
    static func identity(_ kind: AIJobs.Kind, request: SkyStudioJobRequest, key: String) -> String? {
        switch kind {
        case .voiceDesign:
            return designIdentity(request)
        case .voiceEnroll:
            guard let voice = request.params["voice"]?.stringValue, let language = request.params["language"]?.stringValue else { return nil }
            return enrollIdentity(voice: voice, language: language, account: SkyStudioCharacterAccess.stamp(key))
        default:
            return nil
        }
    }

    init(kind: AIJobs.Kind, identity: String, request: SkyStudioJobRequest, key: String, reservation: SkyStudioJobGate.Reservation, title: String,
         modelTitle: String, project: VideoEditProject?, nextStep: String, api: SkyStudioAPI = SkyStudioAPI()) {
        self.kind = kind
        self.identity = identity
        self.request = request
        self.key = key
        self.api = api
        self.nextStep = nextStep
        self.reservation = reservation
        held = SkyStudioHeldCredits(reservation)
        status = project.map { project in
            SkyStudioMediaStatus(kindLabel: L10n("Voice"), modelTitle: modelTitle, credits: reservation.credits, uploads: false,
                                 title: title, owner: CloudTasksActivity.owner(of: project), mediaKind: .audio)
        }
    }

    /// 重启之前交的那一单（SkyStudioVoiceLibraryOrders.resume 读出来的）：按原来那一笔结账，没做成时按种类说下一步（起它的那次调用早没了）。
    convenience init(resuming record: SkyStudioVoiceLibraryOrders.Record, kind: AIJobs.Kind, identity: String, jobID: String, key: String,
                     api: SkyStudioAPI) {
        self.init(kind: kind, identity: identity, request: record.request, key: key,
                  reservation: .init(credits: record.reservedCredits, day: record.reservedDay), title: "", modelTitle: "", project: nil,
                  nextStep: record.nextStep, api: api)
        serverID = jobID
        accepted = true
        resumed = jobID
        onFailure = { _, _ in ["next_step": .string(Self.retryStep(kind))] }
    }

    func start() -> AIJobs.Job {
        // 最后一道：落了盘、这次运行里还没人跟的同一件事（重启之前交的）先接着跟起来，下面就认得出它。
        SkyStudioVoiceLibraryOrders.resume(key: key, api: api)
        // 同一件事已经开着一单：跟它，这一笔预留退回（不起第二个任务、不记第二笔）。
        if let existing = Self.running(identity) {
            held.refund()
            return existing
        }
        let job = launch()
        // 交之前落盘：SkyCut 中途退出，重启之后照它接着跟、按这一笔结账（SkyStudioVoiceLibraryOrders）。
        SkyStudioVoiceLibraryOrders.save(.init(kind: kind.rawValue, account: SkyStudioVoiceLibraryOrders.account(key), request: request,
                                               reservedCredits: reservation.credits, reservedDay: reservation.day, jobID: nil, nextStep: nextStep))
        task = Task { @MainActor in await self.execute() }
        return job
    }

    /// 接着跟重启之前交的那一单（`resume` 已经看过这次运行里没人在跟）：记录已经在盘上，不另存。
    func follow() -> AIJobs.Job {
        let job = launch()
        task = Task { @MainActor in await self.execute() }
        return job
    }

    private func launch() -> AIJobs.Job {
        let job = AIJobs.shared.start(kind, progress: { nil }, liveDetail: { [weak self] in self?.live() ?? [:] },
                                      cancel: { [weak self] in self?.task?.cancel() })
        self.job = job
        Self.open[identity] = job
        if let status {
            status.aiJobID = job.id
            status.onCancel = { [weak self] in self?.task?.cancel() }
            SkyStudioGenerationActivity.shared.add(status)
        }
        return job
    }

    private func execute() async {
        defer { if let status { SkyStudioGenerationActivity.shared.remove(status) } }
        var runner = SkyStudioJobRun(api: api, key: key)
        if let sleep = Self.pollSleep { runner.sleep = sleep }
        runner.checkpoint = { [weak self] server in await self?.remember(server.jobID) }
        let order = request.idempotencyKey
        do {
            let done = try await runToEnd(runner)
            // 有结局了：先删记录再改账（中间出事只会多算那一笔，不会结两次）。
            SkyStudioVoiceLibraryOrders.remove(order)
            if let charged = done.billing?.netCharged ?? done.creditsCharged { held.settle(charged: charged) }
            guard case .voice(let result)? = done.voiceResult else {
                return finish(.failed, "Sky Studio finished but returned no voice; query the original job before trying again.",
                              detail: ["skystudio_job_id": .string(done.jobID)])
            }
            // 设计出来的声音进了声音库、建好的 MiniMax 版改了那个声音：设置里的声音库那一节听这一声刷新。
            SkyStudioVoiceLibraryChange.post()
            finish(.done, message(result), detail: detail(result, server: done))
        } catch let error as SkyStudioJobError {
            // 服务器上还没结局（问不到了、等太久、停不下来、交的回答丢了）：记录和那一笔都留着，下次读到 Key / 同一件事再来时接着跟、那时再结。
            let refund = error.canRefund(beforeAccepted: serverID == nil)
            if refund || !SkyStudioVoiceLibraryOrders.unresolved(error, accepted: serverID != nil) {
                SkyStudioVoiceLibraryOrders.remove(order)
                if refund { held.refund() }
            }
            let outcome: AIJobs.Status = Task.isCancelled ? .cancelled : .failed
            finish(outcome, SkyStudioVoiceLibraryErrors.message(error), detail: await failureDetail(error))
        } catch {
            // 不是 Sky Studio 说的：没受理的退回；受理了的留着记录接着跟。
            if serverID == nil {
                SkyStudioVoiceLibraryOrders.remove(order)
                held.refund()
            }
            // 别的错（不是 Sky Studio 说的）：没有原因可带，下一步照样由起它的地方说。
            let next = await onFailure?(nil, nil) ?? [:]
            finish(Task.isCancelled ? .cancelled : .failed, SkyStudioVoiceLibraryErrors.message(error), detail: next)
        }
    }

    /// 交上去等它做完；重启之前交的那一单只 GET（第一次问的错和后面问的一样算）。
    private func runToEnd(_ runner: SkyStudioJobRun) async throws -> SkyStudioJobStatus {
        let update: @Sendable (SkyStudioJobRun.Update) -> Void = { [weak self] update in Task { @MainActor in self?.observe(update) } }
        guard let resumed else { return try await runner.run(request, onUpdate: update) }
        do { return try await runner.resume(resumed, onUpdate: update) }
        catch let failure as SkyStudioFailure { throw SkyStudioJobError.request(failure) }
    }

    /// 没做成：服务器的原因原样带上（`failure`）；改了价的把新价单独写出来（`credits_now`，旧的那个数在 `credits_approved`），
    /// 调用方说下一步（重新问价、再问用户；旁白中途那一笔把新价记进恢复记录）。
    private func failureDetail(_ error: SkyStudioJobError) async -> [String: JSONValue] {
        var value: [String: JSONValue] = [:]
        var priced: Double?
        if let failure = error.failure {
            value["failure"] = failure.json
            if let code = failure.code { value["code"] = .string(code) }
        }
        if case .request(.server(let server)) = error, server.code == "price_changed", let credits = server.fields["credits"]?.doubleValue,
           credits.isFinite, credits >= 0 {
            priced = credits
            value["credits_now"] = .number(credits)
            if let approved = request.maxCredits { value["credits_approved"] = .number(approved) }
        }
        if let onFailure { value.merge(await onFailure(error.failure?.code, priced)) { _, new in new } }
        return value
    }

    private func remember(_ id: String) async {
        if serverID == nil { serverID = id }
        guard !accepted else { return }
        accepted = true
        adoptEarlier(id)
        await onAccepted?()
    }

    /// 受理了：记录上记下任务号。同一件事早先那一单（重启之前交的、交的回答丢了，账还没结）服务器只为它扣一次
    /// （同一个声音 + 语言开着的建单回的就是原来那一单）：它的那一笔归这一单结，这一笔退回——账只记一次。
    private func adoptEarlier(_ id: String) {
        let identity = identity, key = key, account = SkyStudioVoiceLibraryOrders.account(key)
        guard let earlier = SkyStudioVoiceLibraryOrders.accept(request.idempotencyKey, jobID: id, sameOrder: { record in
            record.account == account && AIJobs.Kind(rawValue: record.kind).flatMap { Self.identity($0, request: record.request, key: key) } == identity
        }) else { return }
        held.refund()
        held = SkyStudioHeldCredits(SkyStudioJobGate.Reservation(credits: earlier.reservedCredits, day: earlier.reservedDay))
    }

    /// 重启之后接着跟的那一单没做成：起它的那次调用早没了，按种类说下一步。
    private static func retryStep(_ kind: AIJobs.Kind) -> String {
        kind == .voiceDesign
            ? "No voice was designed. To try again, call manage_voices action=design again: it quotes the current price and asks the user again."
            : "The MiniMax version was not built. Call add_voiceover again with the same lines and voice (or resume the narration's recovery "
                + "file): it quotes the current price and asks the user again."
    }

    private func observe(_ update: SkyStudioJobRun.Update) {
        guard let status else { return }
        switch update {
        case .waitingForSlot: status.advance(to: .queued(position: nil), typicalSeconds: 0)
        case .status(let server):
            if serverID == nil { serverID = server.jobID }
            switch server.state {
            case .queued?: status.advance(to: .queued(position: server.queuePosition), typicalSeconds: server.typicalSeconds ?? 0)
            case .running?: status.advance(to: .processing, typicalSeconds: server.typicalSeconds ?? 0)
            default: break
            }
        }
    }

    private func live() -> [String: JSONValue] {
        var value: [String: JSONValue] = ["provider": "Sky Studio", "credits": .number(request.maxCredits ?? 0)]
        if let serverID { value["skystudio_job_id"] = .string(serverID) }
        return value
    }

    private func message(_ result: SkyStudioVoiceLibraryResult) -> String {
        let name = result.voice.name
        if kind == .voiceDesign { return "Designed the voice \"\(name)\" (\(result.voice.id)). Listen to sample_url before using it." }
        let language = request.params["language"]?.stringValue.map(SkyStudioVoicePick.languageName) ?? "this language"
        return "Built the MiniMax version of \"\(name)\" for \(language)."
    }

    private func detail(_ result: SkyStudioVoiceLibraryResult, server: SkyStudioJobStatus) -> [String: JSONValue] {
        var value: [String: JSONValue] = ["voice": result.voice.json, "skystudio_job_id": .string(server.jobID), "next_step": .string(nextStep)]
        if let sample = result.sampleURL { value["sample_url"] = .string(sample.absoluteString) }
        if let expires = result.sampleExpiresAt { value["sample_expires_at"] = .string(ISO8601DateFormatter().string(from: expires)) }
        if !result.warnings.isEmpty { value["warnings"] = .array(result.warnings.map(JSONValue.string)) }
        if let charged = server.billing?.netCharged ?? server.creditsCharged { value["credits_charged"] = .number(charged) }
        if let billing = server.billing { value["billing"] = billing.json }
        return value
    }

    private func finish(_ outcome: AIJobs.Status, _ message: String, detail: [String: JSONValue]) {
        guard let job else { return }
        // 这一单到头了：不再算「开着」（之后同一件事再来就是新的一单，照常问 / 记账）。
        if Self.open[identity]?.id == job.id { Self.open[identity] = nil }
        var value = detail
        if outcome != .done, let serverID { value["skystudio_job_id"] = .string(serverID) }
        AIJobs.shared.finish(job, outcome, message: message, detail: value.isEmpty ? nil : .object(value))
    }
}
