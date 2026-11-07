import Foundation
import SrtFlowMCPKit

// 原生角色任务的 App 适配：先持久化获准请求 / 每张上传，再经共用 Workflow / JobRun；恢复原单绝不上传或重报价。
@MainActor
final class SkyStudioCharacterRun {
    private var receipt: SkyStudioCharacterReceipt
    private let plan: SkyStudioCharacterPlan?
    private let approvedFiles: [JSONValue]
    private let key: String
    private let stamp: String
    private let retryFreeImport: Bool
    private var held: SkyStudioHeldCredits?
    private let activity: SkyStudioMediaStatus?
    private var task: Task<Void, Never>?
    private var job: AIJobs.Job?
    private var refreshing = false
    private var recoveryEvidenceSaved: Bool?

    init(receipt: SkyStudioCharacterReceipt, key: String, project: VideoEditProject?, plan: SkyStudioCharacterPlan? = nil,
         approvedFiles: [JSONValue] = [], reservation: SkyStudioJobGate.Reservation? = nil, retryFreeImport: Bool = false) {
        self.receipt = receipt; self.key = key; self.stamp = SkyStudioCharacterAccess.stamp(key)
        self.plan = plan; self.approvedFiles = approvedFiles; self.retryFreeImport = retryFreeImport
        held = reservation.map { SkyStudioHeldCredits($0) }
        if let project {
            activity = SkyStudioMediaStatus(kindLabel: L10n("Image"), modelTitle: receipt.request.model.isEmpty ? "Sky Studio" : receipt.request.model,
                credits: receipt.reservedCredits, uploads: plan?.files.isEmpty == false,
                title: plan?.title.isEmpty == false ? plan!.title : L10n("Image"), owner: CloudTasksActivity.owner(of: project), mediaKind: .image)
        } else { activity = nil }
    }

    func start() -> AIJobs.Job {
        let job = AIJobs.shared.start(.generate, id: receipt.localID, replacingFinished: true, progress: { nil },
            liveDetail: { [self] in payload() }, cancel: { [weak self] in self?.task?.cancel() })
        self.job = job
        job.refresh = { [self] in await refresh() }
        if let activity {
            activity.aiJobID = job.id
            activity.onCancel = { [weak self] in self?.task?.cancel() }
            SkyStudioGenerationActivity.shared.add(activity)
        }
        task = Task { await execute() }
        return job
    }

    private func execute() async {
        defer { if let activity { SkyStudioGenerationActivity.shared.remove(activity) } }
        let workflow = SkyStudioCharacterWorkflow(api: SkyStudioAPI(), key: key)
        do {
            if let plan {
                try await validateAccount()
                activity?.advance(to: plan.files.isEmpty ? .preparing : .uploading(fraction: nil), typicalSeconds: plan.quote?.typicalSeconds ?? 0)
                let prepared = try await workflow.upload(plan, approvedFiles: approvedFiles, checkpoint: { [self] prepared in
                    try await saveInputs(prepared)
                }, progress: { [weak self] fraction in
                    Task { @MainActor in self?.activity?.advance(to: .uploading(fraction: CloudJobPhase.quantized(fraction)), typicalSeconds: 0) }
                })
                try await saveInputs(prepared)
            }
            if let mutation = receipt.mutation {
                if plan == nil {
                    try await readMutation()
                    return finish(receipt.latest["mutation_completed"] == true ? .done : .failed,
                        "Original role replacement inspected without uploading or writing again; check current_character and recovery_state.")
                }
                try await beforeSubmit()
                try Task.checkCancellation()
                let api = workflow.api, key = self.key
                let result = try await Task.detached { try await api.mutateCharacter(mutation, key: key) }.value
                receipt.latest = result.objectValue ?? [:]
                receipt.latest["mutation_completed"] = true
                receipt.latest["credits_charged"] = 0; receipt.latest["credits_unknown"] = false
                receipt.latest["generation_status"] = "not_submitted"
                receipt.latest["billing"] = ["status": "not_charged", "credits_charged": 0]
                receipt.latest["next_step"] = "Refresh the character and quote before using the replacement view. The timeline is unchanged."
                try await SkyStudioCharacterJobs.persist(receipt)
                SkyStudioCharacterAccess.invalidateLibrary(characterID: mutation.id)
                return finish(.done, "Character view replaced; no credits charged.")
            }
            guard receipt.rejectionCode == nil else { return finish(.failed, "The original operation was not submitted; this key remains retired.") }
            let recovery = receipt.recovery(explicitFreeImport: retryFreeImport)
            guard receipt.jobID != nil || plan != nil || recovery == .freeImport else {
                return finish(.failed, receipt.isFree
                    ? "The free import reply was lost. Explicitly resume this import to recover the same key without uploading again."
                    : "The original paid submission has no known job_id. Preserve its key for server reconciliation; no paid POST was repeated.")
            }
            let previousRevision = receipt.latest["character"]?["revision"]?.stringValue ?? receipt.request.character?.revision
            _ = try await workflow.run(receipt.request, resuming: receipt.jobID, checkpoint: { [self] status in
                try await observed(status)
            }, beforeSubmit: { [self] in try await beforeSubmit() })
            invalidateChangedCharacter(previousRevision: previousRevision)
            finish(.done, SkyStudioCharacterJobReport.completionMessage(resuming: plan == nil))
        } catch let error as SkyStudioJobError {
            if error.canRefund(beforeAccepted: receipt.jobID == nil) { held?.refund() }
            if let failure = error.failure {
                do { try receipt.receivedFailure(failure) }
                catch { receipt.latest["recovery_error"] = "Server failure evidence conflicted with the retained original job_id; the original identity was preserved." }
            }
            if case .request(.server(let server)) = error, server.code == "character_checkpoint_failed",
               server.fields["credits_reserved"] == 0, server.fields["submission_state"] == "not_submitted" {
                receipt.latest["credits_reserved"] = 0; receipt.latest["submission_state"] = "not_submitted"
                receipt.latest["credits_charged"] = 0; receipt.latest["credits_unknown"] = false
            }
            if let code = error.rejectedBeforeAdmissionCode, receipt.jobID == nil {
                receipt.rejectionCode = code
            }
            await saveFailureEvidence()
            finish(Task.isCancelled ? .cancelled : .failed, error.message)
        } catch {
            if !receipt.submissionAttempted {
                held?.refund(); receipt.rejectionCode = "local_not_sent"
                await saveFailureEvidence()
            }
            finish(Task.isCancelled ? .cancelled : .failed, SkyStudioCharacterError.tool(error).message)
        }
    }

    private func saveFailureEvidence() async {
        do { try await SkyStudioCharacterJobs.persist(receipt); recoveryEvidenceSaved = true }
        catch { recoveryEvidenceSaved = false }
    }

    private func invalidateChangedCharacter(previousRevision: String?) {
        if let id = receipt.characterID, let revision = receipt.latest["character"]?["revision"]?.stringValue, revision != previousRevision {
            SkyStudioCharacterAccess.invalidateLibrary(characterID: id)
        }
    }

    private func validateAccount() async throws {
        let current = try await SkyStudioOfficialGenerateTool.readKey()
        guard current == key, SkyStudioCharacterAccess.stamp(current) == stamp,
              try SkyStudioCharacterJobs.account() == receipt.accountID else { throw SkyStudioJobError.notSubmitted("The Sky Studio account/key changed; no new Character submission was sent.") }
    }

    private func beforeSubmit() async throws {
        try await validateAccount()
        receipt.submissionAttempted = true
        try await SkyStudioCharacterJobs.persist(receipt)
    }

    private func saveInputs(_ prepared: SkyStudioCharacterPlan) async throws {
        guard var request = prepared.job else { throw SkyStudioCharacterReceiptError.invalid }
        request.idempotencyKey = receipt.idempotencyKey
        receipt.request = request
        receipt.mutation = prepared.mutation
        try await SkyStudioCharacterJobs.persist(receipt)
    }

    private func observed(_ server: SkyStudioJobStatus) async throws {
        try receipt.received(server)
        if let charged = server.billing?.netCharged { held?.settle(charged: charged) }
        try await SkyStudioCharacterJobs.persist(receipt)
        let phase: CloudJobPhase = server.state == .queued ? .queued(position: server.queuePosition)
            : server.characterStatus == "finalizing" || server.phase == "saving" ? .finishing : .processing
        activity?.advance(to: phase, typicalSeconds: server.typicalSeconds ?? 0)
    }

    private func payload() -> [String: JSONValue] {
        var fields = receipt.latest
        fields["idempotency_key"] = .string(receipt.idempotencyKey)
        fields["character_id"] = receipt.characterID.map(JSONValue.string) ?? fields["character_id"] ?? .null
        fields["character_operation"] = .string(receipt.operation)
        fields["approval_identity"] = .string(receipt.approvalIdentity)
        fields["cancellable"] = false
        fields["model_id"] = (receipt.request.model.isEmpty ? .null : .string(receipt.request.model))
        fields["params"] = .object(receipt.request.params)
        if let recoveryEvidenceSaved {
            fields["recovery_evidence_saved"] = .bool(recoveryEvidenceSaved)
            if !recoveryEvidenceSaved { fields["recovery_note"] = "The latest evidence could not be saved. Keep this original operation; after restart uncertain evidence stays blocked rather than replaying payment." }
        }
        if let activity { fields.merge(activity.progress?.json() ?? [:]) { _, new in new } }
        if let code = receipt.rejectionCode {
            fields["recovery_state"] = "confirmed_not_submitted"; fields["rejection_code"] = .string(code); fields["charged"] = false
        } else if receipt.mutation != nil {
            fields["credits_charged"] = 0; fields["credits_unknown"] = false
            fields["uploaded_asset"] = receipt.mutation?.body["asset"] ?? .null
            if receipt.latest["mutation_completed"] != true {
                fields["recovery_state"] = receipt.submissionAttempted ? "library_write_unknown" : "interrupted_before_submission"
                fields["next_step"] = "Read current_character/get_character and compare the original revision and uploaded asset before any new write. Recovery never repeats this upload or overwrites a concurrent edit."
            }
        } else if receipt.jobID == nil, receipt.submissionAttempted {
            fields["recovery_state"] = "submission_unknown"
            fields["credits_unknown"] = .bool(!receipt.isFree)
            fields["next_step"] = receipt.isFree
                ? "Free import only: manage_characters action=import resume=job_id explicitly recovers the same saved import body/key without any new upload or wallet charge."
                : "No read-only key lookup exists. Preserve idempotency_key for Sky Studio reconciliation; never POST paid creation to find it."
        } else if receipt.jobID == nil, plan == nil {
            fields["recovery_state"] = "interrupted_before_submission"; fields["charged"] = false
            fields["next_step"] = "No server job was admitted. Existing uploaded inputs and the original approval are retained; this key is not replayed. A new operation needs a new quote/approval."
        }
        if plan == nil, !receipt.isFree { fields["local_budget_reconciliation"] = "pending" }
        return fields
    }

    private func finish(_ status: AIJobs.Status, _ message: String) {
        guard let job else { return }
        if status != .done { activity?.issue = message }
        AIJobs.shared.finish(job, status, message: message, detail: .object(payload()))
    }

    private func refresh() async {
        guard !refreshing, let job, job.status != .running else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if receipt.mutation != nil {
                try await readMutation()
                AIJobs.shared.updateDetail(job, payload())
                return
            }
            guard let id = receipt.jobID else { return }
            guard try SkyStudioCharacterJobs.account() == receipt.accountID else { return }
            let key = try await SkyStudioOfficialGenerateTool.readKey()
            let previousRevision = receipt.latest["character"]?["revision"]?.stringValue
            let server = try await SkyStudioAPI().job(id, key: key)
            try await observed(server)
            if server.characterStatus == "ready" {
                invalidateChangedCharacter(previousRevision: previousRevision)
                AIJobs.shared.adoptRecovered(job, message: SkyStudioCharacterJobReport.completionMessage(resuming: plan == nil, previousStatus: job.status.rawValue), detail: .object(payload()))
            } else { AIJobs.shared.updateDetail(job, payload()) }
        } catch { AIJobs.shared.updateDetail(job, ["refresh_error": .string(SkyStudioCharacterError.tool(error).message)]) }
    }

    private func readMutation() async throws {
        guard let mutation = receipt.mutation, try SkyStudioCharacterJobs.account() == receipt.accountID else { throw SkyStudioCharacterReceiptError.conflict }
        let currentKey = try await SkyStudioOfficialGenerateTool.readKey()
        let current = try await SkyStudioAPI().character(mutation.id, key: currentKey)
        receipt.latest["current_character"] = current.json
        try await SkyStudioCharacterJobs.persist(receipt)
    }
}
