import Foundation

// 一次运行的 Key 缓存与有界静默读；不直接调用 Security。原生读由 KeychainSecret 的专用执行器承接。
// 超时只结束调用者的等待，不能硬中断 Security；保留那次读取，迟到成功仍缓存，其他调用立即回需要授权。
actor KeychainSecretCache {
    typealias Reader = @Sendable (KeychainSecret.Access) async -> KeychainSecret.ReadResult
    private let reader: Reader
    private let timeout: Duration
    private var cached: String?
    private var generation = 0
    private var silentRead: UUID?
    private var waiter: CheckedContinuation<KeychainSecret.ReadResult, Never>?
    private var deadline: Task<Void, Never>?
    private var interactiveRead: Task<KeychainSecret.ReadResult, Never>?
    private var interactiveGeneration = 0

    init(_ secret: KeychainSecret) {
        reader = { await secret.read($0) }
        timeout = .seconds(3)
    }

    /// 逻辑自检注入读取器，不读用户的钥匙串。
    init(timeout: Duration, reader: @escaping Reader) {
        self.reader = reader
        self.timeout = timeout
    }

    func keyWithoutPrompt() async -> KeychainSecret.ReadResult {
        if let cached { return .key(cached) }
        guard silentRead == nil, interactiveRead == nil else { return .needsPermission }
        let id = UUID(), observedGeneration = generation
        silentRead = id
        return await withCheckedContinuation { continuation in
            waiter = continuation
            let reader = reader
            Task {
                let result = await reader(.silent)
                complete(id, generation: observedGeneration, result: result)
            }
            deadline = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                expire(id)
            }
        }
    }

    /// 只供用户点按钮后调用；等待交互读时 actor 仍能服务静默调用，不让 AI 排在系统框后面。
    func key(willAsk: @escaping @MainActor @Sendable () -> Void = {}) async -> KeychainSecret.ReadResult {
        if let cached { return .key(cached) }
        if let interactiveRead {
            let observed = interactiveGeneration
            return current(await interactiveRead.value, generation: observed)
        }
        let quietGeneration = generation
        let quiet = await keyWithoutPrompt()
        guard generation == quietGeneration else { return current(quiet, generation: quietGeneration) }
        guard quiet == .needsPermission else { return quiet }
        if let interactiveRead {
            let observed = interactiveGeneration
            return current(await interactiveRead.value, generation: observed)
        }
        let reader = reader, observedGeneration = generation
        let task = Task {
            await willAsk()
            return await reader(.interactive)
        }
        interactiveRead = task
        interactiveGeneration = observedGeneration
        let result = await task.value
        interactiveRead = nil
        guard generation == observedGeneration else { return current(result, generation: observedGeneration) }
        if case .key(let key) = result { cached = key }
        return result
    }

    /// 存换删后让迟到的旧读取作废，不允许它复活已删除的 Key 或覆盖新 Key。
    func remember(_ key: String?) {
        generation += 1
        cached = key
        finish(key.map(KeychainSecret.ReadResult.key) ?? .missing)
    }

    private func complete(_ id: UUID, generation observed: Int, result: KeychainSecret.ReadResult) {
        guard silentRead == id else { return }
        silentRead = nil
        guard generation == observed else { return }
        if case .key(let key) = result { cached = key }
        finish(result)
    }

    private func expire(_ id: UUID) {
        guard silentRead == id else { return }
        finish(.needsPermission)
    }

    private func finish(_ result: KeychainSecret.ReadResult) {
        deadline?.cancel()
        deadline = nil
        let waiting = waiter
        waiter = nil
        waiting?.resume(returning: result)
    }

    private func current(_ result: KeychainSecret.ReadResult, generation observed: Int) -> KeychainSecret.ReadResult {
        generation == observed ? result : cached.map(KeychainSecret.ReadResult.key) ?? .missing
    }
}
