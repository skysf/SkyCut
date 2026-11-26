import Foundation
import SrtFlowMCPKit

// MARK: - Paid results held for Download again, by AI job id (pure registry)
//
// What it covers (2026-11-24, the reviews of PR #554): a generation (official ones and the official recovery included) whose paid
// result did not come down registers its Download again here under its own AI job id. The entry stays until a download of it succeeds
// (`release`): starting Download again, or a Download again that fails again, keeps it. Only the job's own identity reaches it:
// generate_media called again with that job's idempotency_key (SkyStudioGenerationRequests.heldAnswer(for:) reads the job id from the
// key's own cached answer), and the row's button. A call without that key, or with another one, is a new request and a new paid job
// (user, 2026-11-25: an identical paid request sent again is a deliberate new version); nothing here looks requests up by their
// parameters. A generation whose optional SRT did not download holds a caption-only retry the same way.
// What it does not cover: what is downloaded (each flow, which also refuses to start a second Download again while one runs), the row
// and its button (SkyStudioMediaStatus.holdDownload).
// Rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

@MainActor
enum SkyStudioHeldDownloads {
    private static var held: [String: () -> Void] = [:]

    static func hold(_ jobID: String, retry: @escaping () -> Void) { held[jobID] = retry }

    /// Its result came down: nothing is held for it any more.
    static func release(_ jobID: String) { held[jobID] = nil }

    static func isHeld(_ jobID: String) -> Bool { held[jobID] != nil }

    /// Asks `jobID` to download its held result again; true when it holds one. The entry stays until that download succeeds; a flow
    /// that is already downloading it again starts nothing more.
    static func retry(_ jobID: String) -> Bool {
        guard let retry = held[jobID] else { return false }
        retry()
        return true
    }

    /// What a re-ask with the job's own idempotency_key answers when that job holds a paid result.
    static func answer(jobID: String) -> AIToolResult {
        .ok(["status": "downloading_again", "job_id": .string(jobID), "submitted_again": false,
             "next_step": .string("Sky Studio made this result earlier; SkyCut is downloading the same result again under this job id, "
                + "with no new job and no new charge. Wait with get_job.")])
    }
}
