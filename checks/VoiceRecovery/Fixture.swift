import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 假 HTTP 与注入的本机转写；生产任务、解码、切句、写文件、字幕和撤销都照常执行。
// `/models` 是 Sky Studio 导出的声音目录快照（checks/SkyStudio/Fixtures/models-voice-*.json），只把读稿模型的字数上限换成 `cap`，好造多批；
// `/quote` 照声音方案 5.4 回整段的 voice_plan / 每批的价（带了 params.plan 就照它，没带自己选），`/jobs` 照它带回的 plan 做完；
// 读的模型是 eleven-v4 时像 Eleven 一样回每个字的时间（`words`，字均匀铺在 0.1–5.7 秒）。
// 这台 Mac 转写得了 / 模型装没装 / 装不装得上、转写听错哪个词、哪一批听成别的话，都由 VoiceRecoveryFixture 的开关定（声音 PR 5）。
// 2026-11-10 审查补的（假协议原来太「整齐」，三个会卡死付费声音的 bug 都照不到）：转写写成简体（稿子是繁体，`simplifies`）、
// 问转写时带的语言记下来（`transcriptionLanguages`）、某一批回 24 kHz 的 WAV（Gemini 的样子，`lowRate`；别的照旧 44.1 kHz）、
// eleven-v4 的 `words` 用不了（`brokenWords`：null、或者字对不回原文）、点名 eleven-v4 读 Gemini 预设时选择里是它的 Eleven 替身。
// `deferred`（声音 PR 4）：`/jobs` 先回排队、问的时候才回结局，第几单等第几单回过结局才做完（`holdUntil`）—— 好造「几批同时在跑、后交的先回」；
// 记下同时开着最多几单（`peakOpen`）。
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
    /// 第几单以「默认失败、备用要先花一次性费用」结束（fallback_needs_one_time，钱退了）。
    static var oneTimeAt: Int?
    /// 交上来的建 MiniMax 版（voice_enroll）。
    static var enrolls: [JSONValue] = []
    /// 这个账号有没有有效的长期授权（GET /voices/consent-grant，声音 PR 7：全部权限下有就不问）。
    static var standingActive = false
    /// 报价带上备用（voice_plan.fallback.selection），中途换了备用之后的批要带它。
    static var offerFallback = false
    /// `/jobs` 先回排队，问的时候才回结局；第几单（按交的顺序）要等第几单回过结局才做完。
    static var deferred = false
    static var holdUntil: [Int: Int] = [:]
    /// 规矩（cloudFailure、oneTimeAt、fallbackAt、holdUntil）按哪一批说：给了就按这一单读的字认是第几批（几批同时交，交的顺序不一定是批的顺序），
    /// 没给按交的顺序（第几单）。
    static var promptIndex: [String: Int] = [:]
    static var open: Set<Int> = []
    static var peakOpen = 0
    /// 回过结局的（按规矩的序号），先后照回的顺序。
    static var finished: [Int] = []
    static var jobBodies: [JSONValue] = []
    static var ruleOf: [Int] = []
    /// 哪几批（按规矩的序号）回 24 kHz 的 WAV（Gemini）；别的回 44.1 kHz（Eleven 解出来的样子）。
    static var lowRate: Set<Int> = []
    static var lowWave = Data()
    /// eleven-v4 的 `words` 用不了：null，或者报的字对不回原文（字母全换成 x）。
    enum BrokenWords { case null, wrongLetters }
    static var brokenWords: BrokenWords?
    /// 这一场自己答的请求（方法、路径 → 状态码、JSON；nil 照常）：StopChecks 用它答取消和停下之后的原单。调用时已经拿着锁。
    static var override: ((String, String) -> (Int, JSONValue)?)?
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
        oneTimeAt = nil; enrolls = []; standingActive = false; offerFallback = false; deferred = false; holdUntil = [:]; promptIndex = [:]
        open = []; peakOpen = 0; finished = []; jobBodies = []; ruleOf = []
        lowRate = []; brokenWords = nil; override = nil
        let samples = (0..<264_600).map { Int16(sin(Double($0) * 0.08) * 4_000) }
        wave = VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100)
        // 同一个音（约 562 Hz）、同样 6 秒，24 kHz。
        let low = (0..<144_000).map { Int16(sin(Double($0) * 0.08 * 44_100 / 24_000) * 4_000) }
        lowWave = VoiceReferenceSample.wavData(samples: low, sampleRate: 24_000)
    }

    /// 放开「等第几单」的规矩（一直卡着的那一单这就做完）。
    static func release() { lock.lock(); holdUntil = [:]; lock.unlock() }

    static var posts: Int { lock.lock(); defer { lock.unlock() }; return prompts.count }
    static var log: [(String, String, JSONValue)] { lock.lock(); defer { lock.unlock() }; return requests }
    static func bodies(_ suffix: String) -> [JSONValue] { log.filter { $0.0 == "POST" && $0.1.hasSuffix(suffix) }.map(\.2) }
    static var peak: Int { lock.lock(); defer { lock.unlock() }; return peakOpen }
    static var finishOrder: [Int] { lock.lock(); defer { lock.unlock() }; return finished }
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
        if let (code, answer) = Self.override?(method, path) {
            status = code; value = answer
        } else if path.hasSuffix("/models") {
            value = Self.cappedCatalog()
        } else if path.hasSuffix("/voices/consent-grant") {
            value = ["grant": Self.standingActive ? ["statement_version": "voice-standing-consent-v1", "active": true] : .null,
                     "current_statement_version": "voice-standing-consent-v1"]
        } else if path.hasSuffix("/quote") {
            if let (code, answer) = Self.quoteFailure { status = code; value = answer } else { value = Self.quote(body) }
        } else if path.hasSuffix("/jobs"), method == "POST", body["kind"] == "voice_enroll" {
            // 建 MiniMax 版（声音 PR 6：备用要先花的一次性费用点过头之后）：不是读稿的一批，回声音。
            Self.enrolls.append(body)
            value = ["job_id": "enroll-1", "status": "done", "credits_charged": 377.6, "billing": ["status": "charged", "credits_charged": 377.6],
                     "result": ["model": "minimax-voice-clone", "voice": ["id": "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d", "name": "Sky", "source": "recording",
                                "languages": [["language": "en", "kind": "recording", "minimax": true]]]]]
        } else if path.hasSuffix("/jobs"), method == "POST" {
            let index = Self.prompts.count
            let prompt = body["prompt"]?.stringValue ?? ""
            Self.prompts.append(prompt)
            Self.jobBodies.append(body)
            Self.ruleOf.append(Self.promptIndex[prompt] ?? index)
            if Self.unknownSubmission {
                status = 502; value = ["unexpected": "response lost"]
            } else if Self.deferred {
                Self.open.insert(index)
                Self.peakOpen = max(Self.peakOpen, Self.open.count)
                value = ["job_id": .string("voice-\(index)"), "status": "queued", "poll_after_seconds": 2]
            } else {
                value = Self.outcome(index, body)
            }
        } else if path.contains("/jobs/voice-"), method == "GET", let index = Int(path.components(separatedBy: "/jobs/voice-").last ?? "") {
            let rule = Self.ruleOf[index]
            if let blocker = Self.holdUntil[rule], !Self.finished.contains(blocker) {
                value = ["job_id": .string("voice-\(index)"), "status": "running", "phase": "processing", "poll_after_seconds": 2]
            } else {
                value = Self.outcome(index, Self.jobBodies[index])
                Self.open.remove(index)
                if !Self.finished.contains(rule) { Self.finished.append(rule) }
            }
        } else if path.hasPrefix("/files/") {
            let index = Int(path.components(separatedBy: "voice-").last?.replacingOccurrences(of: ".wav", with: "") ?? "")
            let low = index.map { $0 < Self.ruleOf.count && Self.lowRate.contains(Self.ruleOf[$0]) } ?? false
            bytes = low ? Self.lowWave : Self.wave
        }
        Self.lock.unlock()
        let responseData = bytes ?? (try! value.encodedData())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(responseData.count), "Content-Type": bytes == nil ? "application/json" : "audio/wav"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Eleven v4 的样子：每个字（含换行）一个时间，均匀铺在 0.1–5.7 秒（6 秒的假音频里）。
    private static func characterTimes(_ prompt: String) -> JSONValue {
        let characters = Array(prompt).map(String.init)
        let step = 5.6 / Double(max(characters.count, 1))
        return [["characters": .array(characters.map(JSONValue.string)),
                 "character_start_times_seconds": .array(characters.indices.map { .number(0.1 + Double($0) * step) }),
                 "character_end_times_seconds": .array(characters.indices.map { .number(0.1 + Double($0 + 1) * step) })]]
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

    /// 第 `index` 单（按交的顺序）的结局：没做成（钱退了）、默认失败而备用要先花一次性费用，或者照带回的 plan 做完（`fallbackAt` 那一批换了备用）。
    /// 规矩按 `ruleOf`（给了 promptIndex 就是第几批）。
    private static func outcome(_ index: Int, _ body: JSONValue) -> JSONValue {
        let rule = ruleOf[index]
        if cloudFailure == rule {
            return ["job_id": .string("voice-\(index)"), "status": "failed", "error": ["message": "Provider failed"],
                    "billing": ["status": "refunded", "credits_charged": 0]]
        }
        if oneTimeAt == rule {
            return ["job_id": .string("voice-\(index)"), "status": "failed",
                    "error": ["code": "fallback_needs_one_time", "message": "The default model failed; its fallback needs a one-time fee.",
                              "one_time": [["kind": "voice_enroll", "model": "minimax-voice-clone", "language": "en", "credits": 377.6,
                                            "why": "The fallback reads with a MiniMax version of this voice."]], "refunded": true],
                    "billing": ["status": "refunded", "credits_charged": 0]]
        }
        let selection = body["params"]?["plan"] ?? .object(["model": body["model"] ?? "auto"])
        let model = fallbackAt == rule ? JSONValue.string("eleven-v4") : (selection["model"] ?? .null)
        var result: [String: JSONValue] = ["url": .string("http://127.0.0.1/files/voice-\(index).wav"), "content_type": "audio/wav",
            "duration": 6, "model": model, "fallback_used": .bool(fallbackAt == rule), "voice_plan": ["selection": selection]]
        if model == "eleven-v4" {
            let prompt = body["prompt"]?.stringValue ?? ""
            switch brokenWords {
            case .null?: result["words"] = .null
            case .wrongLetters?: result["words"] = characterTimes(String(prompt.map { $0.isLetter ? "x" : $0 }))
            case nil: result["words"] = characterTimes(prompt)
            }
        }
        return ["job_id": .string("voice-\(index)"), "status": "done", "credits_charged": 2.5, "result": .object(result)]
    }

    /// 整段报价：每批 2.5 积分（最多）、2 积分（大概）。带了 params.plan 就照它（恢复补批次），没带自己选（`rechoose` 时选成别的）。
    private static func quote(_ body: JSONValue) -> JSONValue {
        let batches = body["params"]?["batches"]?.arrayValue ?? []
        let voice = body["params"]?["voice"] ?? .null
        let model = body["model"]?.stringValue ?? "auto"
        let selection: JSONValue
        var fallback: JSONValue = .null
        if let plan = body["params"]?["plan"] { selection = plan }
        else if body["kind"] == "voice_clone" { selection = ["model": rechoose ? "minimax-speech-2.8-hd" : "index-tts-2", "reference_language": "en"] }
        else if offerFallback, model == "auto" {
            // 整段的自动备用：选择里带着它，`voice_plan.fallback.selection` 是换过去之后每批该带的那份（它自己的 fallback 是 null）。
            let backup: JSONValue = ["model": "eleven-v4", "voice": voice]
            selection = ["model": "gemini-3.8-flash-tts", "voice": voice, "fallback": backup]
            fallback = ["selection": backup, "available": true, "auto": true, "one_time": .null]
        }
        else {
            // 点名 eleven-v4 读 Gemini 的预设：服务器换成这个预设的 Eleven 替身（voice_presets[].fallback.voice）。
            let chosen = model != "auto" ? model : (rechoose ? "eleven-v4" : "gemini-3.8-flash-tts")
            let standIn = catalog["voice_presets"]?.arrayValue?.first { $0["id"] == voice }?["fallback"]?["voice"]
            let reads = chosen == "eleven-v4" && voice.stringValue?.hasPrefix("gemini:") == true ? (standIn ?? voice) : voice
            selection = ["model": .string(chosen), "voice": reads]
        }
        return ["credits": .number(2.5 * Double(batches.count)), "credits_expected": .number(2.0 * Double(batches.count)), "settlement": "exact",
                "voice_plan": ["selection": selection, "requested_model": .string(model), "rule": "preset", "reason": "A preset voice reads this text.",
                               "languages": [["language": "en", "share": 1, "seconds": 3]], "cross_language": false,
                               "warnings": .array(quoteWarnings.map(JSONValue.string)), "fallback": fallback],
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
    /// 这台 Mac 转写得了这种语言（SpeechTranscriber 支持）；`installed` 是模型装没装，没装的任务里先装，`installFailure` 让装失败。
    var transcribes = true
    var installed = true
    var installFailure: String?
    /// 每次装模型时已经交了几批（付费请求之前装的是 0）。
    var installs: [Int] = []
    var transcriptions = 0
    /// 转写听错的词（原文的词 → 听成的）、哪一批整个听成别的话。
    var mishear: [String: String] = [:]
    var garbleAt: Int?
    /// 转写写成简体、一个字一个词（稿子是繁体：简体模型、或者系统自己写成简体）。
    var simplifies = false
    /// 每次问「这台 Mac 转写得了吗」时带的语言。
    var transcriptionLanguages: [String] = []
    var keyReads = 0
    /// 这个场景自己的槽，不碰全 App 那一份：默认声音池 1 个（一批一批交，交的顺序就是批的顺序，老的恢复场景照旧算得准）；
    /// 几批同时交的场景给 2 个（好造「几批同时在跑、还有几批等空位」）。
    let slots: SkyStudioJobSlots

    init(folder: URL, cap: Int = 30, audioSlots: Int = 1) throws {
        self.folder = folder
        slots = SkyStudioJobSlots(limits: .init(shared: 3, audio: audioSlots))
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
        services.transcription = { language in
            self.transcriptionLanguages.append(language)
            guard self.transcribes else { return .unavailable }
            return self.installed ? .installed(Locale(identifier: "en-US")) : .downloadable(Locale(identifier: "en-US"))
        }
        services.install = { _, progress in
            self.installs.append(VoiceRecoveryHTTP.posts)
            progress(0.5)
            if let failure = self.installFailure { throw AIToolError(failure) }
            progress(1)
            self.installed = true
        }
        services.slots = slots
        services.jobSleep = { _ in try await Task.sleep(nanoseconds: 5_000_000) }
        services.transcribe = { file, _ in
            self.transcriptions += 1
            let index = Int(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "batch-", with: ""))!
            if index == 1, self.cancelSplitOnce { self.cancelSplitOnce = false; throw CancellationError() }
            if index == 1, self.failSplitOnce { self.failSplitOnce = false; return [] }
            if self.failSubtitleOnce { self.failSubtitleOnce = false; return [] }
            if index == self.garbleAt { return [TimedWord(text: "Totally unrelated words", start: 0.1, end: 5.7)] }
            // 这一批读的是哪几句：照恢复记录（几批同时交，交的顺序不一定是批的顺序）。
            let record = try SkyStudioVoiceRecoveryStore.read(file.deletingLastPathComponent().appendingPathComponent("voiceover-recovery.json"))
            let prompt = record.plan.batches[index].speech.prompt
            if self.simplifies {
                let simplified = prompt.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? prompt
                let characters = simplified.filter { !$0.isWhitespace }.map(String.init)
                let step = 5.6 / Double(characters.count)
                return characters.enumerated().map { TimedWord(text: $0.element, start: 0.1 + Double($0.offset) * step,
                                                                 end: 0.1 + Double($0.offset + 1) * step) }
            }
            let tokens = prompt.split(whereSeparator: { $0.isWhitespace })
                .flatMap { (self.mishear[String($0)] ?? String($0)).split(separator: " ").map(String.init) }
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

    /// 声音库的声音（voice_clone）：MCP 的入口是声音 PR 6，这里照生产的那几块拼好报价、预留，直接起任务（合批、切句那一摊）；
    /// 怎么读照生产的 SkyStudioVoiceReading（这台 Mac 转写不了就一句一单、按字数估）。
    func clone(_ lines: [String], subtitles: Bool = true) async throws -> AIToolResult {
        let services = services
        let key = try await services.key()
        let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api)
        let voice = "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"
        let reading = SkyStudioVoiceReading.decide(kind: SkyStudioVoiceKind.clone, voice: voice, model: nil, subtitles: subtitles,
                                                   language: "en", transcribes: transcribes, catalog: catalog)
        let draft = try SkyStudioVoicePlan.draft(lines: lines, kind: SkyStudioVoiceKind.clone, voice: voice,
                                                 reading: reading, language: "en", catalog: catalog)
        let quote = try await services.api.quote(draft.segment, key: key)
        let plan = try SkyStudioVoicePlan.quoted(draft, quote: quote)
        guard let budget = SkyStudioVoiceBudget.reserve(plan.batchCredits) else { throw AIToolError("No budget for the clone fixture") }
        var input = input(lines: lines, subtitles: subtitles)
        input.ask = nil
        input.choice = .init(engine: .skyStudio(voice: plan.voice))
        let prepared = SkyStudioVoiceoverPrepared(plan: plan, quote: quote, budget: budget, key: key,
                                                  locale: transcribes ? Locale(identifier: "en-US") : nil, modelTitle: "IndexTTS2")
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
