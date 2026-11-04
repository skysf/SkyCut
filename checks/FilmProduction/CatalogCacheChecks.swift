import Foundation

// 真实 SkyStudioCatalogCache + API + 注入 URLSession；不给生产 Key，也不触钥匙串。
@MainActor func runCatalogCacheChecks() async throws {
    CatalogCacheStub.reset()
    let session = CatalogCacheStub.session()
    defer { session.invalidateAndCancel() }
    let api = SkyStudioAPI(session: session, base: URL(string: "https://catalog.invalid/api")!, version: "0.0.0", machine: nil)
    let cache = SkyStudioCatalogCache()
    check(cache.cachedCatalog() == nil && CatalogCacheStub.count == 0, "cold catalog peek is read-only and starts no request")
    let old = Task { try await cache.catalog(key: "synthetic-old", api: api) }
    try await CatalogCacheStub.received(1)
    cache.forget()
    let newer = Task { try await cache.catalog(key: "synthetic-new", api: api) }
    try await CatalogCacheStub.received(2)
    CatalogCacheStub.answer(0)
    check(try await old.value.models.first?.id == "old-catalog", "old caller still receives its own original response")
    check(cache.cachedCatalog() == nil, "late old-key result cannot repopulate the invalidated catalog")

    // 到达 catalog 的 MainActor 任务会先执行到其第一次 await，然后测试才恢复；无固定延迟猜测。
    // 若旧 defer 错误清掉新 loading，第 3 次会走协议并自动回答，最终请求数必须暴露它。
    CatalogCacheStub.automaticallyAnswer(from: 2)
    var third: Task<SkyStudioCatalog, Error>!
    await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
        third = Task { @MainActor in
            started.resume()
            return try await cache.catalog(key: "synthetic-new", api: api)
        }
    }
    CatalogCacheStub.answer(1)
    let newValue = try await newer.value
    let shared = try await third.value
    check(newValue.models.first?.id == "new-catalog", "new-key request receives the new catalog")
    check(shared == newValue, "caller arriving after old completion still joins the new-key result")
    check(CatalogCacheStub.count == 2, "late old-key defer cannot clear or duplicate the newer in-flight request")
    check(cache.cachedCatalog() == newValue, "only the current invalidation epoch may fill the cache")
    let cached = try await cache.catalog(key: "synthetic-new", api: api)
    check(cached == newValue && CatalogCacheStub.count == 2, "a hot current catalog is reused without HTTP")
    check(cache.cachedCatalog(now: Date().addingTimeInterval(601)) == nil, "expired cache cannot authorize offline new render writes")
    check(cache.cachedCatalog(now: Date(timeIntervalSince1970: 0)) == nil, "backward wall clock does not treat the catalog as fresh")
    cache.forget()
    check(cache.cachedCatalog() == nil, "forget synchronously invalidates the offline snapshot")
}
