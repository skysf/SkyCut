import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// An official film generation whose download did not finish, through the real flow (2026-11-26, CXD4 on PR #554; docs/bugfixes/
// 2026-11-24-download-lost-connection-no-retry.md): a one-shot public production plan in the project, its film and render, the real
// official authority snapshot and operation, and SkyStudioGenerationRun submitting it to GenerationHTTP (the account verified against
// the fake /me, so this runs after OfficialRecoveryDownloadChecks). Three lost connections hold the paid result, and get_job's next step
// is the film's own: the same film arguments and operation key, or the row; another key is a new, charged generation; a film call
// without a key is refused before anything is sent, never said to be charged (only a direct call of the wording was checked before).

private let filmRunContext: JSONValue = ["environment": "interior", "light_source": "practical", "shot_task": "read_action"]
private let filmRunState: JSONValue = [
    "actor_position": "beside table", "hand": "right", "grip": "holding lantern", "prop_location": "right hand",
    "action_phase": "paused", "spatial_relation": "table ahead", "gaze": "at switch", "screen_direction": "right",
    "lighting": "single lamp", "completed_actions": ["arrive"]
]
private let filmRunJSON: JSONValue = [
    "intent": "original_film", "category": "science_fiction", "footage": "none", "context": filmRunContext,
    "shot": ["id": "shot-a", "index": 0, "total": 1, "revision": 1, "entry": filmRunState, "exit": filmRunState, "actions": []],
    "sound": ["bed_id": "room-air", "music": "restrained pulse", "environment": "continuous ventilation", "foley": "none while still"]
]

@MainActor
func runOfficialFilmRunChecks(_ root: URL) async throws {
    let folder = root.appendingPathComponent("official-film-run", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = OpenProjects.shared.primary
    let before = project.state
    project.documentURL = folder.appendingPathComponent("Film.skycut")
    defer { project.perform { $0 = before } }
    try await withGenerationHTTP {
        await verifyAccountKeepingSlots()
        guard case .success(let key) = await SkyStudioJobKey.key(.silent) else { return require(false, "the fixture key is in SkyCut's cache") }
        let film = try SkyStudioFilm(json: filmRunJSON)
        let prompt = "An original empty room."
        let render: JSONValue = ["kind": "image", "model": "seedream5-flash", "prompt": .string(prompt), "context": filmRunContext]
        project.perform {
            $0.production = FilmProductionState(revision: 1, story: "A synthetic check story.", shots: [
                .init(film: try! JSONEncoder().encode(film), render: try! render.encodedData())
            ], soundCues: [])
        }
        let operationKey = "film-\(UUID().uuidString.prefix(8))"
        let request = SkyStudioJobRequest(kind: "image", model: "seedream5-flash", prompt: prompt, maxCredits: 8, idempotencyKey: operationKey,
                                          film: film, recipePin: "pin-check", seamReview: SkyStudioSeamReview(previous: nil, next: nil))
        let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: SkyStudioAPI())
        let references = SkyStudioReferencePlan(mode: "none", files: [])
        let sources = try SkyStudioOfficialPreparation.sources(references)
        let authority = try await SkyStudioOfficialAuthority.snapshot(request: request, referenceSources: sources, catalog: catalog, project: project)
        let scope = try SkyStudioOfficialGenerateTool.scope(project, key: key)
        let receipt = SkyStudioOfficialReceipt(
            accountID: scope.accountID, projectPath: scope.projectPath, idempotencyKey: operationKey,
            argumentsDigest: String(repeating: "c", count: 64), renderDigest: String(repeating: "d", count: 64), kind: "image",
            modelID: "seedream5-flash", modelTitle: "Seedream 5.0 Flash", params: [:], folder: folder, stem: "film", reservedCredits: 8,
            reservedDay: Date())
        let operation = SkyStudioOfficialOperation(request: request, key: key, scope: scope, recovery: try await SkyStudioOfficialRecovery.create(receipt),
                                                   expiresAt: Date().addingTimeInterval(3600), sources: sources, authority: authority, catalog: catalog)
        guard let model = catalog.model("seedream5-flash", kind: "image"), let quote = SkyStudioQuote(json: ["credits": 8, "typical_seconds": 10]) else {
            return require(false, "the fixture model and quote")
        }
        let run = SkyStudioGenerationRun(
            generation: SkyStudioGeneration(kind: .image, prompt: prompt, params: [:], notes: [], operation: "generate"), model: model,
            quote: quote, references: references, folder: folder, stem: "film", project: project,
            reservation: SkyStudioJobGate.Reservation(credits: 8, day: Date(), dayKey: DailySpendLedger.dayKey(for: Date())),
            idempotencyKey: operationKey, official: operation)
        GenerationHTTP.lock.withLock { GenerationHTTP.drops = 3 }
        let posts = GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs")
        let job = run.start()
        let failed = await finishedJob(job)
        let next = failed["next_step"]?.stringValue ?? ""
        require(failed["status"] == "failed" && failed["code"] == "download_network"
                && GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs") == posts + 1,
                "the official film was submitted once, and its download gave up: \(failed)")
        require(next.contains("the same film arguments and idempotency_key \"\(operationKey)\"")
                && next.contains("A film call with another idempotency_key is a new generation and is charged again")
                && next.contains("one without an idempotency_key is refused before anything is sent")
                && !next.contains("A call without that idempotency_key, or with another one"),
                "the film's next step says a key-less film call is refused, never that it is charged: \(next)")
        require(SkyStudioHeldDownloads.retry(job.id), "its own key path downloads it again")
        let done = await finishedJob(job)
        require(done["status"] == "done" && !SkyStudioHeldDownloads.isHeld(job.id), "then the film is saved: \(done)")
    }
}
