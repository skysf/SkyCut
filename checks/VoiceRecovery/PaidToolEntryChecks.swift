import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Paid tools asked again after a paid result did not come down (2026-11-25, the narrowed round of PR #554; docs/bugfixes/2026-11-24-
// download-lost-connection-no-retry.md; user, 2026-11-25: an identical paid request sent again is a deliberate new version), through
// the tool entries that submit orders, with POSTs counted at the fake servers (the round before only called its lookup functions):
// - generate_media: after a held failure at 16:9, the canvas turned to 9:16 without the key is a new job asking for 9:16, never the
//   held result; the same arguments with another key are exactly one new POST and a new job, the held one still held; the key SkyCut
//   returned, with the same arguments and the row dismissed, sends no POST and saves the held job's identical file; the same arguments
//   without the key are exactly one new POST and a new job;
// - generate_media with a key sent with spaces: the receipt's key (trimmed), sent back, is that same request (it was once refused as
//   other inputs, CXD3); an output folder a file stands in for: held (download_not_saved, the row's Download again, no file GET), and
//   once the folder is fixed the job's own key downloads it with no new POST (it once lost the way back);
// - generate_media into an output folder SkyCut may not write (the real write error): held as download_not_saved after its one GET,
//   and once the folder is writable the job's own key saves it with no new POST;
// - upscale_clip: project B asking for project A's source after A's upscale was held is a new job for B: B's clip replaced, A's left
//   as it was, A's result still held on its own row; an upscale saved while its bill is under review keeps the 75 reserved and says
//   the bill is pending, and get_job reads the original job until it is final, then the books and the receipt say 72 (CXD4).
// Both tools need a key on the account (SkyStudioAccount.hasKey), so these run last: the account marks the key as present the way the
// App does when macOS asks for the keychain's permission (the key itself comes from SkyCut's in-memory cache; the keychain is never
// read). That writes the MCP provider marker into this run's own Application Support folder, which Main and the script remove.

@MainActor
func runPaidToolEntryChecks(_ root: URL) async throws {
    if !SkyStudioAccount.shared.hasKey { SkyStudioAccount.shared.requireKeychainPermission() }
    let mode = AIAccessStore.shared.mode
    AIAccessStore.shared.setMode(.full)   // paid requests within the daily limit start without a confirmation question
    defer { AIAccessStore.shared.setMode(mode) }
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    try await generateMediaEntryChecks(root.appendingPathComponent("paid-generate", isDirectory: true))
    try await generateMediaKeyAndFolderChecks(root.appendingPathComponent("paid-generate-key", isDirectory: true))
    try await upscaleClipEntryChecks(root.appendingPathComponent("paid-upscale", isDirectory: true))
    try await upscaleBillUnderReview(root.appendingPathComponent("paid-upscale-review", isDirectory: true))
}

@MainActor
private func generateMediaEntryChecks(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let project = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("Generate.skycut"), placement: .background) else {
        return require(false, "a project for generate_media")
    }
    project.setCanvasRatio(.wide16x9)
    try await withGenerationHTTP {
        let posts = { GenerationHTTP.bodies("POST", "/api/skycut/v1/jobs") }
        let args: JSONValue = ["kind": "image", "prompt": "a cabin in snow"]
        GenerationHTTP.lock.withLock { GenerationHTTP.drops = 3 }
        let first = try await SkyStudioGenerateTool.generate(AIToolArguments(args), project)
        guard let id = first.payload["job_id"]?.stringValue, let key = first.payload["idempotency_key"]?.stringValue,
              let job = AIJobs.shared.job(id) else { return require(false, "generate_media starts a job: \(first.payload)") }
        let failed = await finishedJob(job)
        require(failed["status"] == "failed" && failed["code"] == "download_network" && failed["job_id"]?.stringValue == id
                && failed["idempotency_key"]?.stringValue == key && (failed["next_step"]?.stringValue ?? "").contains(key),
                "the failure names its job id and its idempotency_key: \(failed)")
        require(posts().count == 1 && posts().first?["params"]?["aspect_ratio"] == "16:9", "one POST /jobs, asking for 16:9: \(posts())")

        // 9:16 after 16:9, without the key: a new job asking for 9:16, never the held 16:9 result (its POST comes from the started
        // job, so it is counted once that job is done).
        project.setCanvasRatio(.tall9x16)
        let tall = try await SkyStudioGenerateTool.generate(AIToolArguments(args), project)
        let tallID = tall.payload["job_id"]?.stringValue
        if let tallJob = tallID.flatMap({ AIJobs.shared.job($0) }) { _ = await finishedJob(tallJob) }
        require(tall.payload["status"] == "started" && tallID != nil && tallID != id && posts().count == 2
                && posts().last?["params"]?["aspect_ratio"] == "9:16" && SkyStudioHeldDownloads.isHeld(id),
                "9:16 after 16:9 is a new job asking for 9:16; the held 16:9 result stays held: \(tall.payload), "
                    + "\(posts().map { $0["params"] ?? .null })")
        project.setCanvasRatio(.wide16x9)

        // The same arguments with another key: exactly one new POST and a new job; the held one stays held.
        var otherKey = args.objectValue ?? [:]
        otherKey["idempotency_key"] = .string("other-\(UUID().uuidString.prefix(8))")
        let other = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(otherKey)), project)
        let otherID = other.payload["job_id"]?.stringValue
        if let otherJob = otherID.flatMap({ AIJobs.shared.job($0) }) { _ = await finishedJob(otherJob) }
        require(other.payload["status"] == "started" && otherID != nil && otherID != id && otherID != tallID && posts().count == 3
                && SkyStudioHeldDownloads.isHeld(id),
                "another key with the same arguments is a new paid job, exactly one more POST (\(posts().count)); the held one stays held: "
                    + "\(other.payload)")

        // The key SkyCut returned, with the same arguments, the row dismissed: no POST, the held job's identical file.
        if let row = SkyStudioGenerationActivity.shared.runs.first(where: { $0.aiJobID == id }) { SkyStudioGenerationActivity.shared.dismiss(row) }
        var withKey = args.objectValue ?? [:]
        withKey["idempotency_key"] = .string(key)
        let quotes = GenerationHTTP.bodies("POST", "/quote").count
        let again = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(withKey)), project)
        require(again.payload["status"] == "downloading_again" && again.payload["job_id"]?.stringValue == id
                && again.payload["submitted_again"] == false,
                "the returned key with the same arguments downloads the held job again: \(again.payload)")
        let done = await finishedJob(job)
        let file = done["file"]?.stringValue.map { AIWorkspace.shared.resolve($0) }
        require(done["status"] == "done" && file.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.image,
                "the held job's identical file is saved under its own job id: \(done)")
        require(posts().count == 3 && GenerationHTTP.bodies("POST", "/quote").count == quotes, "no POST /jobs and no quote for it")

        // The same arguments without the key: exactly one new POST and a new job.
        let keyless = try await SkyStudioGenerateTool.generate(AIToolArguments(args), project)
        let keylessID = keyless.payload["job_id"]?.stringValue
        if let keylessJob = keylessID.flatMap({ AIJobs.shared.job($0) }) { _ = await finishedJob(keylessJob) }
        require(keyless.payload["status"] == "started" && keylessID != nil && keylessID != id && keylessID != tallID && posts().count == 4,
                "the same arguments without the key are a new paid job: exactly one more POST /jobs (\(posts().count)): \(keyless.payload)")
    }
}

/// A key sent with spaces, and an output folder a file stands in for.
@MainActor
private func generateMediaKeyAndFolderChecks(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let project = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("Key.skycut"), placement: .background) else {
        return require(false, "a project for generate_media's key and folder")
    }
    try await withGenerationHTTP {
        let posts = { GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs") }
        let args: [String: JSONValue] = ["kind": "image", "prompt": "a lighthouse at dusk"]

        // A key sent with spaces: the receipt says it trimmed, and that key sent back is the same request (no POST, the same job).
        let trimmed = "spaced-\(UUID().uuidString.prefix(8))"
        var spaced = args
        spaced["idempotency_key"] = .string("  \(trimmed) \n")
        let first = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(spaced)), project)
        guard let firstID = first.payload["job_id"]?.stringValue, let firstJob = AIJobs.shared.job(firstID) else {
            return require(false, "generate_media with a spaced key starts a job: \(first.payload)")
        }
        _ = await finishedJob(firstJob)
        var copied = args
        copied["idempotency_key"] = .string(trimmed)
        let jobs = posts()
        do {
            let again = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(copied)), project)
            require(first.payload["idempotency_key"]?.stringValue == trimmed && again.payload["job_id"]?.stringValue == firstID && posts() == jobs,
                    "the receipt's key, sent back, is the same request: \(first.payload["idempotency_key"] ?? .null), \(again.payload)")
        } catch {
            require(false, "the receipt's key, sent back, is the same request, got \(error)")
        }

        // An output folder a file stands in for: held, with Download again on its row; nothing came down.
        let generated = AIWorkspace.shared.outputFolder(.generated, project: project)
        try FileManager.default.createDirectory(at: generated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: generated)
        try Data("a file where the folder should be".utf8).write(to: generated)
        let files = GenerationHTTP.count("GET", "/generation-check/files/")
        let blocked = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(args)), project)
        guard let id = blocked.payload["job_id"]?.stringValue, let key = blocked.payload["idempotency_key"]?.stringValue,
              let job = AIJobs.shared.job(id) else { return require(false, "generate_media starts a job: \(blocked.payload)") }
        let failed = await finishedJob(job)
        let row = SkyStudioGenerationActivity.shared.runs.first { $0.aiJobID == id }
        require(failed["status"] == "failed" && failed["code"] == "download_not_saved" && row?.retryDownload != nil
                && SkyStudioHeldDownloads.isHeld(id) && GenerationHTTP.count("GET", "/generation-check/files/") == files
                && (failed["next_step"]?.stringValue ?? "").contains(key),
                "an output folder that cannot be made holds the paid result for Download again: \(failed)")

        // The folder fixed, the job's own key: downloaded under the same job id, no new POST.
        try FileManager.default.removeItem(at: generated)
        let made = posts()
        var withKey = args
        withKey["idempotency_key"] = .string(key)
        let again = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(withKey)), project)
        require(again.payload["status"] == "downloading_again" && again.payload["job_id"]?.stringValue == id,
                "the job's own key downloads it again: \(again.payload)")
        let done = await finishedJob(job)
        let file = done["file"]?.stringValue.map { AIWorkspace.shared.resolve($0) }
        require(done["status"] == "done" && file.flatMap { try? Data(contentsOf: $0) } == GenerationHTTP.image && posts() == made
                && !SkyStudioHeldDownloads.isHeld(id),
                "once the folder is fixed the same result is saved, with no new POST: \(done)")

        // A folder SkyCut may not write: the system's download cannot be moved in (the real write error, never a network one).
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        chmod(generated.path, 0o555)
        let locked = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(args)), project)
        guard let lockedID = locked.payload["job_id"]?.stringValue, let lockedKey = locked.payload["idempotency_key"]?.stringValue,
              let lockedJob = AIJobs.shared.job(lockedID) else {
            chmod(generated.path, 0o755)
            return require(false, "generate_media starts a job: \(locked.payload)")
        }
        let refused = await finishedJob(lockedJob)
        chmod(generated.path, 0o755)
        require(refused["status"] == "failed" && refused["code"] == "download_not_saved" && refused["download_attempts"] == 1
                && SkyStudioHeldDownloads.isHeld(lockedID),
                "a folder SkyCut may not write: download_not_saved after its one GET, held for Download again: \(refused)")
        var lockedArgs = args
        lockedArgs["idempotency_key"] = .string(lockedKey)
        let reread = posts()
        _ = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(lockedArgs)), project)
        let saved = await finishedJob(lockedJob)
        require(saved["status"] == "done" && posts() == reread, "once the folder is writable the job's own key saves it, no new POST: \(saved)")
    }
}

@MainActor
private func upscaleClipEntryChecks(_ folder: URL) async throws {
    guard let (source, info) = try await upscaleSource(folder),
          let a = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("A.skycut"), placement: .background),
          let b = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("B.skycut"), placement: .background) else {
        return require(false, "two projects for upscale_clip")
    }
    func place(in project: VideoEditProject) -> UUID {
        let clip = EditClip(sourceURL: source, sourceDuration: info.duration, timelineStart: 0, info: info)
        project.perform { $0.mainClips = [clip] }
        return clip.id
    }
    let clipA = place(in: a), clipB = place(in: b)
    func args(_ project: VideoEditProject, _ clip: UUID) -> AIToolArguments {
        AIToolArguments(["clip_id": .string(AIShortIDs(state: project.state).short(clip)), "tier": "topaz-starlight", "target": "1080p"])
    }
    try await withUpscaleHTTP(serving: source) {
        UpscaleHTTP.lock.withLock { UpscaleHTTP.drops = 3 }
        let first = try await AIUpscaleTool.upscale(args(a, clipA), a)
        guard let idA = first.payload["job_id"]?.stringValue, let jobA = AIJobs.shared.job(idA) else {
            return require(false, "upscale_clip starts A's job: \(first.payload)")
        }
        let failed = await finishedJob(jobA)
        let heldA = UpscaleActivity.shared.jobs.first { $0.aiJobID == idA }
        require(failed["status"] == "failed" && failed["code"] == "download_network" && heldA?.canRetryDownload == true
                && (failed["next_step"]?.stringValue ?? "").contains("Calling upscale_clip again starts a new upscale and is charged again"),
                "A's upscale is held on its own row; the next step says asking again is charged again: \(failed)")
        require(UpscaleHTTP.count("POST", "/jobs") == 1 && UpscaleHTTP.count("POST", "/uploads") == 1, "one upload and one POST /jobs for A")

        // Project B, the same source and settings: a new job for B; A's clip as it was, A's result still held.
        let second = try await AIUpscaleTool.upscale(args(b, clipB), b)
        guard let idB = second.payload["job_id"]?.stringValue, idB != idA, let jobB = AIJobs.shared.job(idB) else {
            return require(false, "project B asking for the same source starts its own job, not A's: \(second.payload)")
        }
        let doneB = await finishedJob(jobB)
        require(second.payload["status"] == "started" && doneB["status"] == "done" && (doneB["replaced_ids"]?.arrayValue?.count ?? 0) == 1,
                "B's upscale is done and replaces B's clip: \(doneB)")
        require(UpscaleHTTP.count("POST", "/jobs") == 2 && UpscaleHTTP.count("POST", "/uploads") == 2, "B's own upload and POST /jobs")
        require(b.state.clip(with: clipB)?.upscale != nil, "B's clip now uses its upscaled file")
        require(a.state.clip(with: clipA)?.upscale == nil && a.state.clip(with: clipA)?.sourceURL == source, "A's clip is as it was")
        require(heldA?.canRetryDownload == true && UpscaleActivity.shared.jobs.contains { $0 === heldA },
                "A's result is still held on its own row")
        if let heldA { UpscaleActivity.shared.remove(heldA) }
    }
}

/// An upscale saved while Sky Studio's bill is under review: the 75 reserved stays, the receipt says the bill is pending; get_job reads
/// the original job again (still under review: still pending), and once the bill is final the books and the receipt take 72.
@MainActor
private func upscaleBillUnderReview(_ folder: URL) async throws {
    guard let (source, info) = try await upscaleSource(folder),
          let project = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("Review.skycut"), placement: .background) else {
        return require(false, "a project for the upscale under review")
    }
    let clip = EditClip(sourceURL: source, sourceDuration: info.duration, timelineStart: 0, info: info)
    project.perform { $0.mainClips = [clip] }
    try await withUpscaleHTTP(serving: source) {
        UpscaleHTTP.lock.withLock { UpscaleHTTP.charge = .reviewing }
        let spent = SkyStudioSpendStore.shared.spentToday()
        let started = try await AIUpscaleTool.upscale(AIToolArguments(["clip_id": .string(AIShortIDs(state: project.state).short(clip.id)),
                                                                       "tier": "topaz-starlight", "target": "1080p"]), project)
        guard let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else {
            return require(false, "upscale_clip starts: \(started.payload)")
        }
        let done = await finishedJob(job)
        @MainActor func books() -> Double { SkyStudioSpendStore.shared.spentToday() - spent }
        require(done["status"] == "done" && done["billing_pending"] == true && done["credits_charged"] == .null && done["credits_reserved"] == 75
                && abs(books() - 75) < 0.001,
                "saved while the bill is under review: 75 reserved, the bill said pending, never 75 as the charge: \(done), \(books())")
        let reads = UpscaleHTTP.lock.withLock { UpscaleHTTP.reads }
        UpscaleHTTP.lock.withLock { UpscaleHTTP.rereadCharge = .reviewing }
        let still = try await AIExportTools.job(AIToolArguments(["job_id": .string(id)])).payload
        require(still["billing_pending"] == true && abs(books() - 75) < 0.001 && UpscaleHTTP.lock.withLock { UpscaleHTTP.reads } > reads,
                "get_job reads the original job; still under review: still pending at 75: \(still)")
        UpscaleHTTP.lock.withLock { UpscaleHTTP.rereadCharge = .billing }
        let final = try await AIExportTools.job(AIToolArguments(["job_id": .string(id)])).payload
        require(final["billing_pending"] == false && final["credits_charged"] == 72 && abs(books() - 72) < 0.001,
                "once the bill is final, get_job settles it: the books and the receipt say 72: \(final), \(books())")
        if let file = done["file"]?.stringValue.map({ AIWorkspace.shared.resolve($0) }) { try? FileManager.default.removeItem(at: file) }
    }
}
