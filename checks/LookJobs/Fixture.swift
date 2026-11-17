import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Real background projects with synthetic one-keyframe clips, and a look call run the way the router runs it (AIToolRouter.handleRequest:
// join the project's line, AILookCall.run, the call asks `begin` first and runs the tool in its AICallContext).

/// What happened to one look call's work.
@MainActor final class LookProbe {
    var started = 0
    var skipped = 0
    var finished = 0
    var cancelled = 0
}

@MainActor struct LookProject {
    let project: VideoEditProject
    let session: String

    /// A background project of `session`: `count` clips of 2 s each from the synthetic files, one after another on V1.
    init(folder: URL, name: String, session: String, sources: [(URL, MediaInfo)], count: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let created = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent(name + ".skycut"), placement: .background) else {
            throw AIToolError(OpenProjects.shared.failure ?? "Could not create the isolated project \(name)")
        }
        var state = TimelineState()
        state.mainMagnet = false
        for index in 0..<count {
            let (url, info) = sources[index % sources.count]
            // Late in each file, far from its only keyframe: every frame is decoded from the clip's start.
            state.mainClips.append(EditClip(sourceURL: url, sourceStart: 3.8, sourceDuration: 2, timelineStart: Double(index) * 2, info: info))
        }
        created.restoreTimeline(state)
        project = created
        self.session = session
    }

    var context: AICallContext {
        AICallContext(session: session, client: "LookJobCheck", project: project.shortID, stopsWith: project.shortID)
    }

    /// One look call as the router runs it: join the project's line, then AILookCall.
    func look(_ arguments: JSONValue, in lines: AICallLines, probe: LookProbe) async -> AIToolRouter.Answer {
        let place = lines.join(["project:" + project.shortID], tool: "look", session: session, client: "LookJobCheck")
        return await AILookCall.run(place, in: lines, begin: { true }, work: work(arguments, probe: probe))
    }

    /// The router's execute for a look: ask `begin` first, then the tool in this call's context.
    func work(_ arguments: JSONValue, probe: LookProbe) -> AILookCall.Work {
        let project = project
        let context = context
        return { begin in
            guard begin() else {
                probe.skipped += 1
                return AIToolRouter.Answer(result: MCPBridge.textResult("Not done: the AI helper stopped waiting for this call.", isError: true))
            }
            probe.started += 1
            do {
                let result = try await AICallContext.$current.withValue(context) { try await AILookTool.look(AIToolArguments(arguments), project) }
                probe.finished += 1
                return AIToolRouter.Answer(result: result.json)
            } catch is CancellationError {
                probe.cancelled += 1
                return AIToolRouter.Answer(result: MCPBridge.textResult("cancelled", isError: true))
            } catch {
                return AIToolRouter.Answer(result: MCPBridge.textResult("SkyCut could not do that: \(error)", isError: true))
            }
        }
    }

    /// get_job / cancel_job as this session calls them.
    func getJob(_ id: String, wait: Double = 0) async throws -> AIToolResult {
        try await AICallContext.$current.withValue(context) {
            try await AIExportTools.job(AIToolArguments(["job_id": .string(id), "wait_seconds": .number(wait)]))
        }
    }

    func cancelJob(_ id: String, as other: String? = nil) throws -> AIToolResult {
        var caller = context
        if let other { caller.session = other }
        return try AICallContext.$current.withValue(caller) { try AIExportTools.cancel(AIToolArguments(["job_id": .string(id)])) }
    }
}

/// The JSON object and pictures of an answer (a look's, or a job's).
func lookAnswer(_ answer: AIToolRouter.Answer) -> (object: [String: JSONValue], images: Int, failed: Bool) {
    let split = AILookCall.split(answer.result)
    return (split.payload.objectValue ?? [:], split.images.count, split.failed)
}

/// Twelve moments across `from` (0.17 s apart, like the reports' looks).
func twelve(from start: Double) -> JSONValue {
    .array((0..<12).map { .number(((start + Double($0) * 0.17) * 100).rounded() / 100) })
}
