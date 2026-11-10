import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 假 HTTP 与注入的本机转写；生产任务、解码、切句、写文件、字幕和撤销都照常执行。
final class VoiceRecoveryHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [(String, String, JSONValue)] = []
    static var prompts: [String] = []
    static var wave = Data()
    /// 克隆用的参考素材：12 秒有声（参考录音至少 10 秒有效人声）。
    static var reference = Data()
    /// PUT 上去的原始字节（参考录音）。
    static var uploaded: [Data] = []
    static var cloudFailure: Int?
    static var unknownSubmission = false
    static var cap = 30

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceRecoveryHTTP.self]
        return URLSession(configuration: configuration)
    }()

    static func reset(cap: Int = 30, cloudFailure: Int? = nil, unknownSubmission: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        requests = []; prompts = []; uploaded = []
        self.cap = cap; self.cloudFailure = cloudFailure; self.unknownSubmission = unknownSubmission
        let samples = (0..<264_600).map { Int16(sin(Double($0) * 0.08) * 4_000) }
        wave = VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100)
        reference = VoiceReferenceSample.wavData(samples: (0..<529_200).map { Int16(sin(Double($0) * 0.08) * 4_000) }, sampleRate: 44_100)
    }

    static var posts: Int { lock.lock(); defer { lock.unlock() }; return prompts.count }
    static var uploads: [Data] { lock.lock(); defer { lock.unlock() }; return uploaded }
    static var log: [(String, String, JSONValue)] { lock.lock(); defer { lock.unlock() }; return requests }
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
        if method == "PUT" { Self.uploaded.append(data ?? Data()) }
        var status = 200
        var value: JSONValue = [:]
        var bytes: Data?
        if path.hasSuffix("/models") {
            value = ["models": [["id": "recovery-clone", "kind": "voice_clone", "title": "Recovery fixture",
                       "params": ["language": ["en_us"]], "limits": ["max_characters_by_language": ["en_us": .number(Double(Self.cap))]]]]]
        } else if path.hasSuffix("/quote") { value = ["credits": 2.5] }
        else if path.hasSuffix("/uploads") {
            value = ["upload_url": "http://127.0.0.1/put/reference.wav", "file_url": "http://127.0.0.1/files/reference.wav", "headers": [:]]
        } else if path.hasSuffix("/jobs"), method == "POST" {
            let index = Self.prompts.count
            Self.prompts.append(body["prompt"]?.stringValue ?? "")
            if Self.unknownSubmission {
                status = 502; value = ["unexpected": "response lost"]
            } else if Self.cloudFailure == index {
                value = ["job_id": .string("voice-\(index)"), "status": "failed", "error": ["message": "Provider failed"],
                         "billing": ["status": "refunded", "credits_charged": 0]]
            } else {
                value = ["job_id": .string("voice-\(index)"), "status": "done", "credits_charged": 2.5,
                         "result": ["url": .string("http://127.0.0.1/files/voice-\(index).wav"), "content_type": "audio/wav", "duration": 6]]
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
}

@MainActor
final class VoiceRecoveryFixture {
    let folder: URL
    let project: VideoEditProject
    var failSplitOnce = true
    var failSubtitleOnce = false
    var cancelSplitOnce = false
    var keyReads = 0

    init(folder: URL) throws {
        self.folder = folder
        project = OpenProjects.shared.primary
        project.linkageEnabled = false
        _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform { $0 = TimelineState() } }
        project.effectiveUndoManager?.removeAllActions()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project.documentURL = folder.appendingPathComponent("recovery.skycut")
        VoiceRecoveryHTTP.reset()
        SkyStudioCatalogCache.shared.forget()
        SkyStudioSpendStore.shared.setDailyLimit(1_000)
        AIReadGrants.shared.remember([folder.appendingPathComponent("allowed")])
    }

    var services: SkyStudioVoiceServices {
        var services = SkyStudioVoiceServices()
        services.api = SkyStudioAPI(session: VoiceRecoveryHTTP.session, base: URL(string: "http://127.0.0.1/api/skycut/v1")!, machine: nil)
        services.key = { self.keyReads += 1; return "local-recovery-fixture" }
        services.locale = { _ in Locale(identifier: "en-US") }
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

    func input(lines: [String]) throws -> AIVoiceoverInput {
        let reference = folder.appendingPathComponent("reference.wav")
        try VoiceRecoveryHTTP.reference.write(to: reference)
        return AIVoiceoverInput(lines: lines.map { .init(text: $0, start: nil) }, speed: 1, language: "en", requestedVoice: nil,
            choice: .init(engine: .skyStudio(voice: "cloned voice")), clone: .init(url: reference, start: 0, seconds: nil),
            target: .newAudioBottom, subtitles: true, maxLines: 1, generation: project.documentGeneration, folder: folder)
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

    func resume(_ file: String, generate: Bool = false) async throws -> JSONValue {
        let args = AIToolArguments(["resume": .string(file), "generate_missing": .bool(generate)])
        guard let result = try await SkyStudioVoiceRecovery.resumeIfAsked(args, project: project, services: services) else {
            throw AIToolError("Recovery entry was not connected")
        }
        return try await wait(result)
    }
}
