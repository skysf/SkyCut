import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Identical paid requests in a row, part two (RepeatRequestChecks.swift has generate_media and upscale_clip): change_voice, which
// asks nothing else, and the two panels (user, 2026-11-25 / 26; SkyStudioRepeatGuard, SkyStudioPanelHeldDownload):
// - change_voice: the 2nd–4th say which one in a row; the 5th asks (its own question, in full access) before any upload or POST,
//   and its token starts it; an identical change from the panel is never counted (the AI's next is the 6th, not the 7th or a 1st);
//   another language or another voice is a different request (a new run, no line);
// - after a failed download the change-voice panel opened on that clip holds its Download again (and the paid button's label), not
//   for the same clip number in another project; the panel's Download again lands it with no new POST, and nothing is held after;
// - upscale: an identical upscale from the panel is never counted (the AI's next is the 3rd); after a failed download the panel for
//   that clip in that project holds Download again, the same source's clip in another project and a clip the job did not cover do
//   not; its Download again gets the same result with no new upload or POST.

@MainActor
func runRepeatPanelChecks(_ root: URL) async throws {
    try await voiceChangeRepeatChecks(root.appendingPathComponent("repeat-change", isDirectory: true))
    try await upscalePanelChecks(root.appendingPathComponent("repeat-upscale-panel", isDirectory: true))
}

@MainActor
private func voiceChangeRepeatChecks(_ folder: URL) async throws {
    let fixture = try VoiceChangeFixture(folder: folder)
    let clip = fixture.placeClip(try fixture.stereoSource())
    let args: [String: JSONValue] = ["clip_id": .string(fixture.short(clip)), "voice": .string(VoiceChangeHTTP.voiceID), "language": "en"]
    let posts = { VoiceChangeHTTP.calls("POST", "/jobs").count }
    func unmute() {   // each change mutes the clip it changed; the next identical one needs its sound back
        _ = AIUndoGrouping.step(fixture.project.effectiveUndoManager) { fixture.project.perform { $0.update(clip) { $0.isMuted = false } } }
    }
    func change(_ extra: [String: JSONValue] = [:]) async throws -> AIToolResult {
        let result = try await fixture.change(.object(args.merging(extra) { _, new in new }))
        if result.payload["job_id"] != nil { _ = try await fixture.wait(result); unmute() }
        return result
    }
    AIAccessStore.shared.setMode(.full)
    for number in 1...4 {
        let started = try await change()
        require(started.payload["status"] == "started" && repeatNumber(started) == (number == 1 ? nil : Double(number)) && posts() == number,
                "identical change \(number) starts with its line: \(started.payload["repeat_request"] ?? .null)")
    }
    let uploads = VoiceChangeHTTP.uploaded.count
    let fifth = try await change()
    require(fifth.payload["status"] == "needs_confirmation" && repeatNumber(fifth) == 5 && posts() == 4 && VoiceChangeHTTP.uploaded.count == uploads
            && (fifth.payload["question"]?.stringValue ?? "").contains("Voice change · Sky"),
            "full access: the 5th identical change asks its own question before any upload or POST: \(fifth.payload)")
    let agreed = try await change(["confirm_token": fifth.payload["confirm_token"] ?? .null])
    require(agreed.payload["status"] == "started" && agreed.payload["repeat_request"]?["user_agreed"] == true && posts() == 5,
            "its token starts the 5th: \(agreed.payload)")

    // An identical change from the panel is a person's click: never counted, never breaks the run.
    let store = VoiceLibraryStore()
    store.readKey = { .success("local-voice-change-fixture") }
    store.api = fixture.api
    fixture.detected = "en"
    guard let model = VoiceChangePanelModel(project: fixture.project, clipID: clip, store: store) else {
        return require(false, "the panel opens on the clip")
    }
    model.services = fixture.services
    await model.open()
    await eventually("the panel's quote") { model.quote != nil }
    require(model.held == nil && model.start(), "the panel (nothing held) starts an identical change")
    model.close()
    await eventually("the panel's change to land") { posts() == 6 && !VoiceChangeActivity.shared.isChanging(clip) }
    unmute()
    let sixth = try await change()
    require(repeatNumber(sixth) == 6 && posts() == 7, "the panel's change was not counted: the AI's next is the 6th (\(repeatNumber(sixth) ?? 0))")

    // Another language, another voice: different requests, each a new run.
    let chinese = try await change(["language": "zh"])
    let preset = try await change(["voice": "gemini:Charon"])
    let english = try await change()
    require(chinese.payload["status"] == "started" && repeatNumber(chinese) == nil && preset.payload["status"] == "started"
            && repeatNumber(preset) == nil && repeatNumber(english) == nil,
            "another language and another voice are different requests: new runs (\(repeatNumber(chinese) ?? 0), \(repeatNumber(preset) ?? 0), "
                + "\(repeatNumber(english) ?? 0))")

    // A download that gave up: the panel opened on that clip holds its Download again; another project's clip number does not.
    VoiceChangeHTTP.lock.withLock { VoiceChangeHTTP.fileDrops = 3 }
    let held = try await fixture.change(.object(args))
    let failed = try await fixture.wait(held)
    require(failed["code"] == "download_network", "the change's download gave up: \(failed)")
    let reopened = VoiceChangePanelModel(project: fixture.project, clipID: clip, store: store)
    require(reopened?.held != nil, "the panel opened on that clip holds its Download again")
    require(SkyStudioPanelHeldText.voiceChangeNewVersion(9) == "Make a new version (up to 9 credits)"
            && SkyStudioPanelHeldText.upscaleNewVersion(75) == "Make a new version (75 credits)",
            "the paid button next to Download again makes a new version, with its price")
    guard let elsewhere = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("Elsewhere.skycut"), placement: .background) else {
        return require(false, "another project")
    }
    require(SkyStudioPanelHeldDownload.voiceChange(project: elsewhere, clipID: clip) == nil,
            "another project never finds it (by the job's own clip and project, never by a request's parameters)")
    _ = OpenProjects.shared.close(elsewhere)   // at most 8 are open at once
    let made = posts()
    reopened?.held?.downloadAgain()
    await eventually("the held change to land") { fixture.project.state.clip(with: clip)?.isMuted == true }
    require(posts() == made && VoiceChangePanelModel(project: fixture.project, clipID: clip, store: store)?.held == nil,
            "the panel's Download again lands the same change with no new POST, and nothing is held after")
}

@MainActor
private func upscalePanelChecks(_ folder: URL) async throws {
    guard let (source, info) = try await upscaleSource(folder),
          let a = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("A.skycut"), placement: .background),
          let b = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("B.skycut"), placement: .background) else {
        return require(false, "two projects for the upscale panel")
    }
    defer { _ = OpenProjects.shared.close(a); _ = OpenProjects.shared.close(b) }
    func place(in project: VideoEditProject) -> UUID {
        let clip = EditClip(sourceURL: source, sourceDuration: info.duration, timelineStart: 0, info: info)
        project.perform { $0.mainClips = [clip] }
        return clip.id
    }
    let clipA = place(in: a), clipB = place(in: b)
    let args: [String: JSONValue] = ["clip_id": .string(AIShortIDs(state: a.state).short(clipA)), "tier": "topaz-starlight", "target": "1080p"]
    func call() async throws -> AIToolResult {
        let result = try await AIUpscaleTool.upscale(AIToolArguments(.object(args)), a)
        if let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) { _ = await finishedJob(job) }
        return result
    }
    AIAccessStore.shared.setMode(.full)
    try await withUpscaleHTTP(serving: source) {
        _ = try await call()
        let second = try await call()
        require(repeatNumber(second) == 2, "the AI's second identical upscale says so")
        // The panel's identical upscale (as UpscalePanel.start makes it): never counted.
        guard let model = UpscalePanelModel(project: a, clipID: clipA) else { return require(false, "the upscale panel's model") }
        let tier = UpscaleTier(id: "topaz-starlight", title: "Topaz Starlight", targets: [.p1080, .p2160], maxSourceSeconds: 30.5,
                               maxSourceFPS: 30, maxUploadBytes: 209_715_200)
        let request = model.request(choice: model.defaultChoice, target: .p1080, tier: tier, quote: SkyStudioQuote(json: ["credits": 75])!)
        let panelJob = UpscaleJob(request: request, clipIDs: request.range.coveredClipIDs, owner: CloudTasksActivity.owner(of: a), title: model.clipName)
        UpscaleActivity.shared.add(panelJob)
        await eventually("the panel's upscale") { if case .running = panelJob.state { return false } else { return true } }
        UpscaleActivity.shared.compare = nil
        UpscaleActivity.shared.remove(panelJob)
        let third = try await call()
        require(repeatNumber(third) == 3, "the panel's upscale was not counted: the AI's next is the 3rd (\(repeatNumber(third) ?? 0))")

        // A download that gave up: A's panel for that clip holds Download again; B's clip of the same source does not.
        UpscaleHTTP.lock.withLock { UpscaleHTTP.drops = 3 }
        let held = try await call()
        let failed = held.payload["job_id"]?.stringValue.flatMap { AIJobs.shared.job($0) }.map { AIJobs.shared.json($0) }
        require(failed?["code"] == "download_network", "the upscale's download gave up: \(String(describing: failed))")
        require(SkyStudioPanelHeldDownload.upscale(project: a, clipID: clipA) != nil, "A's panel for that clip holds Download again")
        require(SkyStudioPanelHeldDownload.upscale(project: b, clipID: clipB) == nil,
                "B's clip of the same source does not find it (by the job's own clip and project, never by the source file)")
        require(SkyStudioPanelHeldDownload.upscale(project: a, clipID: UUID()) == nil, "a clip the job did not cover does not either")
        let uploads = UpscaleHTTP.count("POST", "/uploads"), jobs = UpscaleHTTP.count("POST", "/jobs")
        SkyStudioPanelHeldDownload.upscale(project: a, clipID: clipA)?.downloadAgain()
        if let id = held.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) { _ = await finishedJob(job) }
        require(UpscaleHTTP.count("POST", "/uploads") == uploads && UpscaleHTTP.count("POST", "/jobs") == jobs
                && SkyStudioPanelHeldDownload.upscale(project: a, clipID: clipA) == nil,
                "the panel's Download again gets the same result with no new upload or POST, and nothing is held after")
    }
}

@MainActor
private func eventually(_ what: String, _ done: @MainActor () -> Bool) async {
    for _ in 0..<600 {
        if done() { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    require(false, "timed out waiting for \(what)")
}
