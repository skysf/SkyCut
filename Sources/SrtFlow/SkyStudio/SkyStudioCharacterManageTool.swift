import Foundation
import SrtFlowMCPKit

// 唯一角色库写工具：按动作共用计划、权限、付费闸与持久原单；不往时间线自动放角色图。
@MainActor
enum SkyStudioCharacterManageTool {
    static func run(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        do { return try await perform(args, project) }
        catch { throw SkyStudioCharacterError.tool(error) }
    }

    private static func perform(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let action = try SkyStudioCharacterPlan.action(args)
        if let resume = try args.string("resume") {
            let keys = Set(args.raw.objectValue?.filter { !$0.value.isNull }.map(\.key) ?? [])
            guard keys.isSubset(of: ["action", "resume", "project"]), let receipt = try await SkyStudioCharacterJobs.read(resume),
                  receipt.operation == "character_" + (action == .importViews ? "import" : action.rawValue),
                  let job = try await SkyStudioCharacterJobs.restore(resume, project: project, explicitFreeImport: action == .importViews) else {
                throw AIToolError("Resume requires only action=create/import/headshot/replace_view and the original stable job_id in resume; no new inputs or payment are accepted.")
            }
            return SkyStudioCharacterJobs.response(job, receipt: receipt)
        }
        let account = try SkyStudioCharacterJobs.account()
        let key = try await SkyStudioOfficialGenerateTool.readKey(), stamp = SkyStudioCharacterAccess.stamp(key)
        let quoteOnly = try args.bool("quote_only") ?? false
        let isJob = [.create, .headshot, .importViews, .replaceView].contains(action)
        let operationKey = try args.string("idempotency_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (quoteOnly || !isJob ? UUID().uuidString.lowercased() : "")
        guard !isJob || !operationKey.isEmpty, operationKey.utf16.count <= 128 else { throw AIToolError("Choose a stable idempotency_key (1–128 characters) before submitting create/import/headshot/replace_view; keep it after lost answers.") }
        let localID = "character-" + SkyStudioReceiptFile.identifier(accountID: account, key: operationKey)
        let arguments = SkyStudioCharacterReceipt.arguments(args)
        if isJob && !quoteOnly, let prior = try await SkyStudioCharacterJobs.read(localID) {
            guard prior.accountID == account, prior.argumentsDigest == arguments else { throw AIToolError("This idempotency_key belongs to different Character inputs. Query its original job; a new operation needs a new key and approval.") }
            let job: AIJobs.Job
            if let current = AIJobs.shared.job(localID) { job = current }
            else { job = try await SkyStudioCharacterJobs.restore(localID, project: project)! }
            return SkyStudioCharacterJobs.response(job, receipt: prior)
        }
        let scope = "characters:" + account
        if isJob && !quoteOnly {
            if let cached = try SkyStudioGenerationRequests.begin(operationKey, identity: .string(arguments), scope: scope) { return cached }
        }
        defer { if isJob && !quoteOnly { SkyStudioGenerationRequests.abandonPreparation(operationKey, scope: scope) } }
        let paths = try SkyStudioCharacterPlan.paths(args, resolve: { AIWorkspace.shared.resolve($0) })
        if let question = try AIWorkspace.shared.confirmReading(paths.map(\.url), verb: "send to Sky Studio", args: args, project: project) { return question }
        let files = try await SkyStudioCharacterWorkflow.measure(paths, creatingPhoto: action == .create)
        let capabilities = try await SkyStudioCharacterCache.shared.capabilities(key: key)
        let saved: SkyStudioCharacter?
        if action == .headshot || action == .delete || action == .replaceView { saved = try await SkyStudioCharacterCache.shared.character(args.requiredString("character_id"), key: key) }
        else { saved = nil }
        var plan = try SkyStudioCharacterPlan.make(args, capabilities: capabilities, saved: saved, files: files)
        let workflow = SkyStudioCharacterWorkflow(api: SkyStudioAPI(), key: key)
        if isJob { plan = try await workflow.quote(plan) }
        guard SkyStudioCharacterAccess.stamp(key) == stamp, try SkyStudioCharacterJobs.account() == account else { throw SkyStudioCharacterError.changed }
        if quoteOnly {
            return .ok(["status": "quoted", "credits": .number(plan.quote!.credits), "model_id": plan.quote!.model.map(JSONValue.string) ?? .null,
                "effective_params": .object(plan.quote!.effectiveParams), "character_usage": plan.quote!.characterUsage?.json ?? .null,
                "billing_policy": plan.quote!.billingPolicy ?? capabilities.json["billing_policy"] ?? .null,
                "charged": false, "uploaded": false,
                "next_step": "Present this exact Character specification and quote. Submit with quote_only=false and a stable idempotency_key under the current approval mode and hard daily budget. No Character or upload was created by the quote."])
        }
        let identities = try files.map { try SkyStudioApproval.file($0.file) }
        if let mutation = plan.mutation, action != .replaceView {
            if action == .delete {
                guard saved?.revision == mutation.body["character_revision"]?.stringValue else { throw SkyStudioCharacterError.changed }
                if let question = try AIFileTools.confirmCharacterDeletion(id: mutation.id, revision: saved!.revision, accountStamp: stamp, args: args) { return question }
            }
            let result = try await workflow.api.mutateCharacter(mutation, key: key)
            if action == .delete { SkyStudioCharacterAccess.invalidateLibrary(characterID: mutation.id) }
            else { SkyStudioCharacterCache.shared.forget() }
            var fields = result.objectValue ?? [:]
            fields["credits_charged"] = 0
            fields["notification"] = "Notify the user of this free library write in their conversation language. It does not modify the timeline or refund earlier successful generation."
            return .ok(.object(fields))
        }
        if plan.job == nil { plan.job = SkyStudioJobRequest(kind: "image", model: "") }
        plan.job!.idempotencyKey = operationKey
        let credits = plan.quote?.credits ?? 0
        let mutationIdentity = try plan.mutation.map { try JSONValue.decode(JSONEncoder().encode($0)) } ?? .null
        let identity = SkyStudioApproval.identity(job: plan.job!, credits: credits,
            context: ["files": .array(identities), "account_stamp": .string(stamp), "mutation": mutationIdentity, "character_usage": plan.quote?.characterUsage?.json ?? .null])
        let reservation: SkyStudioJobGate.Reservation?
        if plan.isPaid {
            switch try SkyStudioJobGate.decide(credits: plan.quote!.credits, summary: plan.title, identity: identity, args: args,
                reason: "Approve this exact paid Character library operation, model and resolution.",
                overrides: [.init(reason: "Approve this exact paid Character library operation, model and resolution.", names: AIOverrideQuote.characterNames)],
                project: account,
                profile: "character-native:" + SkyStudioCharacterCache.digest(identity)) {
            case .needsConfirmation(let question): return question
            case .reserved(let approved): reservation = approved
            }
        } else { reservation = nil }
        let receipt = SkyStudioCharacterReceipt(accountID: account, idempotencyKey: operationKey, argumentsDigest: arguments,
            approvalIdentity: SkyStudioCharacterCache.digest(identity), request: plan.job!, mutation: plan.mutation, reservedCredits: credits,
            reservedDay: reservation?.day ?? Date(), characterID: plan.job?.character?.id ?? plan.mutation?.id)
        do {
            try await SkyStudioCharacterJobs.persist(receipt, creating: true)
            let job = SkyStudioCharacterRun(receipt: receipt, key: key, project: project, plan: plan, approvedFiles: identities, reservation: reservation).start()
            let response = SkyStudioCharacterJobs.response(job, receipt: receipt)
            SkyStudioGenerationRequests.complete(operationKey, result: response, scope: scope)
            return response
        } catch {
            if let reservation { var held = SkyStudioHeldCredits(reservation); held.refund() }
            throw error
        }
    }
}
