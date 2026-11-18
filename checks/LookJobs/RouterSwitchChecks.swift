import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Calls the router after its existing argument / license gates, with real queueKeys, target selection, tool and jobs.
// A controlled switch holds the exact wait phase; no account, real project, helper connection or wall-clock load is used.
@MainActor func runRouterSwitchChecks(_ root: URL) async throws {
    let ffmpeg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]!)
    let source = root.appendingPathComponent("testsrc2.mp4")
    let info = try await MediaProbe.probe(url: source, ffmpeg: ffmpeg).get()
    let otherSource = root.appendingPathComponent("smptehdbars.mp4")
    let otherInfo = try await MediaProbe.probe(url: otherSource, ffmpeg: ffmpeg).get()
    let session = "router-switch-\(UUID())"
    let a = try LookProject(folder: root.appendingPathComponent("switch-a"), name: "A", session: session, sources: [(source, info)], count: 1)
    let b = try LookProject(folder: root.appendingPathComponent("switch-b"), name: "B", session: session, sources: [(otherSource, otherInfo)], count: 1)
    defer {
        _ = OpenProjects.shared.close(a.project)
        _ = OpenProjects.shared.close(b.project)
        AILookCall.answerWithin = 25
    }
    AIReadGrants.shared.remember([root])
    AILookCall.answerWithin = 0.05
    for remembered in [false, true] { try await switchThenLook(a, b, remembered: remembered) }
    try await closeQueuedBehindEdit(a, b)
    try await cancelPendingSwitch(a, b, stop: false)
    try await cancelPendingSwitch(a, b, stop: true)
    try await explicitAndFileControls(a, source: source)
    print("router switch: checked implicit / remembered waits, queued jobs, late target / Stop binding, distinct clip / picture, real close_project and cancellation controls")
}

@MainActor private final class RouterSwitchProbe {
    var entered = false
    var answer: AIToolRouter.Answer?
}

@MainActor private func owns(_ project: LookProject) {
    AIProjectSessions.shared.own(project.project, session: project.session, client: "RouterSwitchCheck")
}

@MainActor private func request(_ project: LookProject, arguments: JSONValue, remembered: Bool = false) -> MCPBridge.Request {
    MCPBridge.Request(tool: "look", arguments: arguments, client: "RouterSwitchCheck",
                      project: remembered ? AIProjectSessions.shared.stamp(project.project) : nil, session: project.session)
}

@MainActor private func until(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

@MainActor private func switchThenLook(_ a: LookProject, _ b: LookProject, remembered: Bool) async throws {
    owns(a)
    let lines = AICallLines()
    let router = AIToolRouter(lines: lines)
    let held = lines.join(["switch:" + a.session], tool: "new_project", session: a.session, client: "RouterSwitchCheck")
    await lines.waitForTurn(held)
    defer { held.letGo() }
    let probe = RouterSwitchProbe()
    lines.didWaitForLast = { key in if key == "switch:" + a.session { probe.entered = true } }
    let call = Task { @MainActor in
        probe.answer = await router.routeValidated(request(a, arguments: ["times": [1], "size": "small"], remembered: remembered),
                                                   tool: .look, begin: { true })
    }
    require(await until { probe.entered }, "implicit look entered the actual router switch wait (remembered=\(remembered))")
    let bounded = await until { probe.answer != nil }
    require(bounded, "implicit look answers with a job while its switch is still held (remembered=\(remembered))")
    guard let answer = probe.answer, let id = lookAnswer(answer).object["job_id"]?.stringValue,
          let job = AIJobs.shared.job(id) else {
        owns(b); held.letGo(); await call.value
        await drainLateAnswer(probe, as: a)
        return
    }
    let queued = AIJobs.shared.json(job)
    require(queued["status"] == "queued" && queued["queue_position"] == 1, "switch wait is a queued job, next in line")
    require(queued["waiting_for"]?.stringValue?.hasPrefix("new_project from this AI session") == true, "the job names the switch it waits for")
    require(queued["project"] == nil && answer.project == nil, "the pending look does not bind the old remembered project")
    require(job.stopsWith == a.project.shortID, "the pending look initially stops with the session's current project")
    let edit = lines.join(["project:" + b.project.shortID], tool: "edit_clips", session: a.session, client: "RouterSwitchCheck")
    await lines.waitForTurn(edit)
    defer { edit.letGo() }
    owns(b)
    held.letGo()
    require(await until { job.project == b.project.shortID }, "the job binds the project chosen after the switch")
    require(job.stopsWith == b.project.shortID && AIJobs.shared.json(job)["waiting_for"]?.stringValue?.hasPrefix("edit_clips") == true,
            "project queue / Stop ownership follow the newly selected project")
    edit.letGo()
    let result = try await a.getJob(id, wait: 30)
    require(result.payload["status"] == "done" && result.images.count == 1, "get_job returns the switched look's actual picture")
    require(result.payload["result"]?["project"] == .string(b.project.shortID), "the actual router stamps the new target in the final look")
    let onScreen = result.payload["result"]?["frames"]?.arrayValue?.first?["on_screen"]?["clips"]?.arrayValue?.first?.stringValue ?? ""
    let expected = AIShortIDs(state: b.project.state).short(b.project.state.mainClips[0].id)
    require(onScreen.hasPrefix(expected + " ") && onScreen.contains("smptehdbars"), "the real look reads the new project's distinct clip, beyond its router stamp")
    await call.value
}

@MainActor private func cancelPendingSwitch(_ a: LookProject, _ b: LookProject, stop: Bool) async throws {
    owns(a)
    let lines = AICallLines()
    let router = AIToolRouter(lines: lines)
    let held = lines.join(["switch:" + a.session], tool: "close_project", session: a.session, client: "RouterSwitchCheck")
    await lines.waitForTurn(held)
    defer { held.letGo() }
    let probe = RouterSwitchProbe()
    let call = Task { @MainActor in
        probe.answer = await router.routeValidated(request(a, arguments: ["times": [1]]), tool: .look, begin: { true })
    }
    let bounded = await until { probe.answer != nil }
    require(bounded, "pending-switch cancellation has a job before the switch finishes")
    if let answer = probe.answer, let id = lookAnswer(answer).object["job_id"]?.stringValue, let job = AIJobs.shared.job(id) {
        if stop {
            require(AIJobs.shared.cancel(stoppingWith: a.project.shortID).contains(id), "Stop includes the pending-switch look")
        } else { _ = try a.cancelJob(id) }
        require(job.status == .cancelled && job.images.isEmpty && !held.hasLetGo, "pending cancellation is immediate and does not release another call's line")
        owns(b); held.letGo(); await call.value
        await settle()
        require(job.status == .cancelled && job.images.isEmpty && job.project == nil, "a cancelled pending look never binds or publishes a later target")
    } else {
        owns(b); held.letGo(); await call.value
        await drainLateAnswer(probe, as: a)
    }
}

@MainActor private func explicitAndFileControls(_ a: LookProject, source: URL) async throws {
    owns(a)
    let lines = AICallLines()
    let router = AIToolRouter(lines: lines)
    let held = lines.join(["switch:" + a.session], tool: "new_project", session: a.session, client: "RouterSwitchCheck")
    await lines.waitForTurn(held)
    defer { held.letGo() }
    let probe = RouterSwitchProbe()
    lines.didWaitForLast = { _ in probe.entered = true }
    for args: JSONValue in [["project": .string(a.project.shortID), "times": [1], "size": "small"],
                            ["file": .string(source.path), "times": [1], "size": "small"]] {
        var result = lookAnswer(await router.routeValidated(request(a, arguments: args), tool: .look, begin: { true }))
        if let id = result.object["job_id"]?.stringValue {
            let done = try await a.getJob(id, wait: 30)
            result = (done.payload.objectValue ?? [:], done.images.count, done.payload["status"] != "done")
        }
        require(!probe.entered && !result.failed && result.images == 1, "explicit-project and file looks do not wait for the session switch")
    }
}

@MainActor private func closeQueuedBehindEdit(_ a: LookProject, _ b: LookProject) async throws {
    owns(b)
    let clip = b.project.state.mainClips[0]
    let closingProject = try LookProject(folder: b.project.documentURL!.deletingLastPathComponent().appendingPathComponent("closing"),
                                        name: "Closing", session: a.session, sources: [(clip.sourceURL, clip.info!)], count: 1)
    owns(closingProject)
    defer { _ = OpenProjects.shared.close(closingProject.project) }
    let remembered = AIProjectSessions.shared.stamp(closingProject.project)
    let lines = AICallLines()
    let router = AIToolRouter(lines: lines)
    let edit = lines.join(["project:" + closingProject.project.shortID], tool: "edit_clips", session: a.session, client: "RouterSwitchCheck")
    await lines.waitForTurn(edit)
    defer { edit.letGo() }
    let closeRequest = MCPBridge.Request(tool: "close_project", arguments: ["project": .string(closingProject.project.shortID)],
                                         client: "RouterSwitchCheck", session: a.session)
    let closing = Task { @MainActor in await router.routeValidated(closeRequest, tool: .closeProject, begin: { true }) }
    await settle()
    let probe = RouterSwitchProbe()
    let lookRequest = MCPBridge.Request(tool: "look", arguments: ["times": [1], "size": "small"], client: "RouterSwitchCheck",
                                        project: remembered, session: a.session)
    let call = Task { @MainActor in probe.answer = await router.routeValidated(lookRequest, tool: .look, begin: { true }) }
    require(await until { probe.answer != nil }, "a look waiting for real close_project behind an edit also answers with a job")
    let id = probe.answer.flatMap { lookAnswer($0).object["job_id"]?.stringValue }
    if let id, let job = AIJobs.shared.job(id) {
        let queued = AIJobs.shared.json(job)
        require(queued["status"] == "queued" && queued["queue_position"] == 2,
                "pending close and look report their transitive position behind the running edit")
        require(queued["waiting_for"]?.stringValue?.hasPrefix("edit_clips") == true, "a pending switch reports the actual edit holding its line")
        require(job.project == nil, "the pending look does not claim a project and block the close it needs")
    }
    edit.letGo()
    let closed = lookAnswer(await closing.value)
    require(!closed.failed && OpenProjects.shared.project(shortID: closingProject.project.shortID) == nil,
            "the actual close_project completes after its edit, despite the pending look job")
    await call.value
    if let id = id ?? probe.answer.flatMap({ lookAnswer($0).object["job_id"]?.stringValue }) {
        let done = try await a.getJob(id, wait: 30)
        require(done.payload["status"] == "done" && done.images.count == 1
                    && done.payload["result"]?["project"] == .string(b.project.shortID),
                "after a real close, the remembered implicit look reads the remaining current project")
    }
    await settle()
}

/// Cleanup when testing the old route: it may start a job only after the held switch was released.
@MainActor private func drainLateAnswer(_ probe: RouterSwitchProbe, as project: LookProject) async {
    guard let id = probe.answer.flatMap({ lookAnswer($0).object["job_id"]?.stringValue }) else { return }
    _ = try? await project.getJob(id, wait: 30)
}
