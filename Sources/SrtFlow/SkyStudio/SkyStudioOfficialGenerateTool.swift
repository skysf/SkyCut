import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// generate_media 的官方公开故事入口：显式上传准备 → 精确报价 → 双侧预检 → 同一生成任务。
// 不实现配方、价格表、钱包或另一套生成器；普通请求仍走 SkyStudioGenerateTool 原路径。
@MainActor
enum SkyStudioOfficialGenerateTool {
    static func applies(_ args: AIToolArguments) -> Bool {
        (try? args.bool("prepare_references")) == true || ["film", "prepared_references", "quote_token", "seam_review"].contains(where: args.has)
    }

    struct Plan {
        var generation: SkyStudioGeneration
        var model: SkyStudioModel
        var references: SkyStudioReferencePlan
        var sources: JSONValue
        var catalog: SkyStudioCatalog
        var scope: SkyStudioOfficialPrepared.Scope
        var key: String
        var folder: URL
        var stem: String
        var argumentsDigest: String
        var deviations: [String]
    }

    static func generate(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let prepare = try args.bool("prepare_references") ?? false
        let quoteOnly = try args.bool("quote_only") ?? false
        guard !(prepare && (quoteOnly || ["film", "prepared_references", "quote_token", "seam_review"].contains(where: args.has))) else {
            throw AIToolError("prepare_references prepares the effective render and uploads any original images; omit film, quote_only and quote/review tokens. Quote in a separate call after get_job returns the prepared render.")
        }
        guard let kindText = try args.string("kind"), let kind = SkyStudioGeneration.Kind(rawValue: kindText),
              [.image, .imageToVideo, .textToVideo].contains(kind) else {
            throw AIToolError("Official film preparation supports image, text_to_video or image_to_video only. Music and effects use ordinary generation without film.")
        }
        let operationKey = try args.string("idempotency_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? UUID().uuidString.lowercased()
        if !prepare && !quoteOnly && !args.has("idempotency_key") { throw AIToolError("Official submission requires a stable idempotency_key chosen before sending, so a lost answer can recover the original operation.") }
        let projectGeneration = project.documentGeneration, projectPath = project.documentURL?.standardizedFileURL.path
        let key = try await readKey()
        guard project.documentGeneration == projectGeneration, project.documentURL?.standardizedFileURL.path == projectPath,
              OpenProjects.shared.all.contains(where: { $0 === project }) else {
            throw AIToolError("The project changed or closed while checking its account. Nothing was prepared, reserved or submitted; read the current project first.")
        }
        let scope = try scope(project, key: key)
        let stage = (prepare ? "official-preparation:" : "official-submission:") + scope.accountID
        let digest = SkyStudioOfficialPrepared.argumentsDigest(args.raw)
        if !quoteOnly {
            let identity: JSONValue = ["arguments": .string(digest), "account": .string(scope.accountID),
                                       "project": .string(scope.projectPath), "generation": prepare ? .number(Double(scope.projectGeneration)) : .null]
            if let prior = try SkyStudioGenerationRequests.begin(operationKey, identity: identity, scope: stage) { return prior }
        }
        defer { if !quoteOnly { SkyStudioGenerationRequests.abandonPreparation(operationKey, scope: stage) } }
        if !prepare && !quoteOnly,
           let prior = try await SkyStudioOfficialRecovery.resume(key: operationKey, argumentsDigest: digest, scope: scope, apiKey: key, project: project) {
            SkyStudioGenerationRequests.complete(operationKey, result: prior, scope: stage)
            return prior
        }
        let film = try args.raw["film"].map(SkyStudioFilm.init(json:))
        guard prepare || film != nil else { throw AIToolError("Official quotes and submissions require the complete public film declaration.") }
        let picks = try SkyStudioReferenceFiles.picks(args, kind: kind)
        guard picks.webURL == nil, picks.files.allSatisfy({ $0.type == "image" }) else {
            throw AIToolError("Official no-footage shots accept original image references only. Do not upload research frames, video, audio, documents or pages.")
        }
        if let ask = try AIWorkspace.shared.confirmReading(picks.files.map(\.file), verb: "prepare original images for Sky Studio", args: args, project: project) { return ask }
        let plan = try await makePlan(args, kind: kind, picks: picks, scope: scope, key: key, digest: digest, project: project)
        try await validateScope(plan.scope, project: project, key: key)
        if prepare {
            let response = try SkyStudioOfficialPreparation.start(generation: plan.generation, plan: plan.references, model: plan.model, scope: scope,
                key: key, operationKey: operationKey, project: project)
            SkyStudioGenerationRequests.complete(operationKey, result: response, scope: stage)
            return response
        }
        let request = try preparedRequest(plan, args: args, film: film!)
        let identity: JSONValue = ["request": request.quoteBody, "sources": plan.sources,
                                  "folder": .string(plan.folder.path), "stem": .string(plan.stem), "arguments": .string(digest)]
        if quoteOnly { return try await quote(plan, request: request, identity: identity, project: project) }
        let response = try await submit(plan, request: request, identity: identity, args: args, operationKey: operationKey, project: project)
        SkyStudioGenerationRequests.complete(operationKey, result: response, scope: stage)
        return response
    }

    private static func makePlan(_ args: AIToolArguments, kind: SkyStudioGeneration.Kind, picks: SkyStudioReferenceFiles.Picks,
                                 scope: SkyStudioOfficialPrepared.Scope, key: String, digest: String, project: VideoEditProject) async throws -> Plan {
        let ask = try SkyStudioGenerationControls.ask(args)
        guard ask.operation == "generate" else { throw AIToolError("Official film does not support background removal or lip sync.") }
        let prompt = try args.string("prompt") ?? ""
        let references = try await SkyStudioReferenceFiles.measure(picks, project: project)
        let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key)
        let requested = try args.string("model")
        let imageContext = try args.choice("image_context", from: ["asian", "other"]) ?? "other"
        let quality = try args.choice("quality", from: ["standard", "highest"]) ?? "standard"
        guard let model = SkyStudioModelPolicy.select(catalog: catalog, kind: kind.rawValue, requested: requested, imageContext: imageContext, quality: quality,
            accepts: { SkyStudioModelPolicy.problem(model: $0, ask: ask, references: references) == nil
                && SkyStudioGenerationControls.problem(model: $0, ask: ask, prompt: prompt, references: references) == nil }) else {
            throw AIToolError("No offered model accepts this complete official shot request. Read get_status models=true; references and duration will not be dropped to make it fit.")
        }
        let canvas = project.renderSize
        var generation = SkyStudioGeneration.make(kind, prompt: prompt, ask: ask, canvas: canvas.width / max(canvas.height, 1),
            frame: references.firstFrame.flatMap(SkyStudioGenerationFrame.aspect(of:)), model: model, inputMode: references.mode, references: references)
        // 官方计价把视频首尾帧的角色与多参考数量分开；普通报价路径保持原样。
        if kind.isVideo && references.mode == "frames" { generation.params["reference_image_count"] = 0 }
        let stem = ExportFileName.stem(from: try args.string("name").map { AIVoiceoverPlacement.fileStem($0) } ?? AIVoiceoverPlacement.fileStem(prompt),
                                      droppingExtension: "", fallback: kind == .image ? "Image" : "Video")
        var deviations = AIDraftPolicy.deviations(generation, model: model)
        if quality == "highest" { deviations.append("Highest-quality model selection exceeds the low-cost draft policy.") }
        if let requested, let preferred = SkyStudioModelPolicy.select(catalog: catalog, kind: kind.rawValue, requested: nil, imageContext: imageContext,
            accepts: { SkyStudioModelPolicy.problem(model: $0, ask: ask, references: references) == nil
                && SkyStudioGenerationControls.problem(model: $0, ask: ask, prompt: prompt, references: references) == nil }), preferred.id != requested {
            deviations.append("The selected model differs from the preferred draft model; this exact official quote requires approval under request mode.")
        }
        return Plan(generation: generation, model: model, references: references, sources: try SkyStudioOfficialPreparation.sources(references),
                    catalog: catalog, scope: scope, key: key, folder: AIWorkspace.shared.outputFolder(.generated, project: project), stem: stem, argumentsDigest: digest, deviations: deviations)
    }

    private static func preparedRequest(_ plan: Plan, args: AIToolArguments, film: SkyStudioFilm) throws -> SkyStudioJobRequest {
        var request = plan.generation.job(model: plan.model.id)
        request.film = film
        if !plan.references.files.isEmpty {
            guard let token = try args.string("prepared_references") else {
                throw AIToolError("Official quotes bind actual uploaded images. First call prepare_references=true, then get_job for prepared_references. quote_only has not uploaded or reserved anything.")
            }
            let assets = try SkyStudioOfficialPrepared.shared.assets(token, scope: plan.scope, sources: plan.sources)
            request.inputs = assets.inputs; request.references = assets.references
        } else if args.has("prepared_references") {
            throw AIToolError("Repeat the prepared image paths and roles with prepared_references; do not attach a token to a text-only request.")
        }
        try SkyStudioOfficialRequest.validate(request, submitting: false)
        try validateNeighbors(film, catalog: plan.catalog)
        return request
    }

    /// 只核对公开模型目录里的名字；参数具体语义与私有支持范围仍由官方 /quote 严格决定。
    private static func validateNeighbors(_ film: SkyStudioFilm, catalog: SkyStudioCatalog) throws {
        for neighbor in [film.previous, film.next].compactMap({ $0 }) {
            let render = neighbor.render
            guard let model = catalog.model(render.model, kind: render.kind.rawValue), model.operation != "remove_background" else {
                throw AIToolError("Neighbor \(neighbor.shotID) must name an offered public model for its kind.")
            }
            var allowed = Set(model.params.keys).union(["reference_image_count", "reference_video_count", "reference_video_seconds"])
            if model.params["duration_values"] != nil || model.params["smart_duration"] != nil { allowed.insert("duration") }
            allowed.subtract(["duration_values", "smart_duration"])
            let unknown = Set(render.params.keys).subtracting(allowed)
            guard unknown.isEmpty else { throw AIToolError("Neighbor \(neighbor.shotID) has parameters absent from its public model catalog: \(unknown.sorted().joined(separator: ", ")).") }
        }
    }

    private static func quote(_ plan: Plan, request: SkyStudioJobRequest, identity: JSONValue, project: VideoEditProject) async throws -> AIToolResult {
        let quoted: SkyStudioQuote
        do { quoted = try await SkyStudioAPI().quote(request, key: plan.key) }
        catch let failure as SkyStudioFailure {
            throw AIToolError("Official quote failed: " + SkyStudioJobError.request(failure).message
                + " No generation, upload or credit reservation was started by this quote; no ordinary-generation fallback was used.")
        }
        try await validateScope(plan.scope, project: project, key: plan.key)
        guard try SkyStudioOfficialPreparation.sources(plan.references) == plan.sources else { throw AIToolError("Reference files changed while quoting. Prepare and quote the actual files again; nothing was reserved.") }
        let token = try SkyStudioOfficialPrepared.shared.rememberQuote(scope: plan.scope, identity: identity, request: request, quote: quoted)
        let official = quoted.officialRecipe!
        return .ok(["status": "quoted", "quote_token": .string(token), "seam_review": official.seamReview.json,
                    "official_recipe": ["expires_at": .string(ISO8601DateFormatter().string(from: official.expiresAt)), "preflight_only": true],
                    "model_id": .string(plan.model.id), "params": .object(plan.generation.params), "credits": .number(quoted.credits), "charged": false, "uploaded": false,
                    "approval_reasons": .array(deviations(plan).map(JSONValue.string)),
                    "next_step": "Review the declared current shot, both adjacent states/renders/cuts and sound bed. Submit the unchanged request with quote_only=false, quote_token and these exact seam_review fingerprints. Preflight is not proof of generated picture or sound continuity. Do not mechanically reuse an old review after any change."])
    }

    private static func submit(_ plan: Plan, request: SkyStudioJobRequest, identity: JSONValue, args: AIToolArguments,
                               operationKey: String, project: VideoEditProject) async throws -> AIToolResult {
        guard let token = try args.string("quote_token"), let reviewJSON = args.raw["seam_review"] else {
            throw AIToolError("First obtain an official quote with quote_only=true, review each adjacent seam and then pass quote_token and seam_review. Nothing was reserved or submitted.")
        }
        let review = try SkyStudioSeamReview(json: reviewJSON)
        let cached = try SkyStudioOfficialPrepared.shared.reviewedQuote(token, scope: plan.scope, identity: identity, review: review)
        _ = try await SkyStudioGeneratedVideo.engine()
        try await validateScope(plan.scope, project: project, key: plan.key)
        guard try SkyStudioOfficialPreparation.sources(plan.references) == plan.sources else { throw AIToolError("Original reference files changed before submission. Obtain fresh preparation and quote; no credits were reserved.") }
        // 最后一次 await 之后重新检查有效期与完整绑定，先于预算预留。
        var exact = try SkyStudioOfficialPrepared.shared.reviewedQuote(token, scope: plan.scope, identity: identity, review: review).request
        exact.idempotencyKey = operationKey
        let approval = SkyStudioApproval.identity(job: exact, credits: cached.quote.credits,
            context: ["sources": plan.sources, "destination": .string(plan.folder.path + "/" + plan.stem), "project": .string(plan.scope.projectPath)])
        let reservation: SkyStudioJobGate.Reservation
        switch try SkyStudioJobGate.decide(credits: cached.quote.credits, summary: plan.generation.summary(modelTitle: plan.model.title),
            identity: approval, args: args, reason: deviations(plan).isEmpty ? nil : deviations(plan).joined(separator: " "),
            project: plan.scope.accountID + ":" + plan.scope.projectPath, profile: "official:" + SkyStudioOfficialPrepared.digest(.string(approval))) {
        case .needsConfirmation(let question): return question
        case .reserved(let value): reservation = value
        }
        do {
            try SkyStudioOfficialPrepared.shared.claim(token, for: operationKey)
            let receipt = SkyStudioOfficialReceipt(accountID: plan.scope.accountID, projectPath: plan.scope.projectPath,
                idempotencyKey: operationKey, argumentsDigest: plan.argumentsDigest, renderDigest: SkyStudioOfficialPrepared.digest(exact.quoteBody),
                kind: exact.kind, modelID: exact.model, modelTitle: plan.model.title, params: exact.params, folder: plan.folder,
                stem: plan.stem, reservedCredits: reservation.credits, reservedDay: reservation.day)
            let recovery = try await SkyStudioOfficialRecovery.create(receipt)
            let operation = SkyStudioOfficialOperation(request: exact, key: plan.key, scope: plan.scope, recovery: recovery,
                                                       expiresAt: cached.quote.officialRecipe!.expiresAt, sources: plan.sources)
            let run = SkyStudioGenerationRun(generation: plan.generation, model: plan.model, quote: cached.quote, references: plan.references,
                folder: plan.folder, stem: plan.stem, project: project, reservation: reservation, idempotencyKey: operationKey, official: operation)
            let job = run.start()
            return .ok(["status": "started", "job_id": .string(job.id), "model_id": .string(plan.model.id), "kind": .string(exact.kind),
                        "idempotency_key": .string(operationKey), "credits": .number(cached.quote.credits), "params": .object(exact.params),
                        "official_recipe": ["preflight_reviewed": true, "output_reviewed": false],
                        "billing_note": .string(SkyStudioBilling.policyMessage),
                        "next_step": "Wait with get_job. Inspect the generated start, turns and both actual cut seams before accepting; retain the original operation key after any failure. Quote review is not output acceptance."])
        } catch {
            var held = SkyStudioHeldCredits(reservation); held.refund()
            throw error
        }
    }

    private static func deviations(_ plan: Plan) -> [String] {
        // 官方项目批准绑定完整镜头身份；不复用普通模型规格的旧项目批准。
        plan.deviations
    }

    static func readKey() async throws -> String {
        switch await SkyStudioJobKey.key(.silent) {
        case .success(let key): return key
        case .failure(let failure): throw AIToolError(failure.message)
        }
    }

    static func scope(_ project: VideoEditProject, key: String) throws -> SkyStudioOfficialPrepared.Scope {
        guard OpenProjects.shared.all.contains(where: { $0 === project }), let path = project.documentURL?.standardizedFileURL.path,
              let account = SkyStudioAccount.shared.stored?.me.account.id, !account.isEmpty else {
            throw AIToolError("Official film work requires a saved project and a verified Sky Studio account. Create or save your own background project first.")
        }
        return .init(accountID: account, keyDigest: SkyStudioOfficialPrepared.digest(.string(key)), projectPath: path, projectGeneration: project.documentGeneration)
    }

    static func validateScope(_ expected: SkyStudioOfficialPrepared.Scope, project: VideoEditProject, key: String) async throws {
        let currentKey = try await readKey()
        guard currentKey == key, try scope(project, key: currentKey) == expected else {
            throw AIToolError("The Sky Studio account/key or project changed during preparation. Nothing new was submitted; read the current project and quote again.")
        }
    }
}
