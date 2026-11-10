import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 声音库（声音 PR 6）的假 Sky Studio：`/voices` 的增删改查、`/uploads` + PUT、设计 / 建 MiniMax 版 / 克隆读稿的 `/quote` 和 `/jobs`、
// 成品的音频、长期授权（声音 PR 7：`/voices/consent-grant` 的 GET / POST / DELETE，带 standing_grant 建声音时照它收或拒）；
// `/models` 用 Sky Studio 导出的目录快照（和 VoiceRecoveryHTTP 同一份）。生产的工具、把关、任务、下载、切句、入轨照常执行。
// 和旁白恢复那一份分开写（各自一个 URLProtocol），两边的场景互不影响。

final class VoiceLibraryHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [(method: String, path: String, body: JSONValue)] = []
    static var uploads: [Int] = []
    static var voices: [String: JSONValue] = [:]
    /// GET /voices 直接回这个（声音库用不了）。
    static var listFailure: (Int, JSONValue)?
    /// /quote 直接回这个。
    static var quoteFailure: (Int, JSONValue)?
    /// DELETE 先回几次「存储一时不可用」。
    static var deleteStorageFailures = 0
    /// 克隆读稿的默认要 MiniMax 版、还没建（`default_needs_one_time`）。
    static var needsEnroll = false
    /// 这个账号的长期授权（nil = 没记过或撤了；active 为假 = 文案升了版本）。
    static var standing: (version: String, active: Bool)?
    /// 带 standing_grant 建声音时拒一次（GET 说有效、建的那一刻刚被别的 Mac 撤了）。
    static var refuseStanding = false
    /// `/voices/consent-grant` 回 503（声音库一时用不了）。
    static var grantUnavailable = false
    /// 这个账号记着一条有效的长期授权（声音库界面那一刀的检查照它拨；和上面 `standing` 是同一份）。
    static var standingGrant: Bool {
        get { standing?.active == true }
        set { standing = newValue ? ("voice-standing-consent-v1", true) : nil }
    }
    static var prompts: [String] = []
    static var wave = Data()
    // 设计 / 建 MiniMax 版的那几单（2026-11-11 审查补的：原来每一单 `/jobs` 当场回 done、实扣等于报价，去重、改价、失败退款、排队都照不到）。
    /// 服务器上的一单：`final` 是它的结局；问到第 `hold` 次（`GET /jobs/{id}`）才回，之前回排队 / 进行中。
    struct Order { var kind: String; var key: String; var subject: String; var final: JSONValue; var hold: Int; var polls = 0; var open: Bool }
    static var orders: [String: Order] = [:]
    static var orderIDs: [String] = []
    /// 之后交的设计 / 建单先回排队中（202），问到第几次才回结局；0 = 交的时候就做完。
    static var holdPolls = 0
    /// 排着队的单先按住不放（问多少次都回进行中），场景拨回 false 才往下走。
    static var holding = false
    /// 下一单：服务器算出来比 `max_credits` 贵，回 409 `price_changed` 带真实的价，一分不扣、不建任务。
    static var priceChange: Double?
    /// 下一单做不成：供应商失败、钱全退了（任务以 failed 结束）。
    static var failNext = false
    /// 授权那一句此刻的版本（`/models` 报的和 `POST /voices` 认的）；改了它，带旧版本的 `consent: true` 回 `consent_outdated`。
    static var consentVersion = "voice-consent-v1"

    static let voiceID = "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceLibraryHTTP.self]
        return URLSession(configuration: configuration)
    }()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []; uploads = []; prompts = []
        voices = [voiceID: voice(voiceID, name: "Sky", languages: ["en"], minimax: false)]
        listFailure = nil; quoteFailure = nil; deleteStorageFailures = 0; needsEnroll = false; standing = nil; refuseStanding = false; grantUnavailable = false
        orders = [:]; orderIDs = []; holdPolls = 0; holding = false; priceChange = nil; failNext = false; consentVersion = "voice-consent-v1"
        let samples = (0..<264_600).map { Int16(sin(Double($0) * 0.08) * 4_000) }
        wave = VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100)
    }

    static var log: [(method: String, path: String, body: JSONValue)] { lock.lock(); defer { lock.unlock() }; return requests }
    static func calls(_ method: String, _ suffix: String) -> [JSONValue] { log.filter { $0.method == method && $0.path.hasSuffix(suffix) }.map(\.body) }
    static func calls(_ method: String, containing part: String) -> Int { log.filter { $0.method == method && $0.path.contains(part) }.count }

    static func voice(_ id: String, name: String, languages: [String], minimax: Bool, source: String = "recording") -> JSONValue {
        ["id": .string(id), "name": .string(name), "source": .string(source), "scope": "personal",
         "languages": .array(languages.map { ["language": .string($0), "kind": "recording", "seconds": 29.5, "minimax": .bool(minimax)] })]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let body = (try? JSONValue.decode(data)) ?? .null
        Self.lock.lock()
        Self.requests.append((method, path, body))
        let (status, value, bytes) = Self.answer(method, path, body, data)
        Self.lock.unlock()
        let payload = bytes ?? (try! value.encodedData())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(payload.count), "Content-Type": bytes == nil ? "application/json" : "audio/wav"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            bytes.append(buffer, count: count)
        }
        return bytes
    }

    private static func error(_ status: Int, _ code: String, _ extra: [String: JSONValue] = [:]) -> (Int, JSONValue, Data?) {
        var error: [String: JSONValue] = ["code": .string(code), "message": .string("Sky Studio says \(code).")]
        for (key, value) in extra { error[key] = value }
        return (status, ["error": .object(error)], nil)
    }

    // 调用时已经拿着锁。
    private static func answer(_ method: String, _ path: String, _ body: JSONValue, _ data: Data) -> (Int, JSONValue, Data?) {
        if path.hasSuffix("/models") { return (200, catalog(), nil) }
        if path.hasPrefix("/files/") { return (200, [:], wave) }
        if path.hasPrefix("/put/") { uploads.append(data.count); return (200, [:], Data()) }
        if path.hasSuffix("/uploads") {
            let index = uploads.count + 1
            return (200, ["upload_url": .string("http://127.0.0.1/put/\(index)"), "method": "PUT", "headers": ["Content-Type": "audio/wav"],
                          "file_url": .string("skystudio-private://voice/uploads/u/\(index).wav")], nil)
        }
        if path.hasSuffix("/quote") { return quoteFailure.map { ($0.0, $0.1, nil) } ?? (200, quote(body), nil) }
        if path.hasSuffix("/jobs"), method == "POST" { return submit(body) }
        if method == "GET", let range = path.range(of: "/jobs/") { return poll(String(path[range.upperBound...])) }
        guard let range = path.range(of: "/voices") else { return error(404, "not_found") }
        return library(method, String(path[range.upperBound...]), body)
    }

    /// 目录快照；授权那一句升了版本（`consentVersion`）就照新的报。
    private static func catalog() -> JSONValue {
        guard consentVersion != "voice-consent-v1" else { return VoiceRecoveryHTTP.catalog }
        let consent = merged(VoiceRecoveryHTTP.catalog["voice_consent"] ?? [:], ["per_recording": [
            "version": .string(consentVersion), "statement": .string("NEW STATEMENT \(consentVersion): this is my voice or I may copy it.")]])
        return merged(VoiceRecoveryHTTP.catalog, ["voice_consent": consent])
    }

    private static func library(_ method: String, _ rest: String, _ body: JSONValue) -> (Int, JSONValue, Data?) {
        if rest == "/consent-grant" { return consentGrant(method, body) }
        // 这一次的 `consent: true` 带的是旧版本的那一句：不收（文案升了版本）。
        if method == "POST", body["consent"] == true, body["consent_statement_version"] != .string(consentVersion) {
            return error(400, "invalid_request", ["field": "consent", "reason": "consent_outdated"])
        }
        if body["consent"] == "standing_grant" {
            // Sky Studio 只在 GET 说有效时收 standing_grant（接口合同 Consent 一节）；拒的时候什么都不留。
            if refuseStanding { refuseStanding = false; standing = nil }
            guard let standing, standing.active else {
                return error(400, "invalid_request", ["field": "consent", "reason": .string(standing == nil ? "no_standing_grant" : "consent_outdated")])
            }
        }
        if rest.isEmpty || rest == "/" {
            if method == "GET" {
                if let (status, value) = listFailure { return (status, value, nil) }
                return (200, ["voices": .array(voices.values.sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") }), "next_cursor": .null], nil)
            }
            let id = "voice_" + String(repeating: "a", count: 31) + String(voices.count)
            voices[id] = voice(id, name: body["name"]?.stringValue ?? "", languages: [body["language"]?.stringValue ?? "en"], minimax: false)
            return (200, ["voice": voices[id]!], nil)
        }
        let parts = rest.split(separator: "/").map(String.init)
        guard let id = parts.first, var voice = voices[id] else {
            if method == "DELETE", deleteStorageFailures == 0, parts.first.map(SkyStudioVoice.isVoiceID) == true { return (200, ["deleted": true], nil) }
            return error(404, "not_found")
        }
        switch (method, parts.count) {
        case ("GET", 1): return (200, ["voice": voice], nil)
        case ("PATCH", 1):
            voice = merged(voice, ["name": body["name"] ?? .null]); voices[id] = voice
            return (200, ["voice": voice], nil)
        case ("DELETE", 1):
            if deleteStorageFailures > 0 {
                deleteStorageFailures -= 1
                voices[id] = nil  // 已经看不见了（正在删），再发一次 DELETE 接着删
                return error(503, "voice_library_unavailable", ["reason": "storage_unavailable", "retryable": true])
            }
            voices[id] = nil
            return (200, ["deleted": true], nil)
        case ("POST", 2) where parts[1] == "references":
            let language = body["language"]?.stringValue ?? "en"
            var languages = voice["languages"]?.arrayValue ?? []
            if languages.contains(where: { $0["language"]?.stringValue == language }) { return error(409, "reference_exists", ["language": .string(language)]) }
            languages.append(["language": .string(language), "kind": "recording", "seconds": 20, "minimax": false])
            voice = merged(voice, ["languages": .array(languages)]); voices[id] = voice
            return (200, ["voice": voice], nil)
        default:
            return error(404, "not_found")
        }
    }

    /// `/voices/consent-grant`：GET 读、POST 记（带 statement_version）、DELETE 撤，回的样子照接口合同。
    private static func consentGrant(_ method: String, _ body: JSONValue) -> (Int, JSONValue, Data?) {
        if grantUnavailable { return error(503, "voice_library_unavailable", ["reason": "not_configured"]) }
        switch method {
        case "POST":
            guard let version = body["statement_version"]?.stringValue, !version.isEmpty else {
                return error(400, "invalid_request", ["field": "statement_version"])
            }
            standing = (version, version == "voice-standing-consent-v1")
        case "DELETE":
            standing = nil
            return (200, ["revoked": true, "grant": .null, "current_statement_version": "voice-standing-consent-v1"], nil)
        default:
            break
        }
        var grant: JSONValue = .null
        if let standing {
            grant = ["statement_version": .string(standing.version), "granted_at": "2026-11-10T10:00:00Z", "active": .bool(standing.active),
                     "inactive_reason": standing.active ? .null : "outdated"]
        }
        return (200, ["grant": grant, "current_statement_version": "voice-standing-consent-v1"], nil)
    }

    private static func merged(_ value: JSONValue, _ fields: [String: JSONValue]) -> JSONValue {
        var object = value.objectValue ?? [:]
        for (key, entry) in fields { object[key] = entry }
        return .object(object)
    }

    private static let enrollItem: JSONValue = ["kind": "voice_enroll", "model": "minimax-voice-clone", "voice": .string(voiceID), "language": "en",
        "credits": 377.6, "why": "The default model reads this voice in English from its MiniMax version.",
        "then": ["model": "minimax-speech-2.8-hd", "credits_expected": 1.5]]

    private static func quote(_ body: JSONValue) -> JSONValue {
        switch body["kind"]?.stringValue {
        case "voice_design"?:
            // 中文描述服务器用 MiniMax（贵的那个，「约」和「最多」不一样）；别的用 Qwen3，按描述 + 试读句每开始 1,000 字 22.5（Sky Studio #247）。
            let chinese = (body["prompt"]?.stringValue ?? "").unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            if chinese { return ["credits": 760, "credits_expected": 751.4, "settlement": "exact", "model": "minimax-voice-design"] }
            let characters = (body["prompt"]?.stringValue ?? "").count + (body["params"]?["sample_text"]?.stringValue ?? "").count
            let credits = 22.5 * Double(max(1, (characters + 999) / 1_000))
            return ["credits": .number(credits), "credits_expected": .number(credits), "settlement": "exact", "model": "qwen3-voice-design"]
        default:
            let batches = body["params"]?["batches"]?.arrayValue ?? []
            let selection: JSONValue = body["params"]?["plan"] ?? (needsEnroll
                ? ["model": "index-tts-2", "reference_language": "en", "fallback": .null]
                : ["model": "minimax-speech-2.8-hd", "reference_language": "en", "fallback": .null])
            return ["credits": .number(1.5 * Double(batches.count)), "credits_expected": .number(1.0 * Double(batches.count)), "settlement": "exact",
                    "voice_plan": ["selection": selection, "requested_model": "auto", "rule": .string(needsEnroll ? "default_needs_one_time" : "en_80"),
                                   "reason": "English is at least 80% of the reading time.", "languages": [["language": "en", "share": 1, "seconds": 3]],
                                   "cross_language": false, "warnings": []],
                    "batches": .array(batches.map { _ in ["credits": 1.5, "credits_expected": 1] }),
                    "one_time": needsEnroll ? [enrollItem] : []]
        }
    }

    /// `POST /jobs`。读稿的一批照旧当场做完；设计 / 建 MiniMax 版照 Sky Studio 的规矩：
    /// - 同一个 idempotency_key 再交：回原来那一单、不再扣钱；
    /// - 同一个声音 + 语言的建单还开着：不管 key 是什么都回那一单（202、同一个 job_id），一次性费用只扣一次；
    /// - 比 `max_credits` 贵：409 `price_changed` 带真实的价，不建任务；
    /// - 做完实扣不一定等于报价的上限（MiniMax 设计上限 760、实扣 751.4）。
    private static func submit(_ body: JSONValue) -> (Int, JSONValue, Data?) {
        guard let kind = body["kind"]?.stringValue, kind == "voice_enroll" || kind == "voice_design" else { return (200, reading(body), nil) }
        let key = body["idempotency_key"]?.stringValue ?? ""
        let subject = kind == "voice_enroll" ? "\(body["params"]?["voice"]?.stringValue ?? ""):\(body["params"]?["language"]?.stringValue ?? "")" : key
        if let id = orderIDs.first(where: { orders[$0]?.key == key || (kind == "voice_enroll" && orders[$0]?.open == true && orders[$0]?.subject == subject) }) {
            return orders[id]!.open ? (202, pending(id, "queued"), nil) : (200, orders[id]!.final, nil)
        }
        if let price = priceChange {
            priceChange = nil
            return error(409, "price_changed", ["credits": .number(price)])
        }
        let id = "\(kind == "voice_enroll" ? "enroll" : "design")-\(orderIDs.count + 1)"
        var final: JSONValue
        if failNext {
            failNext = false
            final = ["job_id": .string(id), "status": "failed", "error": ["message": "Provider failed", "refunded": true],
                     "billing": ["status": "refunded", "credits_charged": 0]]
        } else if kind == "voice_enroll" {
            final = ["job_id": .string(id), "status": "done", "credits_charged": 377.6, "billing": ["status": "charged", "credits_charged": 377.6],
                     "result": ["voice": voice(voiceID, name: "Sky", languages: ["en"], minimax: true), "model": "minimax-voice-clone"]]
        } else {
            let voiceID = "voice_" + String(repeating: "d", count: 31) + String(orderIDs.count % 10)
            let maximum = body["max_credits"]?.doubleValue ?? 22.5
            let charged: JSONValue = .number(maximum == 760 ? 751.4 : maximum)
            let designed = voice(voiceID, name: body["params"]?["name"]?.stringValue ?? "", languages: ["en"], minimax: false, source: "design")
            final = ["job_id": .string(id), "status": "done", "credits_charged": charged, "billing": ["status": "charged", "credits_charged": charged],
                     "result": ["voice": designed, "model": maximum == 760 ? "minimax-voice-design" : "qwen3-voice-design",
                                "sample_url": "https://assets.example/voices/sample.wav", "sample_expires_at": "2026-11-20T11:00:00Z"]]
        }
        orders[id] = Order(kind: kind, key: key, subject: subject, final: final, hold: holdPolls, open: true)
        orderIDs.append(id)
        if holdPolls > 0 { return (202, pending(id, "queued"), nil) }
        return (200, settle(id), nil)
    }

    /// `GET /jobs/{id}`：还没问够次数回进行中，够了回结局（做成的这时才进声音库）。
    private static func poll(_ id: String) -> (Int, JSONValue, Data?) {
        guard var order = orders[id] else { return error(404, "not_found") }
        guard order.open else { return (200, order.final, nil) }
        order.polls += 1
        orders[id] = order
        return holding || order.polls < order.hold ? (200, pending(id, "running"), nil) : (200, settle(id), nil)
    }

    private static func pending(_ id: String, _ status: String) -> JSONValue {
        ["job_id": .string(id), "status": .string(status), "poll_after_seconds": 2]
    }

    /// 这一单到结局了：做成的进声音库（设计出来的声音、建好的 MiniMax 版）。
    private static func settle(_ id: String) -> JSONValue {
        guard var order = orders[id] else { return .null }
        order.open = false
        orders[id] = order
        if order.final["status"] == "done", let made = order.final["result"]?["voice"], let voiceID = made["id"]?.stringValue {
            voices[voiceID] = made
            if order.kind == "voice_enroll" { needsEnroll = false }
        }
        return order.final
    }

    private static func reading(_ body: JSONValue) -> JSONValue {
        let index = prompts.count
        prompts.append(body["prompt"]?.stringValue ?? "")
        let selection = body["params"]?["plan"] ?? .null
        return ["job_id": .string("clone-\(index)"), "status": "done", "credits_charged": 1.5,
                "result": ["url": .string("http://127.0.0.1/files/clone-\(index).wav"), "content_type": "audio/wav", "duration": 6,
                           "model": selection["model"] ?? .null, "fallback_used": false, "voice_plan": ["selection": selection]]]
    }

    /// 设计 / 建 MiniMax 版交了几单（`POST /jobs`，不算读稿的批）。
    static func orderPosts(_ kind: String) -> [JSONValue] { calls("POST", "/jobs").filter { $0["kind"] == .string(kind) } }
}

@MainActor
final class VoiceLibraryFixture {
    let folder: URL
    let project: VideoEditProject

    init(folder: URL) throws {
        self.folder = folder
        project = OpenProjects.shared.primary
        project.linkageEnabled = false
        _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform { $0 = TimelineState() } }
        project.effectiveUndoManager?.removeAllActions()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("allowed"), withIntermediateDirectories: true)
        project.documentURL = folder.appendingPathComponent("library.skycut")
        VoiceLibraryHTTP.reset()
        // 设计 / 建 MiniMax 版的任务问 Sky Studio 的间隔不真等（排队的那几个场景）。
        SkyStudioVoiceLibraryJob.pollSleep = { _ in try await Task.sleep(nanoseconds: 20_000_000) }
        SkyStudioCatalogCache.shared.forget()
        SkyStudioSpendStore.shared.setDailyLimit(100_000)
        AIReadGrants.shared.remember([folder.appendingPathComponent("allowed")])
    }

    var services: SkyStudioVoiceServices {
        var services = SkyStudioVoiceServices()
        services.api = SkyStudioAPI(session: VoiceLibraryHTTP.session, base: URL(string: "http://127.0.0.1/api/skycut/v1")!, machine: nil)
        services.key = { "local-library-fixture" }
        services.transcription = { _ in .installed(Locale(identifier: "en-US")) }
        services.install = { _, progress in progress(1) }
        services.slots = SkyStudioJobSlots(limits: .init(shared: 3, audio: 8))
        services.jobSleep = { _ in try await Task.sleep(nanoseconds: 5_000_000) }
        services.transcribe = { file, _ in
            let index = Int(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "batch-", with: "")) ?? 0
            let prompt = VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.prompts.indices.contains(index) ? VoiceLibraryHTTP.prompts[index] : "" }
            let tokens = prompt.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let step = 5.6 / Double(max(tokens.count, 1))
            return tokens.enumerated().map { TimedWord(text: ($0.offset == 0 ? "" : " ") + $0.element,
                start: 0.1 + Double($0.offset) * step, end: 0.1 + Double($0.offset + 1) * step - 0.1) }
        }
        return services
    }

    /// 一段 15 秒、整段都算有效人声的录音（正弦波，响度远高于 0.0056）。
    func recording(_ name: String = "my-voice.wav") throws -> URL {
        let url = folder.appendingPathComponent("allowed").appendingPathComponent(name)
        let samples = (0..<(44_100 * 15)).map { Int16(sin(Double($0) * 0.05) * 6_000) }
        try VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100).write(to: url)
        return url
    }

    func manage(_ args: JSONValue) async throws -> AIToolResult {
        try await SkyStudioVoiceLibraryTool.manage(AIToolArguments(args), project, services: services)
    }

    func list(_ args: JSONValue = [:]) async throws -> AIToolResult {
        try await SkyStudioVoiceLibraryTool.list(AIToolArguments(args), services: services)
    }

    /// add_voiceover 用声音库的声音：走生产的 SkyStudioVoiceoverStart。
    func narrate(_ lines: [String], skipOneTime: Bool = false, token: String? = nil) async throws -> SkyStudioVoiceoverStart.Outcome {
        var input = AIVoiceoverInput(
            lines: lines.map { .init(text: $0, start: nil) }, speed: 1, language: "en", requestedVoice: VoiceLibraryHTTP.voiceID,
            ask: .library(VoiceLibraryHTTP.voiceID), model: nil, choice: .init(engine: .skyStudio(voice: "")), target: .newAudioBottom,
            subtitles: false, maxLines: nil, generation: project.documentGeneration, folder: folder)
        input.skipOneTime = skipOneTime
        input.confirmToken = token
        return try await SkyStudioVoiceoverStart.start(input, project: project, services: services)
    }

    /// 等一个任务做完，回 get_job 的样子。
    func wait(_ result: AIToolResult) async throws -> JSONValue {
        guard let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("No job returned: \(result.payload)") }
        await AIJobs.shared.wait(for: job, seconds: 30)
        guard job.status != .running else { throw AIToolError("Library job timed out") }
        return AIJobs.shared.json(job)
    }
}
