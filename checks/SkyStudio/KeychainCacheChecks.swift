import Foundation

// 使用可控读取器模拟卡住的原生调用；不碰钥匙串，不显示系统框。
private final class KeychainReadLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var calls: [KeychainSecret.Access] = []
    private var cooperativeTask = false
    private var finished = false

    func read(_ access: KeychainSecret.Access) -> KeychainSecret.ReadResult {
        let first = lock.withLock {
            calls.append(access)
            cooperativeTask = cooperativeTask || withUnsafeCurrentTask { $0 != nil }
            return calls.count == 1
        }
        if first { release.wait() }
        lock.withLock { finished = true }
        return .key("fake-late-key")
    }

    func resume() { release.signal() }
    var count: Int { lock.withLock { calls.count } }
    var onlySilent: Bool { lock.withLock { calls.allSatisfy { $0 == .silent } } }
    var usedCooperativeTask: Bool { lock.withLock { cooperativeTask } }
    var didFinish: Bool { lock.withLock { finished } }
}

// 独立普通线程的看门狗：若回归把 actor 真卡住，不能让检查也无限期等下去。
private final class KeychainCheckWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    init() {
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: 6)
            if !lock.withLock({ done }) {
                FileHandle.standardError.write(Data("FAIL keychain cache checks exceeded their independent watchdog\n".utf8))
                _exit(1)
            }
        }
    }

    func finish() { lock.withLock { done = true } }
}

private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(1)
    while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(2)) }
    return predicate()
}

func runKeychainCacheChecks() async {
    let watchdog = KeychainCheckWatchdog()
    defer { watchdog.finish() }
    let latch = KeychainReadLatch()
    defer { latch.resume() }
    let cache = KeychainSecretCache(timeout: .milliseconds(80)) { access in
        await KeychainSecretExecutor.run { latch.read(access) }
    }
    let started = ContinuousClock.now
    let first = Task { await cache.keyWithoutPrompt() }
    check(await waitUntil { latch.count == 1 }, "the injected native read starts")

    let concurrentStart = ContinuousClock.now
    // 2026-11-11：钥匙串只是慢（没弹框；要授权时原生读零点几秒就拒），先叫调用方过几秒再试，不说要授权。
    checkEqual(await cache.keyWithoutPrompt(), .slow, "a second caller does not wait behind a slow read and is told to retry, not to grant permission")
    check(ContinuousClock.now - concurrentStart < .milliseconds(300), "a concurrent caller returns promptly")
    checkEqual(await first.value, .slow, "a read still running at its deadline is reported slow, not as permission-needed")
    let elapsed = ContinuousClock.now - started
    check(elapsed >= .milliseconds(60) && elapsed < .seconds(1), "the first caller observes the bounded silent deadline")
    // 说过「慢」之后那次读还没回来，再问就不再叫人等了：改报要授权（叫用户点 Allow…）。
    checkEqual(await cache.keyWithoutPrompt(), .needsPermission, "asking again while the late read is still pending escalates to permission-needed")
    checkEqual(latch.count, 1, "deadline and concurrent callers do not start more native reads")
    check(latch.onlySilent, "startup/background cache entry never tries the interactive reader")
    check(!latch.usedCooperativeTask, "native work is on the dedicated executor, outside Swift's cooperative tasks")

    // 静默开关仍由那次原生读持有：模拟写入也不能越过它。
    let writerStarted = LockedKeychainFlag()
    let writer = Task { await KeychainSecretExecutor.run { writerStarted.set() } }
    try? await Task.sleep(for: .milliseconds(20))
    check(!writerStarted.value, "writes share the serial executor with a pending read")
    latch.resume()
    await writer.value
    check(await waitUntil { latch.didFinish }, "the late native read finishes")
    var late: KeychainSecret.ReadResult = .needsPermission
    for _ in 0..<100 {
        late = await cache.keyWithoutPrompt()
        if case .key = late { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    checkEqual(late, .key("fake-late-key"), "success arriving after the deadline is cached")
    checkEqual(latch.count, 1, "late success is used without another native read")

    await runKeychainInvalidationChecks(replacement: "fake-replacement")
    await runKeychainInvalidationChecks(replacement: nil)
    await runInteractiveCacheChecks()
    runKeychainNoticeChecks()
    await runJobKeySlowChecks()
    await runJobKeyPermissionChecks()
}

/// 2026-11-11 真实冒烟：负载 8 时重启后第一次静默读超了 3 秒，AI 被叫去让用户点 Allow…，其实重试一次就好。
/// 慢 → 先叫 AI 过几秒重试、不挂「允许…」的提示；重试时那次读还没回来 → 才是要授权和提示；读回来了 → 拿到缓存的 Key、不再读一遍。
@MainActor
private func runJobKeySlowChecks() async {
    let latch = KeychainReadLatch()
    defer { latch.resume() }
    let cache = KeychainSecretCache(timeout: .milliseconds(60)) { access in
        await KeychainSecretExecutor.run { latch.read(access) }
    }
    let raised = LockedKeychainFlag()
    let observer = NotificationCenter.default.addObserver(forName: SkyStudioKeychainNoticePolicy.permissionNeeded, object: nil, queue: nil) { _ in raised.set() }
    defer { NotificationCenter.default.removeObserver(observer) }

    let first = await SkyStudioJobKey.key(.silent, cache: cache)
    check(first == .failure(.keychainSlow), "a keychain that has not answered by the deadline is reported to the AI as slow (got \(first))")
    check(!raised.value, "a slow keychain does not raise the Allow… notice")
    let text = SkyStudioJobKey.Problem.keychainSlow.message
    for phrase in ["Wait a few seconds", "repeat the same call", "no permission dialog"] {
        check(text.contains(phrase), "the slow-keychain answer tells the AI to retry first: \(phrase)")
    }
    check(!text.contains("Mac login password"), "the slow-keychain answer does not send the user to the macOS dialog")

    let again = await SkyStudioJobKey.key(.silent, cache: cache)
    check(again == .failure(.needsPermission), "a retry while the same read is still pending asks for the user's permission (got \(again))")
    check(raised.value, "only that escalation raises the Allow… notice")

    latch.resume()
    check(await waitUntil { latch.didFinish }, "the slow read finishes")
    var third: Result<String, SkyStudioJobKey.Problem> = .failure(.needsPermission)
    for _ in 0..<100 {
        third = await SkyStudioJobKey.key(.silent, cache: cache)
        if case .success = third { break }
        try? await Task.sleep(for: .milliseconds(2))
    }
    check(third == .success("fake-late-key"), "a retry after the late read returned gets the key it cached")
    checkEqual(latch.count, 1, "retries never start another native read")
}

@MainActor
private func runJobKeyPermissionChecks() async {
    let startupPrompt = LockedKeychainFlag()
    let startupCache = KeychainSecretCache(timeout: .milliseconds(60)) { access in
        if access == .interactive { startupPrompt.set(); return .key("fake-interactive-only") }
        return .needsPermission
    }
    checkEqual(await SkyStudioKey.keyWithoutPrompt(cache: startupCache), .needsPermission, "the actual startup/background key entry returns without authorization")
    check(!startupPrompt.value, "the actual startup/background key entry never tries the interactive reader")
    let required = LockedKeychainFlag()
    let observer = NotificationCenter.default.addObserver(forName: SkyStudioKeychainNoticePolicy.permissionNeeded, object: nil, queue: nil) { _ in required.set() }
    defer { NotificationCenter.default.removeObserver(observer) }
    let cache = KeychainSecretCache(timeout: .milliseconds(60)) { _ in .needsPermission }
    let result = await SkyStudioJobKey.key(.silent, cache: cache)
    switch result {
    case .failure(.needsPermission): check(true, "the production paid-job key path returns permission-needed")
    default: check(false, "the production paid-job path must not submit without permission")
    }
    check(required.value, "the production paid-job key path publishes the global notice state")
    for phrase in ["SkyCut's notice", "Settings → Sky Studio", "Mac login password", "Always Allow"] {
        check(SkyStudioJobKey.Problem.needsPermission.message.contains(phrase), "the actual paid-tool refusal includes \(phrase)")
    }
}

private final class LockedKeychainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.withLock { stored = true } }
    var value: Bool { lock.withLock { stored } }
}

private func runKeychainInvalidationChecks(replacement: String?) async {
    let latch = KeychainReadLatch()
    defer { latch.resume() }
    let cache = KeychainSecretCache(timeout: .milliseconds(60)) { access in
        if latch.count > 0 { return .missing }
        return await KeychainSecretExecutor.run { latch.read(access) }
    }
    let waiting = Task { await cache.keyWithoutPrompt() }
    check(await waitUntil { latch.count == 1 }, "old read started before changing the stored key")
    await cache.remember(replacement)
    checkEqual(await waiting.value, replacement.map(KeychainSecret.ReadResult.key) ?? .missing, "changing storage resolves the old caller with the new state")
    latch.resume()
    check(await waitUntil { latch.didFinish }, "old read returns after storage changed")
    // 排在原生读之后的 operation 完成，再给 actor 交付结果；未交付时保留需要授权也算安全。
    await KeychainSecretExecutor.run {}
    try? await Task.sleep(for: .milliseconds(20))
    let result = await cache.keyWithoutPrompt()
    if let replacement { checkEqual(result, .key(replacement), "a late old read cannot replace the new key") }
    else { check(result != .key("fake-late-key"), "a late old read cannot revive a removed key") }
}

private func runInteractiveCacheChecks() async {
    let latch = KeychainReadLatch()
    defer { latch.resume() }
    let cache = KeychainSecretCache(timeout: .milliseconds(60)) { access in
        if access == .silent { return .needsPermission }
        return await KeychainSecretExecutor.run { latch.read(access) }
    }
    let interactive = Task { await cache.key() }
    check(await waitUntil { latch.count == 1 }, "explicit user authorization starts one interactive read")
    let joined = Task { await cache.key() }
    checkEqual(await cache.keyWithoutPrompt(), .needsPermission, "AI does not wait for the user's open authorization dialog")
    latch.resume()
    checkEqual(await interactive.value, .key("fake-late-key"), "explicit authorization receives the key")
    checkEqual(await joined.value, .key("fake-late-key"), "concurrent explicit authorization shares the result")
    checkEqual(latch.count, 1, "concurrent user authorizations share the same read")

    let oldRead = KeychainReadLatch()
    defer { oldRead.resume() }
    let oldCache = KeychainSecretCache(timeout: .milliseconds(60)) { access in
        if access == .silent { return .needsPermission }
        return await KeychainSecretExecutor.run { oldRead.read(access) }
    }
    let old = Task { await oldCache.key() }
    check(await waitUntil { oldRead.count == 1 }, "interactive read started before deletion")
    await oldCache.remember(nil)
    oldRead.resume()
    checkEqual(await old.value, .missing, "removing a key invalidates an outstanding interactive read")
}

private func runKeychainNoticeChecks() {
    let suite = "keychain-notice-checks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = SkyStudioKeychainNoticePolicy(build: "build-A")
    check(first.shouldPresent(in: defaults), "a new build can show its notice")
    check(first.shouldPresent(in: defaults), "a background app does not consume an unshown notice")
    first.didPresent(in: defaults)
    check(!first.shouldPresent(in: defaults), "a shown or dismissed notice stays suppressed for this build")
    first.didPresent(in: defaults)
    checkEqual(defaults.stringArray(forKey: SkyStudioKeychainNoticePolicy.shownBuildsKey), ["build-A"], "duplicate window appearances do not duplicate the build")
    let second = SkyStudioKeychainNoticePolicy(build: "build-B")
    check(second.shouldPresent(in: defaults), "the next build may show once")
    second.didPresent(in: defaults)
    check(!first.shouldPresent(in: defaults), "returning to an earlier build does not show it again")
    for phrase in ["SkyCut's notice", "Settings → Sky Studio", "Mac login password", "Always Allow", "next time SkyCut starts"] {
        check(SkyStudioKeychainNoticePolicy.aiNextStep.contains(phrase), "the AI gets actionable keychain guidance: \(phrase)")
    }
}
