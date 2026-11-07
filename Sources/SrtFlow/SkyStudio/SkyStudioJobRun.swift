import Foundation

// MARK: - 交给 Sky Studio 一件活，等它做完
//
// 管什么：提交 → 照 `poll_after_seconds` 问（没有长轮询）→ 做完回最后那一份状态（带成品）。
// - **同时开着的满了**（`too_many_jobs`，每个账号最多 `max_running_jobs` 个，现在 3）：在本机等着，隔一会儿用**同一个
//   idempotency_key** 再交（服务器认得出是同一个，不会扣两次）。提交断网不重放收费 POST。
// - **提交不跟着取消**：请求发出去一半被掐断，服务器那边可能已经扣了钱、建了任务；让它回来，拿到任务号再按下面的规矩停。
// - **问的时候断网几次不算失败**：活在服务器上照做（连着问不到才算）。
// - **Task 被取消 = 用户要停**：只有排着队的能取消（退钱）；已经开始的取消不了（`not_cancellable`），照实说：积分花了，成品照样进作品库。
//   取消请求在不继承取消的 Task 里发（调用者已经被取消了，网络请求一看见取消就不发）。
//   **取消不了、取消没送到的那单接着在后台查到 done / failed**（`followToEnd`，不下载）：Sky Studio 有人查的时候才把成品存进作品库、
//   把它从「同时开着的」里拿掉，没人查要等它的兜底几个小时（2026-10-28 真积分测试撞上的）。
// - 等多久：这里最多等 5 小时；经过多久都不证明供应商失败或已退款。
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

    let api: SkyStudioAPI
    let key: String
    /// 等（秒）。自检换成不真睡的。
    var sleep: @Sendable (Double) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    /// 最多等多久（秒）。
    var maxWait: Double = 5 * 3600
    /// 停不下来的那单交给谁接着查。nil = 不继承取消的后台任务里 `followToEnd`；自检换成只记下任务号的。
    var onUnstoppable: (@Sendable (String) -> Void)?
    /// 需要可恢复的调用方可先持久化原单身份；完成回调后才继续轮询 / 返回，避免旧进度晚写覆盖恢复结果。
    var checkpoint: (@Sendable (SkyStudioJobStatus) async throws -> Void)?
    /// 每次真正 POST（包括容量重试）前核对易变的调用方状态；nil 保持普通生成原来的流程。
    var beforeSubmit: (@Sendable () async throws -> Void)?
    /// 原生角色任务不能取消；停止本机等待也不能向 /cancel 发送请求。
    var cancellable = true

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
        return try await follow(submitted, deadline: deadline, onUpdate: onUpdate)
    }

    /// 恢复已知原单：只 GET，沿用同一套轮询 / 取消规则，永不重新 POST。
    func resume(_ jobID: String, onUpdate: @escaping @Sendable (Update) -> Void = { _ in }) async throws -> SkyStudioJobStatus {
        let original = try await api.job(jobID, key: key)
        try await report(original, onUpdate: onUpdate)
        return try await follow(original, deadline: Date().addingTimeInterval(maxWait), onUpdate: onUpdate)
    }

    // MARK: 交

    private func submit(
        _ request: SkyStudioJobRequest, deadline: Date, onUpdate: @escaping @Sendable (Update) -> Void
    ) async throws -> SkyStudioJobStatus {
        while true {
            if Task.isCancelled { throw beforeSubmit == nil ? SkyStudioJobError.stopped(.nothingCharged) : .notSubmitted("Cancelled before Sky Studio accepted the operation; no new POST was sent.") }
            try await validateBeforeSubmit()
            let api = self.api, key = self.key
            let attempt = await Task.detached { () -> Result<SkyStudioJobStatus, Error> in
                do { return .success(try await api.submit(request, key: key)) } catch { return .failure(error) }
            }.value
            switch attempt {
            case .success(let status):
                try await report(status, onUpdate: onUpdate)
                // 交上了才发现用户要停：按任务号停。
                if Task.isCancelled { throw await stop(status.jobID) }
                return status
            case .failure(SkyStudioFailure.network(let detail)):
                // 丢失响应不证明没扣费。保留原 key，禁止自动重放收费 POST。
                throw SkyStudioJobError.request(.network(detail))
            case .failure(SkyStudioFailure.server(let error)) where error.fields["job_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false:
                // 拒绝 / 未知应答已给原任务号：先交出身份，只 GET 这一单；绝不再 POST 或切模型。
                let id = error.fields["job_id"]!.stringValue!
                var known = SkyStudioJobStatus(jobID: id, state: nil)
                known.billing = SkyStudioBilling(error.fields["billing"])
                try await report(known, onUpdate: onUpdate)
                if Task.isCancelled { throw await stop(id) }
                let recovered: SkyStudioJobStatus
                let originalFailure = SkyStudioFailure.server(error)
                do { recovered = try await api.job(id, key: key) }
                catch { throw SkyStudioJobError.request(originalFailure) }
                try await report(recovered, onUpdate: onUpdate)
                return recovered
            case .failure(SkyStudioFailure.server(let error)) where SkyStudioJobAdmission.slotRefusal(error):
                onUpdate(.waitingForSlot(running: error.fields["running"]?.intValue, limit: error.fields["limit"]?.intValue))
                guard Date() < deadline else {
                    throw beforeSubmit == nil ? SkyStudioJobError.timedOut : .notSubmitted("No slot became available before the deadline; Sky Studio did not accept the operation.")
                }
                do { try await sleep(Self.slotRetrySeconds) }
                catch { throw beforeSubmit == nil ? SkyStudioJobError.stopped(.nothingCharged) : .notSubmitted("Cancelled while waiting for a slot; Sky Studio did not accept the operation.") }
            case .failure(let failure as SkyStudioFailure):
                throw SkyStudioJobError.request(failure)
            case .failure(let error):
                throw SkyStudioJobError.request(.network(error.localizedDescription))
            }
        }
    }

    private func validateBeforeSubmit() async throws {
        guard let beforeSubmit else { return }
        do {
            try await beforeSubmit()
            try Task.checkCancellation() // 取消也可能在调用方等待钥匙串/工程核对时到达。
        } catch {
            let reason = error is CancellationError ? "Cancelled before Sky Studio accepted the operation; no new POST was sent."
                : (error as? SkyStudioJobError)?.message ?? error.localizedDescription
            throw SkyStudioJobError.notSubmitted(reason)
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
                guard current.result != nil || (current.characterID != nil && current.characterStatus == "ready") else { throw SkyStudioJobError.badAnswer("a finished job without a result") }
                return current
            case .failed?:
                throw SkyStudioJobError.failed(current.failure ?? SkyStudioJobFailure(message: current.error ?? "Sky Studio could not make it.", jobID: current.jobID))
            case .cancelled?:
                if current.billing?.returnedAll == true { throw SkyStudioJobError.stopped(.nothingCharged) }
                throw SkyStudioJobError.failed(current.failure ?? SkyStudioJobFailure(message: "Cancellation acknowledged; billing remains unconfirmed.", jobID: current.jobID))
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
                try await report(next, onUpdate: onUpdate)
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

    private func report(_ status: SkyStudioJobStatus, onUpdate: @Sendable (Update) -> Void) async throws {
        onUpdate(.status(status))
        try await checkpoint?(status)
    }

    /// 原单已经明确真人参考拒绝，但退款记录可能晚到；只查这个 job_id，绝不重新 POST。
    func waitForRefund(_ failure: SkyStudioJobFailure, checks: Int = 8) async throws -> SkyStudioJobFailure {
        guard failure.isRealPersonRefusal, !failure.creditsReturned, let id = failure.jobID else { return failure }
        var latest = failure
        for _ in 0..<checks {
            try await sleep(Self.defaultPollSeconds)
            try Task.checkCancellation()
            do {
                let status = try await api.job(id, key: key)
                if status.state == .failed, let proof = status.failure {
                    latest = proof
                    if proof.creditsReturned { return proof }
                }
            } catch is CancellationError { throw CancellationError() }
            catch SkyStudioFailure.network { continue }
            catch { break }
        }
        return latest
    }

    // MARK: 停

    /// 用户要停：排着队的替它取消（退钱）；开始了的取消不了；问不到就说不准。后两种那单在服务器上照做，交出去接着查到底。
    private func stop(_ jobID: String) async -> SkyStudioJobError {
        if !cancellable { keepFollowing(jobID); return .stopped(.characterContinuing) }
        let api = self.api, key = self.key
        let outcome = await Task.detached { try? await api.cancel(jobID, key: key) }.value
        switch outcome {
        case .cancelled?:
            // 取消应答仅代表请求已接受；再读原任务的结算证据。
            let status = await Task.detached { try? await api.job(jobID, key: key) }.value
            if status?.billing?.returnedAll == true { return .stopped(.nothingCharged) }
            keepFollowing(jobID)
            return .stopped(.unknown)
        case .notCancellable?:
            keepFollowing(jobID)
            return .stopped(.alreadyStarted)
        case nil:
            keepFollowing(jobID)
            return .stopped(.unknown)
        }
    }

    /// 调用者已经被取消了：在不继承取消的后台任务里查。
    private func keepFollowing(_ jobID: String) {
        if let onUnstoppable { return onUnstoppable(jobID) }
        let run = self
        Task.detached(priority: .utility) { await run.followToEnd(jobID) }
    }

    /// 停不下来的那单：照 poll_after_seconds 一直问到 done / failed / cancelled，什么都不拿（不下载、不换源）。
    /// 等满 maxWait、连着问不到 networkMisses 次、服务器回了别的错就算了：剩下的交给 Sky Studio 自己的兜底。
    func followToEnd(_ jobID: String) async {
        let deadline = Date().addingTimeInterval(maxWait)
        var serverSays: Double?
        var misses = 0
        while Date() < deadline {
            do { try await sleep(Self.pollSeconds(serverSays)) } catch { return }
            do {
                let status = try await api.job(jobID, key: key)
                misses = 0
                guard status.state == .queued || status.state == .running else { return }
                serverSays = status.pollAfterSeconds
            } catch SkyStudioFailure.network(_) {
                misses += 1
                guard misses < Self.networkMisses else { return }
            } catch {
                return
            }
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
        case characterContinuing
    }

    /// 服务器说没做成；只按明确证据认退款。
    case failed(SkyStudioJobFailure)
    case stopped(Stop)
    /// 调用方的 POST 前核对拒绝；之前最多只有明确的未准入容量拒绝，绝非丢失应答。
    case notSubmitted(String)
    /// 问 Sky Studio 没问成（Key、余额、版本、参数、限流、网络……）。服务器的 message 原样带着。
    case request(SkyStudioFailure)
    /// 回的不像话。
    case badAnswer(String)
    /// 等了太久：活在服务器上照做，做完会进作品库。
    case timedOut

    static func failed(_ text: String) -> Self { .failed(SkyStudioJobFailure(message: text)) }

    var failure: SkyStudioJobFailure? {
        switch self {
        case .failed(let value): return value
        case .request(.server(let error)): return SkyStudioJobFailure(message: error.message, fields: error.fields.merging(["code": .string(error.code)]) { a, _ in a })
        default: return nil
        }
    }

    func canRefund(beforeAccepted: Bool) -> Bool {
        if case .notSubmitted = self { return beforeAccepted }
        if let billing = failure?.billing { return billing.returnedAll }
        if case .request(.server(let error)) = self, error.code == "character_checkpoint_failed",
           error.fields["credits_reserved"] == 0, error.fields["submission_state"] == "not_submitted" { return true }
        if failure?.creditsReturned == true { return true }
        if case .stopped(.nothingCharged) = self { return true }
        guard beforeAccepted, case .request(.server(let error)) = self, failure?.isRealPersonRefusal != true,
              !SkyStudioJobAdmission.hasAdmissionEvidence(error) else { return false }
        if error.code == SkyStudioServerError.tooManyJobs { return SkyStudioJobAdmission.slotRefusal(error) }
        return SkyStudioJobAdmission.rejectedCodes.contains(error.code)
    }

    /// 只保明确未受理的代码；矛盾的扣费证据、真人拒绝和已知任务号绝不改装成“没交上”。
    var rejectedBeforeAdmissionCode: String? {
        if case .notSubmitted = self { return "local_not_sent" }
        guard case .request(.server(let error)) = self, SkyStudioJobAdmission.rejectedCodes.contains(error.code),
              !SkyStudioJobAdmission.hasAdmissionEvidence(error), failure?.isRealPersonRefusal != true, canRefund(beforeAccepted: true) else { return nil }
        return error.code
    }

    var message: String {
        switch self {
        case .notSubmitted(let reason): return reason
        case .failed(let detail):
            return "Sky Studio job: \(detail.message) " + (detail.billing?.message
                ?? "Billing is not confirmed; query the original job and do not regenerate automatically.")
        case .stopped(.nothingCharged):
            return "Stopped before Sky Studio started it; no credits were spent."
        case .stopped(.alreadyStarted):
            return "Sky Studio had already started it, so it could not be cancelled. Keep querying the original job's billing; "
                + "a successful result is saved to the user's Sky Studio library."
        case .stopped(.unknown):
            return "SkyCut could not reach Sky Studio to cancel it; it may still finish and appear in the user's Sky Studio library."
        case .stopped(.characterContinuing):
            return "Character jobs cannot be cancelled. Only local waiting stopped; query this original job to recover its Character and billing. No cancellation request was sent."
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
