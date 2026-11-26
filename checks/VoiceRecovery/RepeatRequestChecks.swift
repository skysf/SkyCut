import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Identical paid requests in a row (user, 2026-11-25; SkyStudioRepeatGuard; docs/architecture/sky-studio-jobs.md "Identical paid
// requests in a row") through the tool entries, with POSTs counted at the fake servers (the pure half is
// checks/SkyStudio/RepeatGuardChecks.swift; change_voice and the panels are RepeatPanelChecks.swift):
// - generate_media in full access: the 1st carries no line, the 2nd–4th say which one in a row (another output name is the same
//   request); the 5th asks before any POST, asked again it is the same question and still nothing starts (a no starts nothing);
//   its token starts it and the 6th, 7th go through without asking; a call with the first job's idempotency_key is that job (no
//   POST) and neither counts nor breaks the run; the same request in another project is that project's 1st; the canvas turned to
//   9:16 is a different request (a new run), and back to 16:9 is a new run again; in ask mode the 5th asks too;
// - upscale_clip: four in full access, then the 5th in ask mode is one question (the draft reason and the identical-request
//   sentence, which says each identical request after it still needs its own approval), with no upload or POST; its one token
//   starts it;
// - add_voiceover with a Sky Studio voice: the same script four times, then the 5th asks before anything is reserved or POSTed, and
//   its token starts it.
// generate_media and upscale_clip need a key on the account (SkyStudioAccount.hasKey), so these run after PaidToolEntryChecks
// marked one.

@MainActor
func runRepeatRequestChecks(_ root: URL) async throws {
    if !SkyStudioAccount.shared.hasKey { SkyStudioAccount.shared.requireKeychainPermission() }
    let mode = AIAccessStore.shared.mode
    defer { AIAccessStore.shared.setMode(mode) }
    SkyStudioSpendStore.shared.setDailyLimit(100_000)
    try await generateRepeatChecks(root.appendingPathComponent("repeat-generate", isDirectory: true))
    try await upscaleRepeatChecks(root.appendingPathComponent("repeat-upscale", isDirectory: true))
    try await voiceoverRepeatChecks(root.appendingPathComponent("repeat-voiceover", isDirectory: true))
    try await runRepeatPanelChecks(root)
}

/// add_voiceover: the same script read the same way, the 5th asks before anything is reserved or POSTed, and its token starts it
/// (FBR1 on PR #557: a token never passed on left every check green).
@MainActor
private func voiceoverRepeatChecks(_ folder: URL) async throws {
    let fixture = try VoiceRecoveryFixture(folder: folder)
    SkyStudioSpendStore.shared.setDailyLimit(100_000)   // the fixture's 1,000 can be below what the checks before spent today
    AIAccessStore.shared.setMode(.full)
    let lines = ["Hello world."]
    func finished(_ result: AIToolResult) async throws {   // a call that started nothing fails its own line, not the checks after it
        if result.payload["job_id"] != nil { _ = try await fixture.wait(result) }
    }
    for number in 1...4 {
        let started = try fixture.started(try await fixture.narrate(lines, subtitles: false))
        require(started.payload["job_id"] != nil && repeatNumber(started) == (number == 1 ? nil : Double(number)),
                "identical narration \(number) starts with its line: \(started.payload["repeat_request"] ?? .null)")
        try await finished(started)
    }
    let posts = VoiceRecoveryHTTP.posts, spent = SkyStudioSpendStore.shared.spentToday()
    let fifth = try fixture.started(try await fixture.narrate(lines, subtitles: false))
    let token = fifth.payload["confirm_token"]?.stringValue
    require(fifth.payload["status"] == "needs_confirmation" && repeatNumber(fifth) == 5 && token != nil
            && (fifth.payload["question"]?.stringValue ?? "").contains("Voiceover · ")
            && VoiceRecoveryHTTP.posts == posts && SkyStudioSpendStore.shared.spentToday() == spent,
            "the 5th identical narration asks before anything is reserved or POSTed: \(fifth.payload)")
    var yes = fixture.input(lines: lines, subtitles: false)
    yes.confirmToken = token
    let agreed = try fixture.started(try await SkyStudioVoiceoverStart.start(yes, project: fixture.project, services: fixture.services))
    require(agreed.payload["job_id"] != nil && agreed.payload["repeat_request"]?["user_agreed"] == true,
            "its token starts the 5th: \(agreed.payload)")
    try await finished(agreed)
    require(VoiceRecoveryHTTP.posts > posts, "the 5th was sent once the user agreed")
}

/// The number in a row a result says (nil without a line).
func repeatNumber(_ result: AIToolResult) -> Double? { result.payload["repeat_request"]?["identical_in_a_row"]?.doubleValue }

@MainActor
private func generateRepeatChecks(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let project = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("Repeat.skycut"), placement: .background),
          let other = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("Other.skycut"), placement: .background) else {
        return require(false, "two projects for identical generate_media requests")
    }
    defer { _ = OpenProjects.shared.close(project); _ = OpenProjects.shared.close(other) }   // at most 8 are open at once
    project.setCanvasRatio(.wide16x9)
    other.setCanvasRatio(.wide16x9)
    AIAccessStore.shared.setMode(.full)
    try await withGenerationHTTP {
        let posts = { GenerationHTTP.count("POST", "/generation-check/api/skycut/v1/jobs") }
        let args: [String: JSONValue] = ["kind": "image", "prompt": "a lighthouse in fog"]
        @MainActor func call(_ arguments: [String: JSONValue], _ target: VideoEditProject) async throws -> AIToolResult {
            let result = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(arguments)), target)
            if let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) { _ = await finishedJob(job) }
            return result
        }

        var firstID: String?, firstKey: String?
        for number in 1...4 {
            var named = args
            named["name"] = .string("take \(number)")   // never sent to Sky Studio: the same request
            let started = try await call(named, project)
            if number == 1 { (firstID, firstKey) = (started.payload["job_id"]?.stringValue, started.payload["idempotency_key"]?.stringValue) }
            require(started.payload["status"] == "started" && repeatNumber(started) == (number == 1 ? nil : Double(number)) && posts() == number,
                    "identical request \(number): started, \(number == 1 ? "no line" : "the line says \(number)"), \(number) POSTs: "
                        + "\(started.payload["repeat_request"] ?? .null), \(posts())")
        }
        let line = try await call(args, other)   // another project: its own run (and nothing here breaks this one)
        require(repeatNumber(line) == nil && posts() == 5, "the same request in another project is that project's 1st")

        let fifth = try await call(args, project)
        let token = fifth.payload["confirm_token"]?.stringValue
        require(fifth.payload["status"] == "needs_confirmation" && repeatNumber(fifth) == 5 && token != nil && posts() == 5
                && (fifth.payload["question"]?.stringValue ?? "").contains("5th identical request in a row"),
                "full access: the 5th identical request asks before any POST: \(fifth.payload)")
        let unanswered = try await call(args, project)
        require(unanswered.payload["confirm_token"]?.stringValue == token && posts() == 5,
                "asked again before the user answered: the same question, still nothing started or charged")
        var yes = args
        yes["confirm_token"] = token.map(JSONValue.string) ?? .null
        let agreed = try await call(yes, project)
        require(agreed.payload["status"] == "started" && repeatNumber(agreed) == 5 && agreed.payload["repeat_request"]?["user_agreed"] == true
                && posts() == 6, "the user's yes starts the 5th: \(agreed.payload["repeat_request"] ?? .null)")
        for number in 6...7 {
            let next = try await call(args, project)
            require(next.payload["status"] == "started" && repeatNumber(next) == Double(number) && posts() == number + 1,
                    "the \(SkyStudioRepeatWords.ordinal(number)) goes through without asking after the yes")
        }

        // The first job's own key (with its own arguments: a key is bound to them): that job (#554), no POST; the run goes on.
        var keyed = args
        keyed["name"] = "take 1"
        keyed["idempotency_key"] = firstKey.map(JSONValue.string) ?? .null
        let same = try await SkyStudioGenerateTool.generate(AIToolArguments(.object(keyed)), project)
        require(same.payload["job_id"]?.stringValue == firstID && posts() == 8, "a call with an earlier job's key is that job, not a repeat")
        let eighth = try await call(args, project)
        require(repeatNumber(eighth) == 8 && posts() == 9, "the earlier key neither counted nor broke the run: \(eighth.payload["repeat_request"] ?? .null)")

        // A different request (the canvas turned to 9:16) starts a new run; back to 16:9 is a new run again, the yes gone with the old.
        project.setCanvasRatio(.tall9x16)
        let tall = try await call(args, project)
        require(tall.payload["status"] == "started" && repeatNumber(tall) == nil && tall.payload["params"]?["aspect_ratio"] == "9:16",
                "the canvas aspect makes it a different request: a new run")
        project.setCanvasRatio(.wide16x9)
        let back = try await call(args, project)
        require(back.payload["status"] == "started" && repeatNumber(back) == nil, "back to 16:9 after 9:16: a new run")

        // Ask mode, within the draft (nothing else to ask): the 5th asks there too.
        AIAccessStore.shared.setMode(.ask)
        for number in 2...4 {
            let next = try await call(args, project)
            require(next.payload["status"] == "started" && repeatNumber(next) == Double(number), "ask mode within the draft: the \(SkyStudioRepeatWords.ordinal(number)) starts")
        }
        let posted = posts()
        let askFifth = try await call(args, project)
        require(askFifth.payload["status"] == "needs_confirmation" && repeatNumber(askFifth) == 5 && posts() == posted,
                "ask mode: the 5th asks before any POST too: \(askFifth.payload)")
        AIAccessStore.shared.setMode(.full)
    }
}

@MainActor
private func upscaleRepeatChecks(_ folder: URL) async throws {
    guard let (source, info) = try await upscaleSource(folder),
          let project = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("Upscale.skycut"), placement: .background) else {
        return require(false, "a project for identical upscale_clip requests")
    }
    defer { _ = OpenProjects.shared.close(project) }
    let clip = EditClip(sourceURL: source, sourceDuration: info.duration, timelineStart: 0, info: info)
    project.perform { $0.mainClips = [clip] }
    let args: [String: JSONValue] = ["clip_id": .string(AIShortIDs(state: project.state).short(clip.id)), "tier": "topaz-starlight", "target": "1080p"]
    func call(_ arguments: [String: JSONValue]) async throws -> AIToolResult {
        let result = try await AIUpscaleTool.upscale(AIToolArguments(.object(arguments)), project)
        if let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) { _ = await finishedJob(job) }
        return result
    }
    AIAccessStore.shared.setMode(.full)
    try await withUpscaleHTTP(serving: source) {
        for number in 1...4 {
            let started = try await call(args)
            require(started.payload["status"] == "started" && repeatNumber(started) == (number == 1 ? nil : Double(number))
                    && UpscaleHTTP.count("POST", "/jobs") == number,
                    "identical upscale \(number) starts with its line: \(started.payload["repeat_request"] ?? .null)")
        }
        let uploads = UpscaleHTTP.count("POST", "/uploads"), jobs = UpscaleHTTP.count("POST", "/jobs")
        AIAccessStore.shared.setMode(.ask)
        let asked = try await call(args)
        let question = asked.payload["question"]?.stringValue ?? ""
        require(asked.payload["status"] == "needs_confirmation" && question.contains("Paid upscaling exceeds draft settings.")
                && question.contains("5th identical request in a row") && question.contains("still needs its own approval") && repeatNumber(asked) == 5
                && UpscaleHTTP.count("POST", "/uploads") == uploads && UpscaleHTTP.count("POST", "/jobs") == jobs,
                "ask mode: the 5th identical upscale is one question with the draft reason, before any upload or POST: \(question)")
        var yes = args
        yes["confirm_token"] = asked.payload["confirm_token"] ?? .null
        let agreed = try await call(yes)
        require(agreed.payload["status"] == "started" && agreed.payload["repeat_request"]?["user_agreed"] == true
                && UpscaleHTTP.count("POST", "/jobs") == jobs + 1, "its one token answers both questions and starts it: \(agreed.payload)")
        AIAccessStore.shared.setMode(.full)
    }
}
