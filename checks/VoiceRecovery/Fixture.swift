import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 假 HTTP 与注入的本机转写；生产任务、解码、切句、写文件、字幕和撤销都照常执行。
// `/models` 是 Sky Studio 导出的声音目录快照（checks/SkyStudio/Fixtures/models-voice-*.json），只把读稿模型的字数上限换成 `cap`，好造多批；
// `/quote` 照声音方案 5.4 回整段的 voice_plan / 每批的价（带了 params.plan 就照它，没带自己选），`/jobs` 照它带回的 plan 做完。
final class VoiceRecoveryHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [(String, String, JSONValue)] = []
    static var prompts: [String] = []
    static var wave = Data()
    static var cloudFailure: Int?
    static var unknownSubmission = false
    static var cap = 30
    /// 没带 params.plan 的报价换一个模型选（恢复时打开：恢复补批次要是不带原来的选择，服务器就会选成别的、被认出来）。
    static var rechoose = false
    /// `/quote` 直接回这个（状态码、JSON），不算报价。
    static var quoteFailure: (Int, JSONValue)?
    /// 报价的 warnings、一次性费用。
    static var quoteWarnings: [String] = []
    static var quoteOneTime: JSONValue = []
    /// 第几个 `/jobs` 回答说服务器在这一批里换了备用。
    static var fallbackAt: Int?
    static let catalog: JSONValue = {
        let data = FileManager.default.contents(atPath: "checks/SkyStudio/Fixtures/models-voice-2026-11-10.json") ?? Data()
        return (try? JSONValue.decode(data)) ?? [:]
    }()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceRecoveryHTTP.self]
        return URLSession(configuration: configuration)
    }()

    static func reset(cap: Int = 30, cloudFailure: Int? = nil, unknownSubmission: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        requests = []; prompts = []
        self.cap = cap; self.cloudFailure = cloudFailure; self.unknownSubmission = unknownSubmission
        rechoose = false; quoteFailure = nil; quoteWarnings = []; quoteOneTime = []; fallbackAt = nil
        let samples = (0..<264_600).map { Int16(sin(Double($0) * 0.08) * 4_000) }
        wave = VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100)
    }

    static var posts: Int { lock.lock(); defer { lock.unlock() }; return prompts.count }
    static var log: [(String, String, JSONValue)] { lock.lock(); defer { lock.unlock() }; return requests }
    static func bodies(_ suffix: String) -> [JSONValue] { log.filter { $0.0 == "POST" && $0.1.hasSuffix(suffix) }.map(\.2) }
    static func prompt(_ index: Int) -> String { lock.lock(); defer { lock.unlock() }; return prompts[index] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        var data = request.httpBody
        if let stream = request.httpBodyStream {
            stream.open()
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            stream.close()
            data = bytes
        }
        let body = data.flatMap { try? JSONValue.decode($0) } ?? .null
        Self.lock.lock()
        Self.requests.append((method, path, body))
        var status = 200
        var value: JSONValue = [:]
        var bytes: Data?
        if path.hasSuffix("/models") {
            value = Self.cappedCatalog()
        } else if path.hasSuffix("/quote") {
            if let (code, answer) = Self.quoteFailure { status = code; value = answer } else { value = Self.quote(body) }
        } else if path.hasSuffix("/jobs"), method == "POST" {
            let index = Self.prompts.count
            Self.prompts.append(body["prompt"]?.stringValue ?? "")
            if Self.unknownSubmission {
                status = 502; value = ["unexpected": "response lost"]
            } else if Self.cloudFailure == index {
                value = ["job_id": .string("voice-\(index)"), "status": "failed", "error": ["message": "Provider failed"],
                         "billing": ["status": "refunded", "credits_charged": 0]]
            } else {
                let selection = body["params"]?["plan"] ?? .object(["model": body["model"] ?? "auto"])
                let model = Self.fallbackAt == index ? JSONValue.string("eleven-v4") : (selection["model"] ?? .null)
                value = ["job_id": .string("voice-\(index)"), "status": "done", "credits_charged": 2.5,
                         "result": ["url": .string("http://127.0.0.1/files/voice-\(index).wav"), "content_type": "audio/wav", "duration": 6,
                                    "model": model, "fallback_used": .bool(Self.fallbackAt == index), "voice_plan": ["selection": selection]]]
            }
        } else if path.hasPrefix("/files/") { bytes = Self.wave }
        Self.lock.unlock()
        let responseData = bytes ?? (try! value.encodedData())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(responseData.count), "Content-Type": bytes == nil ? "application/json" : "audio/wav"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// 目录快照，读稿模型的字数上限换成 `cap`（每种语言都一样）。
    private static func cappedCatalog() -> JSONValue {
        guard var root = catalog.objectValue, let models = root["models"]?.arrayValue else { return catalog }
        root["models"] = .array(models.map { model in
            guard var entry = model.objectValue, ["voice", "voice_clone"].contains(entry["kind"]?.stringValue ?? "") else { return model }
            var limits = entry["limits"]?.objectValue ?? [:]
            limits["max_characters_by_language"] = ["zh": .number(Double(cap)), "ja": .number(Double(cap)), "ko": .number(Double(cap)),
                                                    "other": .number(Double(cap))]
            entry["limits"] = .object(limits)
            return .object(entry)
        })
        return .object(root)
    }

    /// 整段报价：每批 2.5 积分（最多）、2 积分（大概）。带了 params.plan 就照它（恢复补批次），没带自己选（`rechoose` 时选成别的）。
    private static func quote(_ body: JSONValue) -> JSONValue {
        let batches = body["params"]?["batches"]?.arrayValue ?? []
        let voice = body["params"]?["voice"] ?? .null
        let model = body["model"]?.stringValue ?? "auto"
        let selection: JSONValue
        if let plan = body["params"]?["plan"] { selection = plan }
        else if body["kind"] == "voice_clone" { selection = ["model": rechoose ? "minimax-speech-2.8-hd" : "index-tts-2", "reference_language": "en"] }
        else { selection = ["model": .string(model != "auto" ? model : (rechoose ? "eleven-v4" : "gemini-3.8-flash-tts")), "voice": voice] }
        return ["credits": .number(2.5 * Double(batches.count)), "credits_expected": .number(2.0 * Double(batches.count)), "settlement": "exact",
                "voice_plan": ["selection": selection, "requested_model": .string(model), "rule": "preset", "reason": "A preset voice reads this text.",
                               "languages": [["language": "en", "share": 1, "seconds": 3]], "cross_language": false,
                               "warnings": .array(quoteWarnings.map(JSONValue.string))],
                "batches": .array(batches.map { ["credits": 2.5, "credits_expected": 2, "characters": .number(Double($0.stringValue?.count ?? 0))] }),
                "one_time": quoteOneTime]
    }
}

@MainActor
final class VoiceRecoveryFixture {
    let folder: URL
    let project: VideoEditProject
    var failSplitOnce = true
    var failSubtitleOnce = false
    var cancelSplitOnce = false
    var transcribes = true
    var keyReads = 0

    init(folder: URL, cap: Int = 30) throws {
        self.folder = folder
        project = OpenProjects.shared.primary
        project.linkageEnabled = false
        _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform { $0 = TimelineState() } }
        project.effectiveUndoManager?.removeAllActions()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project.documentURL = folder.appendingPathComponent("recovery.skycut")
        VoiceRecoveryHTTP.reset(cap: cap)
        SkyStudioCatalogCache.shared.forget()
        SkyStudioSpendStore.shared.setDailyLimit(1_000)
        AIReadGrants.shared.remember([folder.appendingPathComponent("allowed")])
    }

    var services: SkyStudioVoiceServices {
        var services = SkyStudioVoiceServices()
        services.api = SkyStudioAPI(session: VoiceRecoveryHTTP.session, base: URL(string: "http://127.0.0.1/api/skycut/v1")!, machine: nil)
        services.key = { self.keyReads += 1; return "local-recovery-fixture" }
        services.locale = { _ in
            guard self.transcribes else { throw AIToolError("No speech transcription model for English on this Mac.") }
            return Locale(identifier: "en-US")
        }
        services.transcribe = { file, _ in
            let index = Int(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "batch-", with: ""))!
            if index == 1, self.cancelSplitOnce { self.cancelSplitOnce = false; throw CancellationError() }
            if index == 1, self.failSplitOnce { self.failSplitOnce = false; return [] }
            if self.failSubtitleOnce { self.failSubtitleOnce = false; return [] }
            let tokens = VoiceRecoveryHTTP.prompt(index).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let step = 5.6 / Double(tokens.count)
            return tokens.enumerated().map { TimedWord(text: ($0.offset == 0 ? "" : " ") + $0.element,
                start: 0.1 + Double($0.offset) * step, end: 0.1 + Double($0.offset + 1) * step - 0.1) }
        }
        return services
    }

    /// add_voiceover 读完参数的样子：`ask` = 要 Sky Studio 的哪个声音（没给 = 默认预设）。
    func input(lines: [String], ask: SkyStudioVoiceAsk = .standard, model: String? = nil, subtitles: Bool = true) -> AIVoiceoverInput {
        AIVoiceoverInput(lines: lines.map { .init(text: $0, start: nil) }, speed: 1, language: AITextLanguage.dominant(in: lines).map(AIVoiceChoice.baseLanguage) ?? "en",
            requestedVoice: nil, ask: ask, model: model, choice: .init(engine: .skyStudio(voice: "")),
            target: .newAudioBottom, subtitles: subtitles, maxLines: 1, generation: project.documentGeneration, folder: folder)
    }

    /// 普通旁白：走生产的 SkyStudioVoiceoverStart（报价、预留、起任务）。
    func narrate(_ lines: [String], ask: SkyStudioVoiceAsk = .standard, model: String? = nil, subtitles: Bool = true) async throws
        -> SkyStudioVoiceoverStart.Outcome {
        try await SkyStudioVoiceoverStart.start(input(lines: lines, ask: ask, model: model, subtitles: subtitles), project: project, services: services)
    }

    /// 声音库的声音（voice_clone）：MCP 的入口是声音 PR 6，这里照生产的那几块拼好报价、预留，直接起任务（合批、切句那一摊）。
    func clone(_ lines: [String]) async throws -> AIToolResult {
        let services = services
        let key = try await services.key()
        let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api)
        let draft = try SkyStudioVoicePlan.draft(lines: lines, kind: SkyStudioVoiceKind.clone, voice: "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d",
                                                 model: SkyStudioVoiceRequests.autoModel, language: "en", catalog: catalog)
        let quote = try await services.api.quote(draft.segment, key: key)
        let plan = try SkyStudioVoicePlan.quoted(draft, quote: quote)
        guard let budget = SkyStudioVoiceBudget.reserve(plan.batchCredits) else { throw AIToolError("No budget for the clone fixture") }
        var input = input(lines: lines)
        input.ask = nil
        input.choice = .init(engine: .skyStudio(voice: plan.voice))
        let prepared = SkyStudioVoiceoverPrepared(plan: plan, quote: quote, budget: budget, key: key,
                                                  locale: Locale(identifier: "en-US"), modelTitle: "IndexTTS2")
        return SkyStudioVoiceoverRun(input: input, project: project, prepared: prepared, services: services).start()
    }

    func wait(_ result: AIToolResult) async throws -> JSONValue {
        guard let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("No job returned: \(result.payload)") }
        await AIJobs.shared.wait(for: job, seconds: 30)
        let value = AIJobs.shared.json(job)
        let summary: JSONValue = ["job_id": .string(id), "status": value["status"] ?? .null,
            "failure_stage": value["failure_stage"] ?? .null, "completed": value["completed_line_indices"] ?? .null,
            "not_generated": value["not_generated_batch_indices"] ?? .null, "cloud_POSTs": .number(Double(VoiceRecoveryHTTP.posts)),
            "message": value["message"] ?? .null]
        print(summary.encodedString())
        guard job.status != .running else { throw AIToolError("Recovery job timed out") }
        return value
    }

    func started(_ outcome: SkyStudioVoiceoverStart.Outcome) throws -> AIToolResult {
        guard case .result(let result) = outcome else { throw AIToolError("Expected a started voiceover, got \(outcome)") }
        return result
    }

    func resume(_ file: String, generate: Bool = false) async throws -> JSONValue {
        let args = AIToolArguments(["resume": .string(file), "generate_missing": .bool(generate)])
        guard let result = try await SkyStudioVoiceRecovery.resumeIfAsked(args, project: project, services: services) else {
            throw AIToolError("Recovery entry was not connected")
        }
        return try await wait(result)
    }
}

/// 检查不过的条数（几个文件共用）。
@MainActor enum VoiceCheckLog {
    static var failures = 0
}

@MainActor func require(_ condition: Bool, _ message: String) {
    if !condition { VoiceCheckLog.failures += 1; print("FAIL: \(message)") }
}
