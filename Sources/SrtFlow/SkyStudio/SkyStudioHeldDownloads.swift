import Foundation
import SrtFlowMCPKit

// MARK: - Paid results held for Download again, by AI job id (pure registry)
//
// What it covers (2026-11-24, the review of PR #554): every flow that keeps a paid result whose download gave up (or was stopped)
// registers its Download again here under the AI job id and takes it out when Download again starts. The AI's re-ask finds it here even
// after the task row was dismissed: generate_media with the same idempotency_key (film included), or the same request without one
// (SkyStudioGenerationRequests.heldAnswer). A generation whose optional SRT did not download holds a caption-only retry.
// What it does not cover: what is downloaded (each flow), the row and its button (SkyStudioMediaStatus.holdDownload).
// Rules: docs/architecture/sky-studio-jobs.md, "Downloads that the network interrupts".

@MainActor
enum SkyStudioHeldDownloads {
    private static var held: [String: () -> Void] = [:]

    static func hold(_ jobID: String, retry: @escaping () -> Void) { held[jobID] = retry }

    static func release(_ jobID: String) { held[jobID] = nil }

    static func isHeld(_ jobID: String) -> Bool { held[jobID] != nil }

    /// Starts Download again for `jobID` when it holds a paid result; true when it started. It is released as it starts (one press,
    /// one Download again).
    static func retry(_ jobID: String) -> Bool {
        guard let retry = held[jobID] else { return false }
        held[jobID] = nil
        retry()
        return true
    }

    /// What a re-ask answers when it started Download again instead of anything paid.
    static func answer(jobID: String) -> AIToolResult {
        .ok(["status": "downloading_again", "job_id": .string(jobID), "submitted_again": false,
             "next_step": "Sky Studio made this result earlier; SkyCut is downloading the same result again, with no new job and no new charge. Wait with get_job."])
    }
}
