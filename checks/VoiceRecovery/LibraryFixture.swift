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
    static var prompts: [String] = []
    static var wave = Data()

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
        if path.hasSuffix("/models") { return (200, VoiceRecoveryHTTP.catalog, nil) }
        if path.hasPrefix("/files/") { return (200, [:], wave) }
        if path.hasPrefix("/put/") { uploads.append(data.count); return (200, [:], Data()) }
        if path.hasSuffix("/uploads") {
            let index = uploads.count + 1
            return (200, ["upload_url": .string("http://127.0.0.1/put/\(index)"), "method": "PUT", "headers": ["Content-Type": "audio/wav"],
                          "file_url": .string("skystudio-private://voice/uploads/u/\(index).wav")], nil)
        }
        if path.hasSuffix("/quote") { return quoteFailure.map { ($0.0, $0.1, nil) } ?? (200, quote(body), nil) }
        if path.hasSuffix("/jobs"), method == "POST" { return (200, job(body), nil) }
        guard let range = path.range(of: "/voices") else { return error(404, "not_found") }
        return library(method, String(path[range.upperBound...]), body)
    }

    private static func library(_ method: String, _ rest: String, _ body: JSONValue) -> (Int, JSONValue, Data?) {
        if rest == "/consent-grant" { return consentGrant(method, body) }
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
            return ["credits": 22.5, "credits_expected": 22.5, "settlement": "exact", "model": "qwen3-voice-design"]
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

    private static func job(_ body: JSONValue) -> JSONValue {
        switch body["kind"]?.stringValue {
        case "voice_enroll"?:
            needsEnroll = false
            voices[voiceID] = voice(voiceID, name: "Sky", languages: ["en"], minimax: true)
            return ["job_id": "enroll-1", "status": "done", "credits_charged": 377.6, "billing": ["status": "charged", "credits_charged": 377.6],
                    "result": ["voice": voices[voiceID]!, "model": "minimax-voice-clone"]]
        case "voice_design"?:
            let id = "voice_" + String(repeating: "d", count: 32)
            voices[id] = voice(id, name: body["params"]?["name"]?.stringValue ?? "", languages: ["en"], minimax: false, source: "design")
            return ["job_id": "design-1", "status": "done", "credits_charged": 22.5, "billing": ["status": "charged", "credits_charged": 22.5],
                    "result": ["voice": voices[id]!, "model": "qwen3-voice-design", "sample_url": "https://assets.example/voices/sample.wav",
                               "sample_expires_at": "2026-11-20T11:00:00Z"]]
        default:
            let index = prompts.count
            prompts.append(body["prompt"]?.stringValue ?? "")
            let selection = body["params"]?["plan"] ?? .null
            return ["job_id": .string("clone-\(index)"), "status": "done", "credits_charged": 1.5,
                    "result": ["url": .string("http://127.0.0.1/files/clone-\(index).wav"), "content_type": "audio/wav", "duration": 6,
                               "model": selection["model"] ?? .null, "fallback_used": false, "voice_plan": ["selection": selection]]]
        }
    }
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
