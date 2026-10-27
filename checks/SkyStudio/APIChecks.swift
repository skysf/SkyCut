import Foundation

// SkyStudioAPI：发出去的请求长什么样（地址、认证头、版本号、机器号），回来的错怎么分（服务器的错 / 没连上 / 回的不像话），
// 环境变量只能把地址指到本机。全程走假协议（SkyStudioStub），不碰真的网络。

func runAPIChecks() async {
    let base = URL(string: "http://127.0.0.1:8123/api/skycut/v1")!
    let key = "sk-" + String(repeating: "A", count: 43)
    let api = SkyStudioAPI(session: SkyStudioStub.session, base: base, version: "0.18.49", machine: String(repeating: "a", count: 64))

    // 1. GET /me：地址、方法、四个头。
    SkyStudioStub.reset { _ in .http(200, sampleMe) }
    let me = try? await api.me(key: key)
    checkEqual(me?.skycut.plan, "trial", "/me reads the answer")
    let seen = SkyStudioStub.log.first
    checkEqual(SkyStudioStub.log.count, 1, "one request")
    checkEqual(seen?.method, "GET", "/me is a GET")
    checkEqual(seen?.url, "http://127.0.0.1:8123/api/skycut/v1/me", "the /me address")
    checkEqual(seen?.headers["Authorization"], "Bearer \(key)", "the key goes in a Bearer header")
    checkEqual(seen?.headers["X-SkyCut-Version"], "0.18.49", "the app version goes along")
    checkEqual(seen?.headers["X-SkyCut-Machine"], String(repeating: "a", count: 64), "the machine hash goes along")
    checkEqual(seen?.headers["Accept"], "application/json", "asks for JSON")

    // 读不到硬件 UUID：不带这一个头（服务器会因此报错，设置里照实显示），别的照发。
    SkyStudioStub.reset { _ in .http(200, sampleMe) }
    let noMachine = SkyStudioAPI(session: SkyStudioStub.session, base: base, version: "0.18.49", machine: nil)
    _ = try? await noMachine.me(key: key)
    check(SkyStudioStub.log.first?.headers["X-SkyCut-Machine"] == nil, "no machine hash, no header")
    checkEqual(SkyStudioStub.log.first?.headers["Authorization"], "Bearer \(key)", "the key still goes along")

    // 2. 服务器照约好的格式回的错：code、message、附加字段原样留着。
    SkyStudioStub.reset { _ in .http(401, #"{"error": {"code": "invalid_key", "message": "This API key was revoked."}}"#) }
    if case .server(let error)? = await expectFailure("401", { _ = try await api.me(key: key) }) {
        checkEqual(error.status, 401, "401 status")
        checkEqual(error.code, SkyStudioServerError.invalidKey, "invalid_key")
        checkEqual(error.message, "This API key was revoked.", "the server's own words")
        check(error.fields.isEmpty, "no extra fields")
    } else {
        check(false, "401 is a server error")
    }

    SkyStudioStub.reset { _ in
        .http(426, #"{"error": {"code": "upgrade_required", "message": "Update SkyCut.", "min_version": "0.19.0", "download_url": "https://skystudioai.com/skycut/download"}}"#)
    }
    if case .server(let error)? = await expectFailure("426", { _ = try await api.me(key: key) }) {
        checkEqual(error.code, SkyStudioServerError.upgradeRequired, "upgrade_required")
        checkEqual(error.fields["min_version"]?.stringValue, "0.19.0", "min_version kept")
        checkEqual(error.downloadURL?.absoluteString, "https://skystudioai.com/skycut/download", "download_url read")
    } else {
        check(false, "426 is a server error")
    }

    SkyStudioStub.reset { _ in .http(429, #"{"error": {"code": "rate_limited", "message": "Slow down.", "retry_after": 30}}"#) }
    if case .server(let error)? = await expectFailure("429", { _ = try await api.me(key: key) }) {
        checkEqual(error.fields["retry_after"]?.intValue, 30, "retry_after kept")
    } else {
        check(false, "429 is a server error")
    }

    // 3. 回的不是约好的样子：502 的网页、2xx 却读不成。
    SkyStudioStub.reset { _ in .http(502, "<html>Bad gateway</html>") }
    checkEqual(await expectFailure("502 html", { _ = try await api.me(key: key) }), .badAnswer(status: 502), "an HTML error page")
    SkyStudioStub.reset { _ in .http(500, #"{"error": "boom"}"#) }
    checkEqual(await expectFailure("500 odd", { _ = try await api.me(key: key) }), .badAnswer(status: 500), "an error without a code")
    SkyStudioStub.reset { _ in .http(200, #"{"hello": "world"}"#) }
    checkEqual(await expectFailure("200 odd", { _ = try await api.me(key: key) }), .badAnswer(status: 200), "a 200 that is not a /me answer")

    // 4. 没连上。
    SkyStudioStub.reset { _ in .failure(.notConnectedToInternet) }
    if case .network? = await expectFailure("offline", { _ = try await api.me(key: key) }) {
        check(true, "offline is a network failure")
    } else {
        check(false, "offline is a network failure")
    }

    // 5. 地址：环境变量只能指到本机（Key 不会因此发到别处），别的一律正式地址。
    let production = SkyStudioAPI.productionBase
    checkEqual(production.absoluteString, "https://skystudioai.com/api/skycut/v1", "the production address")
    checkEqual(SkyStudioAPI.configuredBase([:]), production, "no override")
    checkEqual(SkyStudioAPI.configuredBase([SkyStudioAPI.baseEnvironmentKey: base.absoluteString]), base, "loopback override")
    checkEqual(SkyStudioAPI.configuredBase([SkyStudioAPI.baseEnvironmentKey: "http://localhost:9/api"]).host, "localhost", "localhost override")
    checkEqual(SkyStudioAPI.configuredBase([SkyStudioAPI.baseEnvironmentKey: "https://evil.example.com/api"]), production, "elsewhere is refused")
    checkEqual(SkyStudioAPI.configuredBase([SkyStudioAPI.baseEnvironmentKey: "ftp://127.0.0.1/api"]), production, "only http(s)")
    checkEqual(SkyStudioAPI.configuredBase([SkyStudioAPI.baseEnvironmentKey: "not a url"]), production, "garbage is refused")
    checkEqual(SkyStudioAPI.baseEnvironmentKey, "SRTFLOW_SKYSTUDIO_API_BASE", "environment variables keep the SRTFLOW_ prefix")
}
