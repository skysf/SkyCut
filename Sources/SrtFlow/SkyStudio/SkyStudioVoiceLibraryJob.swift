import Foundation
import SrtFlowMCPKit

// MARK: - 声音库的两种收费任务：设计声音、建 MiniMax 版
//
// 管什么（SkyCut 声音方案 4.5、4.7）：一次性费用点过头、记上账之后起的那一单：交给 Sky Studio（SkyStudioJobRun：满了等、不重放收费 POST、
// 只有排着队的能取消）、等做完、按服务器的结算证据改本机的账（多的退回、没花出去的退回），`get_job` 报新声音 / 建好的那种语言。
// 任务号立刻回（客户端对一次调用只等一分钟）；状态行和云端任务浮层沿用现有的（SkyStudioMediaStatus，挂在起它的那个工程上）。
// 做完的东西在服务器的声音库里（设计出来的声音、`minimax: true`），本机丢了这个任务也不丢成品，所以不另存恢复记录。
// 不管什么：问不问（SkyStudioJobGate.voiceOneTime）、请求怎么拼（SkyStudioVoiceRequests.design / enroll）、配旁白（add_voiceover）。

@MainActor
final class SkyStudioVoiceLibraryJob {
    private let kind: AIJobs.Kind
    private let request: SkyStudioJobRequest
    private let key: String
    private let api: SkyStudioAPI
    private var held: SkyStudioHeldCredits
    private let status: SkyStudioMediaStatus?
    /// 做完那一刻写给 AI 的下一步（建 MiniMax 版：回去再调 add_voiceover）。
    private let nextStep: String
    private var serverID: String?
    private var task: Task<Void, Never>?
    private var job: AIJobs.Job?

    init(kind: AIJobs.Kind, request: SkyStudioJobRequest, key: String, reservation: SkyStudioJobGate.Reservation, title: String,
         modelTitle: String, project: VideoEditProject?, nextStep: String, api: SkyStudioAPI = SkyStudioAPI()) {
        self.kind = kind
        self.request = request
        self.key = key
        self.api = api
        self.nextStep = nextStep
        held = SkyStudioHeldCredits(reservation)
        status = project.map { project in
            SkyStudioMediaStatus(kindLabel: L10n("Voice"), modelTitle: modelTitle, credits: reservation.credits, uploads: false,
                                 title: title, owner: CloudTasksActivity.owner(of: project), mediaKind: .audio)
        }
    }

    func start() -> AIJobs.Job {
        let job = AIJobs.shared.start(kind, progress: { nil }, liveDetail: { [weak self] in self?.live() ?? [:] },
                                      cancel: { [weak self] in self?.task?.cancel() })
        self.job = job
        if let status {
            status.aiJobID = job.id
            status.onCancel = { [weak self] in self?.task?.cancel() }
            SkyStudioGenerationActivity.shared.add(status)
        }
        task = Task { @MainActor in await self.execute() }
        return job
    }

    private func execute() async {
        defer { if let status { SkyStudioGenerationActivity.shared.remove(status) } }
        var runner = SkyStudioJobRun(api: api, key: key)
        runner.checkpoint = { [weak self] server in await self?.remember(server.jobID) }
        do {
            let done = try await runner.run(request) { [weak self] update in
                Task { @MainActor in self?.observe(update) }
            }
            if let charged = done.billing?.netCharged ?? done.creditsCharged { held.settle(charged: charged) }
            guard case .voice(let result)? = done.voiceResult else {
                return finish(.failed, "Sky Studio finished but returned no voice; query the original job before trying again.",
                              detail: ["skystudio_job_id": .string(done.jobID)])
            }
            // 设计出来的声音进了声音库、建好的 MiniMax 版改了那个声音：设置里的声音库那一节听这一声刷新。
            SkyStudioVoiceLibraryChange.post()
            finish(.done, message(result), detail: detail(result, server: done))
        } catch let error as SkyStudioJobError {
            if error.canRefund(beforeAccepted: serverID == nil) { held.refund() }
            finish(Task.isCancelled ? .cancelled : .failed, SkyStudioVoiceLibraryErrors.message(error), detail: [:])
        } catch {
            if serverID == nil { held.refund() }
            finish(Task.isCancelled ? .cancelled : .failed, SkyStudioVoiceLibraryErrors.message(error), detail: [:])
        }
    }

    private func remember(_ id: String) { serverID = id }

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
        var value = detail
        if outcome != .done, let serverID { value["skystudio_job_id"] = .string(serverID) }
        AIJobs.shared.finish(job, outcome, message: message, detail: value.isEmpty ? nil : .object(value))
    }
}
