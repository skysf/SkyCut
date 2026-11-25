import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The official recovery whose output download did not finish (2026-11-25, the narrowed round of PR #554; docs/bugfixes/2026-11-24-
// download-lost-connection-no-retry.md), with the real SkyStudioOfficialRecoveryRun and its receipt against GenerationHTTP (the receipt
// goes to this run's own Application Support folder, which Main and the script remove):
// - three lost connections: failed with download_network; the next step names the operation's own key; held on its row;
// - Download again while the original job answers 503, and its download fails again: still held, with its button (it was once lost
//   after one 503, and the same key then only returned the cached `recovering`, with no GET);
// - the operation's own key (its cached `recovering` answer) then downloads it: the output is saved; nothing was ever submitted.

@MainActor
func runOfficialRecoveryDownloadChecks(_ root: URL) async throws {
    let folder = root.appendingPathComponent("official-recovery", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = OpenProjects.shared.primary
    project.documentURL = folder.appendingPathComponent("Official.skycut")
    try await withGenerationHTTP {
        let key = "official-\(UUID().uuidString.prefix(8))"
        let receipt = SkyStudioOfficialReceipt(
            accountID: "acct-check", projectPath: folder.appendingPathComponent("Official.skycut").path, idempotencyKey: key,
            argumentsDigest: String(repeating: "a", count: 64), renderDigest: String(repeating: "b", count: 64), kind: "image",
            modelID: "seedream5-flash", modelTitle: "Seedream 5.0 Flash", params: [:], folder: folder, stem: "film", reservedCredits: 8,
            reservedDay: Date())
        let recovery = try await SkyStudioOfficialRecovery.create(receipt)
        try await recovery.received(SkyStudioJobStatus(jobID: "film-1", state: .running))
        GenerationHTTP.lock.withLock { GenerationHTTP.drops = 3 }
        let answer = SkyStudioOfficialRecoveryRun(recovery: recovery, key: "sk-" + String(repeating: "G", count: 43), project: project).start()
        guard let id = answer.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else {
            return require(false, "the official recovery starts: \(answer.payload)")
        }
        let failed = await finishedJob(job)
        guard let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == id }) else {
            return require(false, "the failed recovery keeps its row")
        }
        require(failed["status"] == "failed" && failed["code"] == "download_network" && row.retryDownload != nil && SkyStudioHeldDownloads.isHeld(id)
                && (failed["next_step"]?.stringValue ?? "").contains("idempotency_key \"\(key)\""),
                "three lost connections: held on its row and for the operation's own key: \(failed)")

        // Download again while the original job answers 503 (and the download fails again): still held.
        GenerationHTTP.lock.withLock { GenerationHTTP.jobReadFailures = 1; GenerationHTTP.drops = 3 }
        require(SkyStudioHeldDownloads.retry(id) && job.status == .running, "Download again runs the recovery again")
        let again = await finishedJob(job)
        require(GenerationHTTP.lock.withLock { GenerationHTTP.jobReadFailures } == 0, "the original job answered 503 once")
        require(again["code"] == "download_network" && row.retryDownload != nil && SkyStudioHeldDownloads.isHeld(id),
                "a 503 while reading the original job does not lose the way back: still held with its button: \(again)")

        // The operation's own key: its cached `recovering` answer downloads it.
        let reasked = SkyStudioGenerationRequests.heldAnswer(for: answer)
        require(reasked?.payload["status"] == "downloading_again" && reasked?.payload["job_id"]?.stringValue == id,
                "the operation's own key reaches its held recovery: \(String(describing: reasked?.payload))")
        let done = await finishedJob(job)
        let file = done["file"]?.stringValue.map(URL.init(fileURLWithPath:))
        require(done["status"] == "done" && file.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.image && !SkyStudioHeldDownloads.isHeld(id),
                "the output is saved under the same job id, and nothing is held any more: \(done)")
        require(GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs") == 0, "nothing was ever submitted")
    }
}
