import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The official recovery whose output download did not finish (2026-11-25 / 26, the narrowed round and CXD3 on PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md), through generate_media's own entry (film arguments and the
// operation's idempotency_key), with the real SkyStudioOfficialRecoveryRun and its receipt against GenerationHTTP, POSTs counted (the
// receipt goes to this run's own Application Support folder, which Main and the script remove; the account is verified against the
// fake /me, so this runs after PaidToolEntryChecks marked a key on it):
// - the operation's key starts its recovery; three lost connections: failed with download_network; the next step names that key;
//   held on its row;
// - the same key again while the original job answers 503, and its download fails again: still held, with its button (it was once lost
//   after one 503, and the same key then only returned the cached `recovering`, with no GET);
// - the same key once more downloads it: the output is saved; nothing was ever quoted or submitted;
// - a film generation's next step says a film call without a key is refused, never that it is charged again.

@MainActor
func runOfficialRecoveryDownloadChecks(_ root: URL) async throws {
    if !SkyStudioAccount.shared.hasKey { SkyStudioAccount.shared.requireKeychainPermission() }
    let folder = root.appendingPathComponent("official-recovery", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = OpenProjects.shared.primary
    project.documentURL = folder.appendingPathComponent("Official.skycut")
    try await withGenerationHTTP {
        await verifyAccountKeepingSlots()
        guard let account = SkyStudioAccount.shared.stored?.me.account.id else { return require(false, "the account is verified (/me)") }
        let key = "official-\(UUID().uuidString.prefix(8))"
        let args: JSONValue = ["kind": "image", "prompt": "a cabin in snow", "film": [:], "idempotency_key": .string(key)]
        let receipt = SkyStudioOfficialReceipt(
            accountID: account, projectPath: folder.appendingPathComponent("Official.skycut").path, idempotencyKey: key,
            argumentsDigest: SkyStudioOfficialPrepared.argumentsDigest(args), renderDigest: String(repeating: "b", count: 64), kind: "image",
            modelID: "seedream5-flash", modelTitle: "Seedream 5.0 Flash", params: [:], folder: folder, stem: "film", reservedCredits: 8,
            reservedDay: Date())
        let recovery = try await SkyStudioOfficialRecovery.create(receipt)
        try await recovery.received(SkyStudioJobStatus(jobID: "film-1", state: .running))
        func ask() async throws -> AIToolResult { try await SkyStudioGenerateTool.generate(AIToolArguments(args), project) }

        // The operation's key: its recovery, whose download gives up after three lost connections.
        GenerationHTTP.lock.withLock { GenerationHTTP.drops = 3 }
        let answer = try await ask()
        guard answer.payload["status"] == "recovering", let id = answer.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else {
            return require(false, "the operation's key starts its recovery: \(answer.payload)")
        }
        let failed = await finishedJob(job)
        guard let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == id }) else {
            return require(false, "the failed recovery keeps its row")
        }
        require(failed["status"] == "failed" && failed["code"] == "download_network" && row.retryDownload != nil && SkyStudioHeldDownloads.isHeld(id)
                && (failed["next_step"]?.stringValue ?? "").contains("idempotency_key \"\(key)\""),
                "three lost connections: held on its row and for the operation's own key: \(failed)")

        // The same key while the original job answers 503 (and the download fails again): still held.
        GenerationHTTP.lock.withLock { GenerationHTTP.jobReadFailures = 1; GenerationHTTP.drops = 3 }
        let retried = try await ask()
        require(retried.payload["status"] == "downloading_again" && retried.payload["job_id"]?.stringValue == id && job.status == .running,
                "the same key downloads the held output again: \(retried.payload)")
        let again = await finishedJob(job)
        require(GenerationHTTP.lock.withLock { GenerationHTTP.jobReadFailures } == 0, "the original job answered 503 once")
        require(again["code"] == "download_network" && row.retryDownload != nil && SkyStudioHeldDownloads.isHeld(id),
                "a 503 while reading the original job does not lose the way back: still held with its button: \(again)")

        // The same key once more: the output is saved under the same job id; nothing quoted or submitted, ever.
        let reasked = try await ask()
        require(reasked.payload["status"] == "downloading_again" && reasked.payload["job_id"]?.stringValue == id,
                "the operation's own key reaches its held recovery: \(reasked.payload)")
        let done = await finishedJob(job)
        let file = done["file"]?.stringValue.map(URL.init(fileURLWithPath:))
        require(done["status"] == "done" && file.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.image && !SkyStudioHeldDownloads.isHeld(id),
                "the output is saved under the same job id, and nothing is held any more: \(done)")
        require(GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs") == 0
                && GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/quote") == 0,
                "nothing was ever quoted or submitted")
    }

    // A film generation's own held result: the next step never says a film call without a key is charged (it is refused).
    let film = SkyStudioGenerationRun.downloadRetry(key: "film-key", film: true)
    require(film.contains("idempotency_key \"film-key\"") && film.contains("one without an idempotency_key is refused before anything is sent")
            && !film.contains("without that idempotency_key, or with another one"),
            "a film's next step says what a key-less film call does: \(film)")
    let ordinary = SkyStudioGenerationRun.downloadRetry(key: "k", film: false)
    require(ordinary.contains("A call without that idempotency_key, or with another one, is a new generation and is charged again"),
            "an ordinary generation's next step says a key-less call is charged again: \(ordinary)")
}

/// The account verified against the fake /me, keeping the shared job slots the earlier checks arranged. LibraryRestartChecks leaves
/// three voice library jobs parked mid-follow as if SkyCut had quit (their slots would go with the process) and opens three more
/// slots for them; adopting /me's 3 again would leave every later job waiting for a slot. No production job keeps a slot once its
/// Sky Studio job has ended (Main checks that the download checks give theirs back).
@MainActor
func verifyAccountKeepingSlots() async {
    let limits = SkyStudioJobSlots.shared.snapshot.limits
    await SkyStudioAccount.shared.refresh()
    SkyStudioJobSlots.shared.adopt(limits)
}
