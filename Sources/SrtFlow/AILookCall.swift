import Foundation
import SrtFlowMCPKit

// MARK: - A look never leaves the AI waiting for minutes: after `answerWithin` seconds it is a job
//
// What it does: one look call, from its place in the router's lines (AICallLines) to its answer. The look runs in its own task and the
// call waits for it up to `answerWithin` (25 s). Done by then: the answer exactly as before. Not done (still waiting in its project's
// line, or still rendering): the call answers with a job (AIJobs kind `look`): job_id and status running, or queued with queue_position
// and waiting_for (which call holds the line). The look goes on; when it is done its result (the same JSON as a direct answer) is the
// job's `result` and its picture comes with get_job. cancel_job, or the user's Stop on that project, cancels it: still waiting, it never
// starts; running, its task is cancelled and the look stops at the next frame.
// Why (docs/bugfixes/2026-11-17-look-hangs-and-dropped-calls.md): a slow look used to hold its project's line until it was done; the AI
// helper gives up on any call after 2 minutes, so the looks queued behind it were dropped and its own result, written later into a
// closed connection, was lost.
// What it does not do: the look itself (AILookTool), which lines (AIToolRouter.queueKeys), the lines (AICallLines), jobs (AIJobs).

@MainActor
final class AILookCall {
    /// How long a look call waits for the look before it answers with a job. Clients give up on a call after about a minute and the
    /// helper after two; checks shorten it.
    static var answerWithin: TimeInterval = 25

    typealias Work = @MainActor (_ begin: @escaping @Sendable () -> Bool) async -> AIToolRouter.Answer

    static let nextStep = "This look is taking longer than usual (it may be waiting behind earlier calls on this project, or the Mac "
        + "is busy). Call get_job with this job_id and wait_seconds 30 until the status is done: its result and the picture come back "
        + "there. Do not send the same look again; cancel_job stops it."

    private let place: AICallLines.Place
    private let lines: AICallLines
    private let gate: Gate
    private var task: Task<Void, Never>?
    private var answer: AIToolRouter.Answer?
    private var job: AIJobs.Job?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(place: AICallLines.Place, lines: AICallLines, begin: @escaping @Sendable () -> Bool) {
        self.place = place
        self.lines = lines
        gate = Gate(helper: begin)
    }

    /// Run a look that has joined its lines (`place`). `begin` is the helper's "still waiting?" (AIBridgeCalls); `work` runs the call
    /// (the router's execute) and must ask the `begin` it is given before doing anything.
    static func run(
        _ place: AICallLines.Place, in lines: AICallLines, begin: @escaping @Sendable () -> Bool, work: @escaping Work
    ) async -> AIToolRouter.Answer {
        let call = AILookCall(place: place, lines: lines, begin: begin)
        call.start(work)
        if await call.waitForAnswer(upTo: answerWithin), let answer = call.answer { return answer }
        return call.becomeJob()
    }

    private func start(_ work: @escaping Work) {
        task = Task { @MainActor [place, lines, gate] in
            await lines.waitForTurn(place)
            let answer = await AICallLines.$current.withValue(place) { await work(gate.begin) }
            place.letGo()
            self.finished(answer)
        }
    }

    /// Up to `seconds`: true once the look has answered.
    private func waitForAnswer(upTo seconds: TimeInterval) async -> Bool {
        if answer == nil {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, seconds)))
                    self?.wake()
                }
            }
        }
        return answer != nil
    }

    private func wake() {
        let woken = waiters
        waiters = []
        woken.forEach { $0.resume() }
    }

    private func finished(_ answer: AIToolRouter.Answer) {
        self.answer = answer
        wake()
        guard let job, job.status == .running else { return }
        let result = Self.split(answer.result)
        if result.failed {
            AIJobs.shared.finish(job, .failed, message: result.text)
        } else {
            job.images = result.images
            AIJobs.shared.finish(job, .done, detail: ["result": result.payload])
        }
    }

    /// The call answers with a job; the look goes on (or keeps waiting for its turn).
    private func becomeJob() -> AIToolRouter.Answer {
        gate.becomeJob()
        let job = AICallContext.$current.withValue(Self.owner(of: place)) {
            AIJobs.shared.start(.look, progress: { nil }, cancel: { [weak self] in self?.cancel() })
        }
        job.inLine = { [weak self] in self?.lineStanding() }
        self.job = job
        var payload = AIJobs.shared.json(job).objectValue ?? [:]
        payload["next_step"] = .string(Self.nextStep)
        return AIToolRouter.Answer(result: AIToolResult.ok(.object(payload)).json, project: nil)
    }

    /// cancel_job / Stop: still waiting → it never starts; running → stop the look at its next frame.
    private func cancel() {
        guard let job, job.status == .running else { return }
        gate.cancel()
        if place.startedAt == nil {
            AIJobs.shared.finish(job, .cancelled, message: "Cancelled while waiting in line; this look never started.")
        } else {
            task?.cancel()
            AIJobs.shared.finish(job, .cancelled, message: "Cancelled; the look stopped before it finished.")
        }
    }

    private func lineStanding() -> (position: Int, waitingFor: String?)? {
        guard let standing = lines.standing(of: place) else { return nil }
        return (standing.position, standing.holder.map { Self.describe($0, for: place.session) })
    }

    /// "edit_clip from this AI session, running for 41 s".
    static func describe(_ holder: AICallLines.Place, for session: String) -> String {
        let who = holder.session == session ? "this AI session" : "another AI session (\(holder.client))"
        guard let started = holder.startedAt else { return "\(holder.tool) from \(who), itself still waiting" }
        return "\(holder.tool) from \(who), running for \(Int(Date().timeIntervalSince(started).rounded())) s"
    }

    /// Who the job belongs to (`AIJobs.Job` reads it from the call context): its project when the look is in a project's line, and the
    /// project whose Stop stops it, like the router's own calls (a call without a project stops with its session's last project).
    private static func owner(of place: AICallLines.Place) -> AICallContext {
        let project = place.keys.first { $0.hasPrefix("project:") }.map { String($0.dropFirst("project:".count)) }
        let stops = project ?? AIProjectSessions.shared.projects(of: place.session).last?.shortID ?? OpenProjects.shared.primary.shortID
        return AICallContext(session: place.session, client: place.client, project: project, stopsWith: stops)
    }

    /// A finished look as the job keeps it: the result JSON (or its text), its pictures, and whether it failed.
    nonisolated static func split(_ result: JSONValue) -> (payload: JSONValue, text: String, images: [Data], failed: Bool) {
        let content = result["content"]?.arrayValue ?? []
        let text = content.first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue ?? ""
        let images = content.compactMap { item -> Data? in
            guard item["type"]?.stringValue == "image", let data = item["data"]?.stringValue else { return nil }
            return Data(base64Encoded: data)
        }
        let payload = (try? JSONValue.decode(Data(text.utf8))) ?? .string(text)
        return (payload, text, images, result["isError"]?.boolValue == true)
    }

    /// May the look still start: before it is a job the helper decides (it may have stopped waiting, AIBridgeCalls); once it is a job
    /// only cancel_job / Stop do (the helper got its answer long ago).
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let helper: @Sendable () -> Bool
        private var isJob = false
        private var cancelled = false

        init(helper: @escaping @Sendable () -> Bool) {
            self.helper = helper
        }

        func becomeJob() { lock.withLock { isJob = true } }
        func cancel() { lock.withLock { cancelled = true } }

        var begin: @Sendable () -> Bool {
            { [self] in
                let (job, cancelled) = lock.withLock { (isJob, self.cancelled) }
                if cancelled { return false }
                return job || helper()
            }
        }
    }
}
