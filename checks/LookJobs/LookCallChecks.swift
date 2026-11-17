import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Real 12-frame looks through AILookCall (the router's path for look), on two background projects of two AI sessions.

@MainActor func runLookCallChecks(_ root: URL) async throws {
    let ffmpeg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]!)
    var sources: [(URL, MediaInfo)] = []
    for name in ["testsrc2", "smptehdbars", "rgbtestsrc"] {
        let url = root.appendingPathComponent(name + ".mp4")
        sources.append((url, try await MediaProbe.probe(url: url, ffmpeg: ffmpeg).get()))
    }
    let a = try LookProject(folder: root.appendingPathComponent("a"), name: "A", session: "session-a", sources: sources, count: 12)
    let b = try LookProject(folder: root.appendingPathComponent("b"), name: "B", session: "session-b", sources: sources, count: 12)
    defer {
        _ = OpenProjects.shared.close(a.project)
        _ = OpenProjects.shared.close(b.project)
    }
    try await acceptance(a, b)
    try await queuedBehindAnEdit(a)
    try await cancelWhileRunning(b)
    await editGoesBeforeTheFrames(a)
}

/// The acceptance from the reports: two sessions each send two 12-frame looks at once. Each answers within `answerWithin` with its
/// picture, or with a job_id whose get_job brings the picture; nothing is dropped. (At the production 25 s.)
@MainActor private func acceptance(_ a: LookProject, _ b: LookProject) async throws {
    AILookCall.answerWithin = 25
    let lines = AICallLines()
    let probes = (0..<4).map { _ in LookProbe() }
    let started = Date()
    async let first = a.look(["times": twelve(from: 1.0)], in: lines, probe: probes[0])
    async let second = a.look(["times": twelve(from: 13.0)], in: lines, probe: probes[1])
    async let third = b.look(["times": twelve(from: 1.0)], in: lines, probe: probes[2])
    async let fourth = b.look(["times": twelve(from: 13.0)], in: lines, probe: probes[3])
    let answers = await [first, second, third, fourth]
    let slowest = Date().timeIntervalSince(started)
    require(slowest < AILookCall.answerWithin + 5, "every look call answered within about \(Int(AILookCall.answerWithin)) s (slowest \(Int(slowest)) s)")
    for (index, answer) in answers.enumerated() {
        let project = index < 2 ? a : b
        var reply = lookAnswer(answer)
        if let job = reply.object["job_id"]?.stringValue {
            // Slow machine: the look became a job; its picture must come with get_job.
            var result = try await project.getJob(job, wait: 30)
            while result.payload["status"]?.stringValue == "running" || result.payload["status"]?.stringValue == "queued" {
                result = try await project.getJob(job, wait: 30)
            }
            let frames = result.payload["result"]?["frames"]?.arrayValue?.count ?? 0
            reply = (result.payload.objectValue ?? [:], result.images.count, result.payload["status"]?.stringValue != "done" || frames != 12)
        }
        require(!reply.failed && reply.images == 1, "look \(index + 1) of the two sessions came back with its picture (\(reply.object.keys.sorted()))")
        require(probes[index].started == 1 && probes[index].skipped == 0, "look \(index + 1) ran exactly once and was not dropped")
    }
    print("acceptance: two sessions x two 12-frame looks answered in \(String(format: "%.1f", slowest)) s, all with their pictures")
}

/// A look waiting behind an edit on its project becomes a queued job (position, waiting_for), runs after the edit and brings its picture
/// with get_job; a second one cancelled while queued never starts; another session cannot cancel it.
@MainActor private func queuedBehindAnEdit(_ a: LookProject) async throws {
    AILookCall.answerWithin = 0.3
    let lines = AICallLines()
    let edit = lines.join(["project:" + a.project.shortID], tool: "edit_clips", session: a.session, client: "LookJobCheck")
    await lines.waitForTurn(edit)
    let firstProbe = LookProbe(), secondProbe = LookProbe()
    let first = lookAnswer(await a.look(["times": twelve(from: 3.0)], in: lines, probe: firstProbe)).object
    let second = lookAnswer(await a.look(["times": twelve(from: 9.0)], in: lines, probe: secondProbe)).object
    require(first["status"]?.stringValue == "queued" && first["queue_position"]?.intValue == 1, "a look behind the edit answers as a queued job, next in line (\(first))")
    require(second["queue_position"]?.intValue == 2, "the second look is second in line (\(second))")
    require(first["waiting_for"]?.stringValue?.hasPrefix("edit_clips from this AI session, running for") == true,
            "waiting_for names what it waits for (\(String(describing: first["waiting_for"])))")
    require(first["kind"]?.stringValue == "look" && first["next_step"]?.stringValue?.contains("get_job") == true, "the answer says to wait with get_job")
    guard let firstJob = first["job_id"]?.stringValue, let secondJob = second["job_id"]?.stringValue else {
        require(false, "both looks behind the edit became jobs")
        edit.letGo()
        return
    }
    let queued = try await a.getJob(firstJob)
    require(queued.payload["status"]?.stringValue == "queued" && queued.payload["waiting_for"] != nil, "get_job reports queued and waiting_for while it waits")
    do {
        _ = try a.cancelJob(secondJob, as: "another-session")
        require(false, "another AI session cannot cancel this session's look")
    } catch {}
    let cancelled = try a.cancelJob(secondJob)
    require(cancelled.payload["status"]?.stringValue == "cancelled"
                && cancelled.payload["message"]?.stringValue?.contains("never started") == true,
            "cancelled while queued: cancelled at once and never started (\(cancelled.payload))")
    require(firstProbe.started == 0 && secondProbe.started == 0, "nothing ran while the edit held the project's line")
    edit.letGo()
    var done = try await a.getJob(firstJob, wait: 30)
    while done.payload["status"]?.stringValue != "done", done.payload["status"]?.stringValue != "failed" {
        done = try await a.getJob(firstJob, wait: 30)
    }
    require(done.payload["status"]?.stringValue == "done" && done.images.count == 1
                && done.payload["result"]?["frames"]?.arrayValue?.count == 12 && done.payload["result"]?["looked_at"]?.stringValue == "timeline",
            "after the edit the look ran and get_job brings its result and picture (\(done.payload["status"] ?? .null), \(done.images.count) images)")
    await settle()
    require(firstProbe.started == 1 && secondProbe.started == 0 && secondProbe.skipped == 1,
            "the cancelled look never started (started \(secondProbe.started), skipped \(secondProbe.skipped))")
    let still = try await a.getJob(secondJob)
    require(still.payload["status"]?.stringValue == "cancelled" && still.images.isEmpty, "the cancelled job stays cancelled, with no picture")
    print("queued: positions 1 and 2 behind edit_clips, waiting_for, ran after it with its picture; the cancelled one never started")
}

/// A look still rendering when it became a job stops when cancelled: the job is cancelled at once and keeps no picture.
@MainActor private func cancelWhileRunning(_ b: LookProject) async throws {
    AILookCall.answerWithin = 0.05
    let lines = AICallLines()
    let probe = LookProbe()
    let answer = lookAnswer(await b.look(["times": twelve(from: 2.0), "size": "large"], in: lines, probe: probe)).object
    guard let job = answer["job_id"]?.stringValue else {
        require(false, "a look not done within 0.05 s becomes a job (\(answer))")
        return
    }
    var running = try await b.getJob(job)
    while running.payload["status"]?.stringValue == "queued" {
        try await Task.sleep(for: .milliseconds(20))
        running = try await b.getJob(job)
    }
    require(running.payload["status"]?.stringValue == "running", "the look is running when it is cancelled (\(running.payload))")
    let cancelled = try b.cancelJob(job)
    require(cancelled.payload["status"]?.stringValue == "cancelled", "cancel_job cancels a running look at once (\(cancelled.payload))")
    let deadline = Date().addingTimeInterval(60)
    while probe.cancelled + probe.finished == 0, Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    require(probe.cancelled == 1 && probe.finished == 0, "the look stopped at its next frame (cancelled \(probe.cancelled), finished \(probe.finished))")
    let after = try await b.getJob(job)
    require(after.payload["status"]?.stringValue == "cancelled" && after.images.isEmpty, "the stopped look leaves the job cancelled, with no picture")
    print("running: cancel_job stopped a rendering look")
}

/// An edit sent after a look on the same project gets its turn as soon as the look has read the project, not after its frames.
@MainActor private func editGoesBeforeTheFrames(_ a: LookProject) async {
    AILookCall.answerWithin = 25
    let lines = AICallLines()
    let probe = LookProbe()
    let look = Task { @MainActor in await a.look(["times": twelve(from: 5.0)], in: lines, probe: probe) }
    await settle()
    let edit = lines.join(["project:" + a.project.shortID], tool: "set_text", session: a.session, client: "LookJobCheck")
    await lines.waitForTurn(edit)
    // `finished` is counted when the tool returns, before the router's own let-go after the call: had the look kept its line until
    // then, the edit would see it here.
    let renderedAtEditTurn = probe.finished
    edit.letGo()
    let answer = lookAnswer(await look.value)
    require(probe.started == 1 && renderedAtEditTurn == 0, "the edit behind the look got its turn while the look was still rendering")
    require(!answer.failed && answer.images == 1, "and the look still answered with its picture")
    print("early release: the edit went before the look's frames were done")
}
