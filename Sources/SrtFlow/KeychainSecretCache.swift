import Foundation

// 一次运行的 Key 缓存与有界静默读；不直接调用 Security。原生读由 KeychainSecret 的专用执行器承接。
// 超时只结束调用者的等待，不能硬中断 Security；保留那次读取，迟到成功仍缓存，其他调用立即回、不排在后面。
// 立即回的是什么（2026-11-11）：期限到了、或者那次读还没过期限就有人问 = `.slow`（钥匙串忙、没弹框，过几秒再试）；
// 说过一次「慢」之后它还没回来又有人问 = `.needsPermission`（再等也没用，叫用户点 Allow…）。交互读在跑 = 照旧要授权。
actor KeychainSecretCache {
    typealias Reader = @Sendable (KeychainSecret.Access) async -> KeychainSecret.ReadResult
    private let reader: Reader
    private let timeout: Duration
    private var cached: String?
    private var generation = 0
    private var silentRead: UUID?
    /// 过了期限还没回来的那次静默读（已经回过一次 `.slow`）。
    private var lateRead: UUID?
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
        if interactiveRead != nil { return .needsPermission }
        if let pending = silentRead { return pending == lateRead ? .needsPermission : .slow }
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
        // 用户点了 Allow…：静默读慢也照样走交互档（用户就是来授权的）。
        guard quiet == .needsPermission || quiet == .slow else { return quiet }
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
        lateRead = nil
        guard generation == observed else { return }
        if case .key(let key) = result { cached = key }
        finish(result)
    }

    /// 期限到了还没回来：钥匙串慢，不是要授权（要授权时原生读零点几秒就拒）。等着的那个调用先回 `.slow`，读接着跑。
    private func expire(_ id: UUID) {
        guard silentRead == id else { return }
        lateRead = id
        finish(.slow)
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
