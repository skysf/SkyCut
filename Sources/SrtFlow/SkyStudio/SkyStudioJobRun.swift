import Foundation

// MARK: - 交给 Sky Studio 一件活，等它做完
//
// 管什么：提交 → 照 `poll_after_seconds` 问（没有长轮询）→ 做完回最后那一份状态（带成品）。
// - **同时开着的满了**（`too_many_jobs`，每个账号最多 `max_running_jobs` 个，现在 3）：在本机等着，隔一会儿用**同一个
//   idempotency_key** 再交（服务器认得出是同一个，不会扣两次）。交的时候断网也一样再交两次。
// - **提交不跟着取消**：请求发出去一半被掐断，服务器那边可能已经扣了钱、建了任务；让它回来，拿到任务号再按下面的规矩停。
// - **问的时候断网几次不算失败**：活在服务器上照做（连着问不到才算）。
// - **Task 被取消 = 用户要停**：只有排着队的能取消（退钱）；已经开始的取消不了（`not_cancellable`），照实说：积分花了，成品照样进作品库。
//   取消请求在不继承取消的 Task 里发（调用者已经被取消了，网络请求一看见取消就不发）。
// - 等多久：服务器自己会收掉没人管的任务（upscale 245 分钟、别的 35 分钟，失败并退钱），这里最多等 5 小时。
// 合同：Sky Studio 仓库 docs/agents/skycut-api.md「POST /jobs」「GET /jobs/{id}」「POST /jobs/{id}/cancel」。
// 不管什么：传文件（SkyStudioAPI.upload / download）、钱花不花（每日上限）、每种活怎么拼参数、进度怎么画。

struct SkyStudioJobRun: Sendable {
    /// 满了之后隔多久再交。
    static let slotRetrySeconds: Double = 15
    /// 服务器没说隔多久再问时按这个；说了也夹在这两头之间。
    static let defaultPollSeconds: Double = 15
    static let pollRange: ClosedRange<Double> = 2...60
    /// 连着问不到几次才算失败（问的间隔照旧，十次 ≈ 两三分钟）。
    static let networkMisses = 10
    /// 交的时候断网再交几次。
    static let submitRetries = 2

    let api: SkyStudioAPI
    let key: String
    /// 等（秒）。自检换成不真睡的。
    var sleep: @Sendable (Double) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    /// 最多等多久（秒）。
    var maxWait: Double = 5 * 3600

    init(api: SkyStudioAPI, key: String) {
        self.api = api
        self.key = key
    }

    enum Update: Equatable, Sendable {
        /// 同时开着的满了，在本机等着再交。
        case waitingForSlot(running: Int?, limit: Int?)
        /// 交上了 / 问到了一次。
        case status(SkyStudioJobStatus)
    }

    /// 交上去、等它做完；回的是做完那一刻的状态（`state == .done`、带 `result`）。
    func run(_ request: SkyStudioJobRequest, onUpdate: @escaping @Sendable (Update) -> Void = { _ in }) async throws -> SkyStudioJobStatus {
        let deadline = Date().addingTimeInterval(maxWait)
        let submitted = try await submit(request, deadline: deadline, onUpdate: onUpdate)
        onUpdate(.status(submitted))
        return try await follow(submitted, deadline: deadline, onUpdate: onUpdate)
    }

    // MARK: 交

    private func submit(
        _ request: SkyStudioJobRequest, deadline: Date, onUpdate: @escaping @Sendable (Update) -> Void
    ) async throws -> SkyStudioJobStatus {
        var networkTries = 0
        while true {
            if Task.isCancelled { throw SkyStudioJobError.stopped(.nothingCharged) }
            let api = self.api, key = self.key
            let attempt = await Task.detached { () -> Result<SkyStudioJobStatus, Error> in
                do { return .success(try await api.submit(request, key: key)) } catch { return .failure(error) }
            }.value
            switch attempt {
            case .success(let status):
                // 交上了才发现用户要停：按任务号停。
                if Task.isCancelled { throw await stop(status.jobID) }
                return status
            case .failure(SkyStudioFailure.server(let error)) where error.code == SkyStudioServerError.tooManyJobs:
                onUpdate(.waitingForSlot(running: error.fields["running"]?.intValue, limit: error.fields["limit"]?.intValue))
                guard Date() < deadline else { throw SkyStudioJobError.timedOut }
                do { try await sleep(Self.slotRetrySeconds) } catch { throw SkyStudioJobError.stopped(.nothingCharged) }
            case .failure(SkyStudioFailure.network(let detail)):
                networkTries += 1
                guard networkTries <= Self.submitRetries else { throw SkyStudioJobError.request(.network(detail)) }
                do { try await sleep(2) } catch { throw SkyStudioJobError.stopped(.unknown) }
            case .failure(let failure as SkyStudioFailure):
                throw SkyStudioJobError.request(failure)
            case .failure(let error):
                throw SkyStudioJobError.request(.network(error.localizedDescription))
            }
        }
    }

    // MARK: 等

    private func follow(
        _ submitted: SkyStudioJobStatus, deadline: Date, onUpdate: @escaping @Sendable (Update) -> Void
    ) async throws -> SkyStudioJobStatus {
        var current = submitted
        var misses = 0
        while true {
            switch current.state {
            case .done?:
                guard current.result != nil else { throw SkyStudioJobError.badAnswer("a finished job without a result") }
                return current
            case .failed?:
                throw SkyStudioJobError.failed(current.error ?? "Sky Studio could not make it.")
            case .cancelled?:
                throw SkyStudioJobError.stopped(.nothingCharged)
            case .queued?, .running?:
                break
            case nil:
                throw SkyStudioJobError.badAnswer("a job status SkyCut does not know")
            }
            guard Date() < deadline else { throw SkyStudioJobError.timedOut }
            do {
                try await sleep(Self.pollSeconds(current.pollAfterSeconds))
            } catch {
                throw await stop(current.jobID)
            }
            do {
                let next = try await api.job(current.jobID, key: key)
                misses = 0
                current = next
                onUpdate(.status(next))
            } catch is CancellationError {
                throw await stop(current.jobID)
            } catch SkyStudioFailure.network(let detail) {
                misses += 1
                if Task.isCancelled { throw await stop(current.jobID) }
                guard misses < Self.networkMisses else { throw SkyStudioJobError.request(.network(detail)) }
            } catch let failure as SkyStudioFailure {
                throw SkyStudioJobError.request(failure)
            }
        }
    }

    static func pollSeconds(_ serverSays: Double?) -> Double {
        min(pollRange.upperBound, max(pollRange.lowerBound, serverSays ?? defaultPollSeconds))
    }

    // MARK: 停

    /// 用户要停：排着队的替它取消（退钱）；开始了的取消不了；问不到就说不准。
    private func stop(_ jobID: String) async -> SkyStudioJobError {
        let api = self.api, key = self.key
        let outcome = await Task.detached { try? await api.cancel(jobID, key: key) }.value
        switch outcome {
        case .cancelled?: return .stopped(.nothingCharged)
        case .notCancellable?: return .stopped(.alreadyStarted)
        case nil: return .stopped(.unknown)
        }
    }
}

/// 一件活没做成 / 停下来了。`message` 是写给 AI 的英文（界面的话在各自的调用方按语言换）。
enum SkyStudioJobError: Error, Equatable, Sendable {
    enum Stop: Equatable, Sendable {
        /// 交上之前就停了，或者还排着队就取消了：积分没花（扣了的退回）。
        case nothingCharged
        /// 已经开始，取消不了：积分花了，成品照样会进用户的 Sky Studio 作品库。
        case alreadyStarted
        /// 取消请求没送到：可能还在做，做完会进作品库。
        case unknown
    }

    /// 服务器说没做成（积分已经退回，只退一次）。
    case failed(String)
    case stopped(Stop)
    /// 问 Sky Studio 没问成（Key、余额、版本、参数、限流、网络……）。服务器的 message 原样带着。
    case request(SkyStudioFailure)
    /// 回的不像话。
    case badAnswer(String)
    /// 等了太久：活在服务器上照做，做完会进作品库。
    case timedOut

    var message: String {
        switch self {
        case .failed(let detail):
            return "Sky Studio could not make it: \(detail) The credits were refunded."
        case .stopped(.nothingCharged):
            return "Stopped before Sky Studio started it; no credits were spent."
        case .stopped(.alreadyStarted):
            return "Sky Studio had already started it, so it could not be cancelled: the credits are spent and the result will still "
                + "appear in the user's Sky Studio library."
        case .stopped(.unknown):
            return "SkyCut could not reach Sky Studio to cancel it; it may still finish and appear in the user's Sky Studio library."
        case .request(.server(let error)):
            return error.message
        case .request(.network(let detail)):
            return "Could not reach Sky Studio: \(detail)"
        case .request(.badAnswer(let status)):
            return "Sky Studio's answer was not what SkyCut expected (HTTP \(status))."
        case .badAnswer(let detail):
            return "Sky Studio's answer was not what SkyCut expected (\(detail))."
        case .timedOut:
            return "Sky Studio has not finished it after 5 hours, so SkyCut stopped waiting; it may still finish and appear in the "
                + "user's Sky Studio library."
        }
    }
}
