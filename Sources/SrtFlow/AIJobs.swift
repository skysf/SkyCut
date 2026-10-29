import Foundation
import SrtFlowMCPKit

// MARK: - AI 起的长任务：导出、生成字幕、翻译、压缩、烧录、转写、找镜头、录屏
//
// 管什么：任务号、进度、结局。工具起了任务就立刻回任务号（客户端对一次调用大多只等一分钟），
// AI 用 get_job 等结果。结局在任务结束的**那一刻**记下（由各工具挂的完成回调写），
// 之后用户再手动导出一次、把导出器的状态换掉，也不会串到这个任务上。
// 不管什么：任务本身怎么跑（`VideoEditExporter`、`TranscriptionTask`、翻译服务）。

@MainActor
final class AIJobs {
    static let shared = AIJobs()

    enum Kind: String {
        case export, subtitles, translation, compress, transcript, shots, voices, generate, upscale, voiceover
        case burnIn = "burn_in"
        case screenRecording = "screen_recording"
    }

    enum Status: String {
        case running, done, failed, cancelled
    }

    final class Job {
        let id: String
        let kind: Kind
        let startedAt = Date()
        /// 跑着的时候的进度（0…1），读不到就是 nil。
        let progress: @MainActor () -> Double?
        /// 跑着的时候的明细（送 fal 的任务：`phase`、`queue_position`、`transfer_percent`、`phase_seconds`、`typical_seconds`，
        /// 见 `FalJobProgress.json`）；没有就是空。只在 running 时并进 `get_job` 的结果。
        let liveDetail: @MainActor () -> [String: JSONValue]
        /// 在等用户做一件事（比如在 macOS 的框里点「下载」）时的那句话；没在等就是 nil。
        /// AI 查进度时看到它，才会去告诉用户，而不是对着 0% 干等。
        let waitingForUser: @MainActor () -> String?
        let cancelAction: @MainActor () -> Void
        /// 起它的那一次调用落在哪个工程（短 id）、哪个会话（`AICallContext`）：关工程前看它有没有在跑的任务、
        /// cancel_job 只许取消自己会话的（方案 B.5）。不碰工程的任务（压缩、烧录、转写文件……）没有 `project`。
        let project: String?
        let session: String?
        /// 用户在哪个工程上按停止时它跟着停（方案 E 节）：碰工程的就是那个工程，不碰工程的是起它时这个会话最后打开的那个。
        let stopsWith: String?
        fileprivate(set) var status: Status = .running
        fileprivate(set) var message: String?
        fileprivate(set) var detail: JSONValue?
        fileprivate(set) var finishedAt: Date?

        init(
            id: String, kind: Kind, progress: @escaping @MainActor () -> Double?, liveDetail: @escaping @MainActor () -> [String: JSONValue],
            waitingForUser: @escaping @MainActor () -> String?, cancel: @escaping @MainActor () -> Void
        ) {
            self.id = id
            self.kind = kind
            self.progress = progress
            self.liveDetail = liveDetail
            self.waitingForUser = waitingForUser
            self.cancelAction = cancel
            project = AICallContext.current?.project
            session = AICallContext.current?.session
            stopsWith = AICallContext.current?.stopsWith
        }
    }

    private var jobs: [String: Job] = [:]
    private var counter = 0

    private init() {}

    func start(
        _ kind: Kind, progress: @escaping @MainActor () -> Double?,
        liveDetail: @escaping @MainActor () -> [String: JSONValue] = { [:] },
        waitingForUser: @escaping @MainActor () -> String? = { nil },
        cancel: @escaping @MainActor () -> Void
    ) -> Job {
        counter += 1
        let job = Job(
            id: "\(kind.rawValue)-\(counter)", kind: kind, progress: progress, liveDetail: liveDetail,
            waitingForUser: waitingForUser, cancel: cancel
        )
        jobs[job.id] = job
        return job
    }

    /// 任务结束时由起它的工具调用一次。只认第一次。
    func finish(_ job: Job, _ status: Status, message: String? = nil, detail: JSONValue? = nil) {
        guard job.status == .running else { return }
        job.status = status
        job.message = message
        job.detail = detail
        job.finishedAt = Date()
    }

    var running: [Job] {
        jobs.values.filter { $0.status == .running }.sorted { $0.startedAt < $1.startedAt }
    }

    func job(_ id: String) -> Job? { jobs[id] }

    /// 等到任务结束或者超时（最多 30 秒，给客户端的一分钟留足余量）。
    func wait(for job: Job, seconds: Double) async {
        let deadline = Date().addingTimeInterval(min(max(seconds, 0), 30))
        while job.status == .running, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func cancel(_ job: Job) {
        guard job.status == .running else { return }
        job.cancelAction()
    }

    /// 用户在这个工程的横幅上按了停止：跟着它停的任务都取消，回取消了哪几个（任务号）。
    @discardableResult
    func cancel(stoppingWith project: String) -> [String] {
        let stopping = running.filter { $0.stopsWith == project }
        for job in stopping { job.cancelAction() }
        return stopping.map(\.id)
    }

    func json(_ job: Job) -> JSONValue {
        var object: [String: JSONValue] = [
            "job_id": .string(job.id),
            "kind": .string(job.kind.rawValue),
            "status": .string(job.status.rawValue),
            "elapsed_seconds": .number(((job.finishedAt ?? Date()).timeIntervalSince(job.startedAt)).rounded())
        ]
        if let project = job.project { object["project"] = .string(project) }
        // 还在排队（导出、转写、翻译一次一个，AIWorkQueue）：报排在第几，进度还没有。
        if job.status == .running, let position = AIWorkQueue.shared.position(of: job.id) {
            object["status"] = "queued"
            object["queue_position"] = .number(Double(position))
            return .object(object)
        }
        if job.status == .running, let progress = job.progress() {
            object["progress"] = .number((progress * 100).rounded() / 100)
        }
        if job.status == .running {
            object.merge(job.liveDetail()) { current, _ in current }
        }
        if job.status == .running, let waiting = job.waitingForUser() {
            object["waiting_for_user"] = .string(waiting)
        }
        if let message = job.message { object["message"] = .string(message) }
        if let detail = job.detail, case .object(let extra) = detail {
            object.merge(extra) { current, _ in current }
        }
        return .object(object)
    }
}
