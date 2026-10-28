import Foundation
import SrtFlowMCPKit

// MARK: - 一次 upscale 从原片到落盘的流水线（不碰界面、不碰账本、不碰钥匙串）
//
// 管什么：裁出那一段（或整个 mp4 直接用）→ 探它的宽、高、时长、帧率（`params.source` 照**送上去的那个文件**报，服务器会再读一遍，
// 差太多回 price_changed）→ 传到 Sky Studio（`/uploads` + PUT）→ 交任务、等它做完（SkyStudioJobRun：满了等着再交、照 poll_after_seconds 问、
// 停的时候排队中的退钱 / 开始了的取消不了）→ 下载成品 → 把原片那一段声音封回去 → 探测 → 起名落盘。
// 每一步报阶段（`FalJobPhase`，上传 / 下载带字节比例），Task 被取消时每一步都停得下来，中间文件不留。
// 结果是一个 `UpscaleOutcome`：文件、探测信息、来源记录（换源时拼成 `ClipSourceSwap.Replacement`）、实收的积分。
// 2026-10-28 起走 Sky Studio（收费方案第 6 刀），之前走 fal。自检用假 URLSession 走整条线（checks/Upscale）。
// 不管什么：花钱的把关和记账、Key（UpscaleJob）；换源（VideoEditClipUpscale.swift）；界面。

struct UpscaleRequest: Sendable {
    var originalURL: URL
    var originalInfo: MediaInfo
    var range: UpscaleRange
    var tier: UpscaleTier
    var target: UpscaleTarget
    /// 用户同意的价（/quote 报的积分）：交任务时当 `max_credits`，服务器算出来更贵就回 price_changed、一分不扣。
    var credits: Double
    /// 这一档通常要多久（/quote 报的）：进度里的「通常约几分钟」。
    var typicalSeconds: Double?
    /// 原片的文件夹写不进去时退到哪（工程的家、下载）。
    var fallbackFolders: [URL]

    /// 不问服务器先估的输出尺寸（起名在落盘时照做出来的文件，这个只给人看）。
    var estimatedOutputSize: CGSize { target.outputSize(for: originalInfo.displaySize) }

    /// 报价 / 交任务的那一份（交任务时另加 inputs 和 max_credits）。`source` 照送上去的那个文件。
    static func job(tier: UpscaleTier, target: UpscaleTarget, source: JSONValue) -> SkyStudioJobRequest {
        SkyStudioJobRequest(kind: "upscale", model: tier.id, params: ["target": .string(target.skyStudioName), "source": source])
    }

    /// `params.source`：宽、高、时长（两位小数）、帧率（2026-10-28 Sky Studio 实测的写法）。
    static func source(size: CGSize, seconds: Double, frameRate: Double) -> JSONValue {
        func two(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        return [
            "width": .number(size.width.rounded()), "height": .number(size.height.rounded()),
            "seconds": .number(two(seconds)), "fps": .number(two(frameRate))
        ]
    }
}

struct UpscaleOutcome: Sendable {
    var file: URL
    var info: MediaInfo
    var record: ClipUpscaleRecord
    var jobID: String
    /// Sky Studio 实收的积分（做完的那一份状态里的 `credits_charged`；没报就是同意的价）。
    var creditsCharged: Double
    /// 原片的声音封回去了（原片没声音时也算 true：没什么可封的）；ffmpeg 不在时是 false，文件没有声音。
    var audioRestored: Bool
    var elapsed: Double
}

enum UpscalePipelineError: Error, Equatable {
    case trim(String)
    case probe(String)
    case save(String)
    /// 裁出来的文件比 Sky Studio 收的大。
    case tooLarge(limit: Int)
    var message: String {
        switch self {
        case .trim(let detail): return "Could not cut the clip for upscaling: \(detail)"
        case .probe(let detail): return "Could not read the upscaled file: \(detail)"
        case .save(let detail): return "Could not save the upscaled file: \(detail)"
        case .tooLarge(let limit): return "The clip is larger than the \(limit / 1_000_000) MB Sky Studio accepts; upscale a shorter range."
        }
    }
}

/// 取消的标志：阻塞的裁切跑在 OperationQueue 的线程上，那里看不见 Task 的取消，用这个盒子传。
final class UpscaleCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum UpscalePipeline {
    /// 整个文件直接上传的条件：范围就是整个文件、是 mp4、不超过这一档的时长 / 大小上限。否则裁一份（只有画面）。
    static func uploadsWholeFile(_ request: UpscaleRequest) -> Bool {
        let range = request.range, info = request.originalInfo
        guard range.start <= ClipUpscaleRecord.frameSlack, range.end >= info.duration - ClipUpscaleRecord.frameSlack else { return false }
        guard request.originalURL.pathExtension.lowercased() == "mp4" else { return false }
        if let maxSeconds = request.tier.maxSourceSeconds, info.duration > maxSeconds { return false }
        if let maxBytes = request.tier.maxUploadBytes, info.fileBytes > maxBytes { return false }
        return true
    }

    /// `onSubmitted`：任务交上了（从这一刻起积分扣了，没做成服务器退）；UpscaleJob 用它分清「没交上」和「交上之后断了」。
    static func run(
        _ request: UpscaleRequest, api: SkyStudioAPI, key: String, ffmpeg: URL?, workFolder: URL,
        sleep: (@Sendable (Double) async throws -> Void)? = nil,
        onSubmitted: @escaping @Sendable (String) -> Void = { _ in },
        phase report: @escaping @Sendable (FalJobPhase) -> Void
    ) async throws -> UpscaleOutcome {
        let started = Date()
        // 同一个阶段同一个比例只报一次（排着队每 15 秒问一次，界面不用每次都醒）。
        let last = FalPhaseBox()
        let phase: @Sendable (FalJobPhase) -> Void = { next in
            guard last.swap(next) else { return }
            report(next)
        }
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let stamp = UUID().uuidString
        let temporaries = [workFolder.appendingPathComponent("\(stamp)-in.mp4"), workFolder.appendingPathComponent("\(stamp)-out.mp4"),
                           workFolder.appendingPathComponent("\(stamp)-muxed.mp4")]
        defer { for url in temporaries { try? FileManager.default.removeItem(at: url) } }

        // 1. 输入：整个 mp4 直接用，否则裁出那一段（只有画面）；探出送上去的那个文件的宽、高、时长、帧率。
        phase(.preparing)
        let offset: Double
        let input: URL
        let sent: MediaInfo
        if uploadsWholeFile(request) {
            input = request.originalURL
            offset = 0
            sent = request.originalInfo
        } else {
            input = temporaries[0]
            offset = request.range.start
            try await trim(request, to: input)
            sent = try await probe(input, ffmpeg: ffmpeg)
        }
        if let maxBytes = request.tier.maxUploadBytes, sent.fileBytes > maxBytes { throw UpscalePipelineError.tooLarge(limit: maxBytes) }
        try Task.checkCancellation()

        // 2. 传上去、交任务、等它做完、下载。
        phase(.uploading(fraction: nil))
        let link = try await api.upload(fileURL: input, contentType: "video/mp4", purpose: "video", key: key) { fraction in
            phase(.uploading(fraction: FalJobPhase.quantized(fraction)))
        }
        var job = UpscaleRequest.job(
            tier: request.tier, target: request.target,
            source: UpscaleRequest.source(size: sent.displaySize, seconds: sent.duration, frameRate: sent.frameRate)
        )
        job.inputs = ["video_url": link.absoluteString]
        job.maxCredits = request.credits
        var runner = SkyStudioJobRun(api: api, key: key)
        if let sleep { runner.sleep = sleep }
        let submitted = SubmittedFlag()
        let done = try await runner.run(job) { update in
            switch update {
            case .waitingForSlot: phase(.queued(position: nil))
            case .status(let status):
                if submitted.set() { onSubmitted(status.jobID) }
                switch status.state {
                case .queued?: phase(.queued(position: status.queuePosition))
                case .running?: phase(.processing)
                default: break   // 做完了：下一步就是下载
                }
            }
        }
        guard let result = done.result else { throw SkyStudioJobError.badAnswer("a finished job without a result") }
        phase(.downloading(fraction: nil))
        try await api.download(result.url, to: temporaries[1]) { fraction in
            phase(.downloading(fraction: FalJobPhase.quantized(fraction)))
        }
        try Task.checkCancellation()

        // 3. 探测；原片有声音就把那一段封回去（Sky Studio 存的是 SkyCut 传上去的那段，没有声音）；再探一遍。
        phase(.finishing)
        var file = temporaries[1]
        var info = try await probe(file, ffmpeg: ffmpeg)
        var audioRestored = !request.originalInfo.hasAudio
        if request.originalInfo.hasAudio, let ffmpeg {
            try await UpscaleAudioMux.mux(
                ffmpeg: ffmpeg, upscaled: file, original: request.originalURL, start: offset, duration: info.duration,
                videoCodec: info.videoCodec, output: temporaries[2]
            )
            file = temporaries[2]
            info = try await probe(file, ffmpeg: ffmpeg)
            audioRestored = true
        }
        try Task.checkCancellation()

        // 4. 起名落盘（原片旁边；撞名加编号）。
        let destination = UpscaleOutputName.destination(
            original: request.originalURL, outputSize: info.displaySize, tier: request.tier.id, fallbacks: request.fallbackFolders
        )
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw UpscalePipelineError.save(error.localizedDescription)
        }
        let charged = done.creditsCharged ?? request.credits
        let record = ClipUpscaleRecord(
            originalURL: request.originalURL, sourceOffset: offset, tier: request.tier.id, originalInfo: request.originalInfo, madeAt: Date(),
            credits: charged
        )
        return UpscaleOutcome(
            file: destination, info: info, record: record, jobID: done.jobID, creditsCharged: charged, audioRestored: audioRestored,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// 裁出 `[start, end)`（阻塞的读和编跑在 MediaReadQueue.export 上；Task 取消时那边也停）。
    private static func trim(_ request: UpscaleRequest, to output: URL) async throws {
        let source: UpscaleSourceTrimmer.Source
        switch await UpscaleSourceTrimmer.load(request.originalURL) {
        case .success(let loaded): source = loaded
        case .failure(let failure): throw UpscalePipelineError.trim("\(failure)")
        }
        let flag = UpscaleCancelFlag()
        let start = request.range.start, end = request.range.end
        let result = await withTaskCancellationHandler {
            await MediaReadQueue.run(on: MediaReadQueue.export) {
                UpscaleSourceTrimmer.trim(source, start: start, end: end, to: output, isCancelled: { flag.isCancelled })
            }
        } onCancel: {
            flag.cancel()
        }
        switch result {
        case .success: return
        case .failure(.cancelled): throw CancellationError()
        case .failure(let failure): throw UpscalePipelineError.trim("\(failure)")
        }
    }

    private static func probe(_ url: URL, ffmpeg: URL?) async throws -> MediaInfo {
        switch await MediaProbe.probe(url: url, ffmpeg: ffmpeg) {
        case .success(let info): return info
        case .failure(let error): throw UpscalePipelineError.probe(error.localizedDescription)
        }
    }
}

/// 第一次报上来的状态 = 交上了（回调在别的线程上）。
private final class SubmittedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// 第一次调回 true。
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
