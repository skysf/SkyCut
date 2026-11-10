import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 变声（声音 PR 9）的假 Sky Studio：`/models`（Sky Studio 导出的目录快照，voice_convert 的上限 300 秒）、`/voices` 和 `/voices/{id}`、
// `/uploads` + PUT（收下传上来的字节）、`voice_convert` 的 `/quote` 和 `/jobs`（可以先回 queued、等回归放行再 done；可以回失败、断网）、
// 两个成品文件。生产的工具、面板背后的那一份、任务、下载、落地、撤销照常执行。和别的几份假协议分开写，场景互不影响。

final class VoiceChangeHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [(method: String, path: String, body: JSONValue)] = []
    /// PUT 上来的字节（每次上传一份）。
    static var uploads: [Data] = []
    static var voices: [String: JSONValue] = [:]
    /// GET /voices、GET /voices/{id} 直接回这个（声音库用不了）。
    static var libraryFailure: (Int, JSONValue)?
    static var quoteFailure: (Int, JSONValue)?
    /// POST /jobs：断网（结果不明）。
    static var submitNetworkFailure = false
    /// POST /jobs 先回 queued；GET /jobs/{id} 等这个变成 true 才回 done。
    static var holdJob = false
    static var released = true
    /// 这一单服务器说没做成（钱退了）。
    static var jobFails = false
    /// 人声比源长多少秒（Chatterbox HD 实测长 5–35 ms）；背景和源一样长，除非另给。
    static var voiceExtraSeconds = 0.02
    static var backgroundSeconds: Double?
    static var sourceSeconds = 4.0
    static var charged = 7.5

    static let voiceID = "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceChangeHTTP.self]
        return URLSession(configuration: configuration)
    }()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []; uploads = []
        voices = [voiceID: voice(voiceID, name: "Sky", languages: ["zh", "en"])]
        libraryFailure = nil; quoteFailure = nil; submitNetworkFailure = false; holdJob = false; released = true; jobFails = false
        voiceExtraSeconds = 0.02; backgroundSeconds = nil; sourceSeconds = 4.0; charged = 7.5
    }

    static var log: [(method: String, path: String, body: JSONValue)] { lock.lock(); defer { lock.unlock() }; return requests }
    static func calls(_ method: String, _ suffix: String) -> [JSONValue] { log.filter { $0.method == method && $0.path.hasSuffix(suffix) }.map(\.body) }
    static func index(_ method: String, _ suffix: String) -> Int? { log.firstIndex { $0.method == method && $0.path.hasSuffix(suffix) } }
    static var uploaded: [Data] { lock.lock(); defer { lock.unlock() }; return uploads }

    static func voice(_ id: String, name: String, languages: [String], source: String = "recording") -> JSONValue {
        ["id": .string(id), "name": .string(name), "source": .string(source), "scope": "personal",
         "languages": .array(languages.map { ["language": .string($0), "kind": "recording", "seconds": 29.5, "minimax": false] })]
    }

    /// 一段正弦波的单声道 WAV（成品文件用）。
    static func wave(seconds: Double, rate: Int = 44_100) -> Data {
        let samples = (0..<Int(seconds * Double(rate))).map { Int16(sin(Double($0) * 0.07) * 5_000) }
        return VoiceReferenceSample.wavData(samples: samples, sampleRate: rate)
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
        let answer = Self.answer(method, path, body, data)
        Self.lock.unlock()
        guard let (status, value, bytes) = answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
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
        var buffer = [UInt8](repeating: 0, count: 65_536)
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

    // 调用时已经拿着锁。nil = 断网。
    private static func answer(_ method: String, _ path: String, _ body: JSONValue, _ data: Data) -> (Int, JSONValue, Data?)? {
        if path.hasSuffix("/models") { return (200, VoiceRecoveryHTTP.catalog, nil) }
        if path.hasSuffix("/files/voice.wav") { return (200, [:], wave(seconds: sourceSeconds + voiceExtraSeconds)) }
        if path.hasSuffix("/files/background.wav") { return (200, [:], wave(seconds: backgroundSeconds ?? sourceSeconds)) }
        if path.hasPrefix("/put/") { uploads.append(data); return (200, [:], Data()) }
        if path.hasSuffix("/uploads") {
            return (200, ["upload_url": .string("http://127.0.0.1/put/\(uploads.count + 1)"), "method": "PUT", "headers": ["Content-Type": "audio/wav"],
                          "file_url": .string("skystudio-private://voice/uploads/u/\(uploads.count + 1).wav")], nil)
        }
        if path.hasSuffix("/quote") {
            if let (status, value) = quoteFailure { return (status, value, nil) }
            return (200, ["credits": 9, "credits_expected": 6, "settlement": "actual_output", "typical_seconds": 90, "model": "chatterbox-hd"], nil)
        }
        if path.hasSuffix("/jobs"), method == "POST" {
            if submitNetworkFailure { return nil }
            if holdJob { return (200, ["job_id": "convert-1", "kind": "voice_convert", "status": "queued", "queue_position": 1, "poll_after_seconds": 2], nil) }
            return (200, finished(body), nil)
        }
        if path.hasSuffix("/jobs/convert-1"), method == "GET" {
            if !released { return (200, ["job_id": "convert-1", "kind": "voice_convert", "status": "running", "poll_after_seconds": 2], nil) }
            return (200, finished(body), nil)
        }
        guard let range = path.range(of: "/voices") else { return error(404, "not_found") }
        if let (status, value) = libraryFailure { return (status, value, nil) }
        let rest = String(path[range.upperBound...])
        if rest.isEmpty || rest == "/" {
            return (200, ["voices": .array(voices.values.sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") }), "next_cursor": .null], nil)
        }
        if rest == "/consent-grant" { return (200, ["grant": .null, "current_statement_version": "voice-standing-consent-v1"], nil) }
        guard let voice = voices[String(rest.dropFirst())] else { return error(404, "not_found") }
        return (200, ["voice": voice], nil)
    }

    private static func finished(_ body: JSONValue) -> JSONValue {
        if jobFails {
            return ["job_id": "convert-1", "kind": "voice_convert", "status": "failed", "error": "The separation model failed.",
                    "billing": ["status": "refunded", "credits_charged": 0, "credits_reserved": 9, "credits_returned": 9]]
        }
        return ["job_id": "convert-1", "kind": "voice_convert", "status": "done", "credits_charged": .number(charged),
                "billing": ["status": "charged", "credits_charged": .number(charged)],
                "result": ["voice_url": "http://127.0.0.1/files/voice.wav", "background_url": "http://127.0.0.1/files/background.wav",
                           "content_type": "audio/wav", "sample_rate": 44_100, "channels": 1,
                           "duration": .number(sourceSeconds + voiceExtraSeconds), "source_duration": .number(sourceSeconds),
                           "padded_seconds": 0, "model": "chatterbox-hd", "fallback_used": false]]
    }
}

@MainActor
final class VoiceChangeFixture {
    let folder: URL
    let project: VideoEditProject
    /// 本机语言检测的假：回这个、数被叫了几次。
    var detected: String?
    private(set) var detections = 0

    init(folder: URL) throws {
        self.folder = folder
        project = OpenProjects.shared.primary
        project.linkageEnabled = true
        _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform { $0 = TimelineState() } }
        project.effectiveUndoManager?.removeAllActions()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        project.documentURL = folder.appendingPathComponent("change.skycut")
        project.notice = nil
        VoiceChangeHTTP.reset()
        SkyStudioCatalogCache.shared.forget()
        SkyStudioSpendStore.shared.setDailyLimit(100_000)
        AIReadGrants.shared.remember([folder.appendingPathComponent("media")])
        UserDefaults.standard.removeObject(forKey: VoiceChangeActivity.lastVoiceKey)
    }

    var api: SkyStudioAPI { SkyStudioAPI(session: VoiceChangeHTTP.session, base: URL(string: "http://127.0.0.1/api/skycut/v1")!, machine: nil) }

    var services: VoiceChangeServices {
        var services = VoiceChangeServices()
        services.voice.api = api
        services.voice.key = { "local-voice-change-fixture" }
        services.voice.slots = SkyStudioJobSlots(limits: .init(shared: 3, audio: 8))
        services.voice.jobSleep = { _ in try await Task.sleep(nanoseconds: 5_000_000) }
        services.detectLanguage = { [weak self] _, _ in
            self?.detections += 1
            return self?.detected
        }
        services.workFolder = folder.appendingPathComponent("work")
        return services
    }

    /// 一段**立体声** 48 kHz 16-bit 的 WAV（左右声道各一个正弦波，够响）；`silent` 全零。
    func stereoSource(_ name: String = "talk.wav", seconds: Double = 6, rate: Int = 48_000, silent: Bool = false) throws -> URL {
        let frames = Int(seconds * Double(rate))
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); append32(UInt32(36 + frames * 4))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16); append16(1); append16(2)
        append32(UInt32(rate)); append32(UInt32(rate * 4)); append16(4); append16(16)
        data.append(contentsOf: "data".utf8); append32(UInt32(frames * 4))
        var samples = [Int16](repeating: 0, count: frames * 2)
        if !silent {
            for frame in 0..<frames {
                samples[frame * 2] = Int16(sin(Double(frame) * 0.05) * 8_000)
                samples[frame * 2 + 1] = Int16(sin(Double(frame) * 0.09) * 4_000)
            }
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let url = folder.appendingPathComponent("media").appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 时间线上放一段只取声音的段（A1）：用素材的 `[1, 5)` 秒，放在 2 秒处，带音量、渐入渐出、音量曲线。回它的 id。
    @discardableResult
    func placeClip(_ source: URL, sourceStart: Double = 1, sourceDuration: Double = 4, assetSeconds: Double = 6, muted: Bool = false) -> UUID {
        var clip = EditClip(sourceURL: source, isAudioOnly: true, sourceStart: sourceStart, sourceDuration: sourceDuration, timelineStart: 2,
                            isMuted: muted, volume: 0.7, fadeInDuration: 0.2, fadeOutDuration: 0.3, audioAssetDuration: assetSeconds)
        clip.volumeCurve = KeyframeTrack(keys: [Keyframe(time: sourceStart + 0.5, value: -3), Keyframe(time: sourceStart + 2, value: -9)])
        _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform { $0.audioTracks = [EditLane(clips: [clip])] } }
        project.effectiveUndoManager?.removeAllActions()
        return clip.id
    }

    func change(_ args: JSONValue) async throws -> AIToolResult {
        try await VoiceChangeTool.change(AIToolArguments(args), project, services: services)
    }

    func short(_ id: UUID) -> String { AIShortIDs(state: project.state).short(id) }

    /// 等一个任务做完，回 get_job 的样子。
    func wait(_ result: AIToolResult) async throws -> JSONValue {
        guard let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("No job returned: \(result.payload)") }
        await AIJobs.shared.wait(for: job, seconds: 30)
        guard job.status != .running else { throw AIToolError("Voice change job timed out") }
        return AIJobs.shared.json(job)
    }
}

/// 传上去的 WAV 的头：声道数、采样率、位深、数据多少字节。
struct WaveHeader {
    let channels: Int
    let sampleRate: Int
    let bits: Int
    let dataBytes: Int

    init?(_ data: Data) {
        guard data.count >= 44, String(decoding: data[0..<4], as: UTF8.self) == "RIFF", String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func little(_ offset: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) } }
        channels = little(22, 2)
        sampleRate = little(24, 4)
        bits = little(34, 2)
        dataBytes = little(40, 4)
    }
}
