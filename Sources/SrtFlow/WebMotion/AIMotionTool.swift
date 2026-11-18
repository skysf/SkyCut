import Foundation
import SrtFlowMCPKit

// set_motion: approve an AI-written page when needed, render through the shared UI service and return the clip or its job.
@MainActor
enum AIMotionTool {
    static var answerWithin: Double = 25

    static func set(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let request = try AIMotionRequest(args, state: project.state, playhead: project.clock.time)
        if let question = try AIMotionApproval.check(args, request: request, project: project) { return question }
        let call = Call(request: request, project: project)
        call.start()
        if let job = call.job { await AIJobs.shared.wait(for: job, seconds: answerWithin) }
        if let result = call.result { return result }
        guard let job = call.job else { throw AIToolError("The motion job could not start.") }
        var payload = AIJobs.shared.json(job).objectValue ?? [:]
        payload["next_step"] = "Wait with get_job and wait_seconds 30. Its result includes the clip, render_seconds, checks and look_times. Do not submit this page again."
        return .ok(.object(payload))
    }

    @MainActor
    private final class Call {
        let request: AIMotionRequest
        let project: VideoEditProject
        let generation: Int
        var task: Task<Void, Never>?
        var job: AIJobs.Job?
        var result: AIToolResult?

        init(request: AIMotionRequest, project: VideoEditProject) {
            self.request = request
            self.project = project
            generation = project.documentGeneration
        }

        func start() {
            job = AIJobs.shared.start(.motion, progress: { nil }, cancel: { [weak self] in self?.task?.cancel() })
            task = Task { await self.run() }
            project.trackImportTask(task!)
        }

        private func run() async {
            guard let job else { return }
            do {
                guard project.isCurrentGeneration(generation), !Task.isCancelled else { throw CancellationError() }
                guard request.replacing == nil || (project.state.clip(with: request.replacing!) == request.expectedClip
                    && WebMotionSourceLane.capture(request.replacing, in: project.state) == request.expectedSourceLane) else {
                    throw AIToolError("The clip or its source track changed before rendering started; no edit was applied. Read get_timeline and retry.")
                }
                let placed = try await WebMotionActions.place(record: request.record, replacing: request.replacing,
                                                              at: request.at, hitAt: request.hitAt, preferring: request.resolvedTarget(in: project.state), project: project)
                var answer = AIMotionReport.success(placed, state: project.state)
                // A job may finish after the router has answered. Note and save the edit here exactly once in both cases.
                if request.expectedClip != placed.clip
                    || request.expectedSourceLane != WebMotionSourceLane.capture(placed.clip.id, in: project.state) {
                    AISession.shared.round(for: project).noteChange()
                    answer = await AIProjectTools.saveIfNeverSaved(project, after: answer)
                    answer = AIRoundVersions.reporting(project, in: answer)
                } else if case .object(var payload) = answer.payload {
                    payload["unchanged"] = true
                    answer.payload = .object(payload)
                }
                AIEditorPresenter.reveal(.init(clips: [placed.clip.id], time: placed.clip.timelineStart), project: project)
                answer.changedProject = false
                result = answer
                AIJobs.shared.finish(job, .done, detail: ["result": answer.payload])
            } catch {
                let answer = AIMotionReport.failure(error)
                result = answer
                let cancelled = Task.isCancelled || error is CancellationError
                AIJobs.shared.finish(job, cancelled ? .cancelled : .failed,
                                     message: answer.payload["error"]?.stringValue, detail: ["result": answer.payload])
            }
            task = nil
        }
    }
}
