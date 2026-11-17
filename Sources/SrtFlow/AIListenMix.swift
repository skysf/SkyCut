import Foundation
import Synchronization
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - listen mix=true：按层量混在一起之后的声音（任务、排队、当场等一会儿）
//
// 管什么：参数交给 AIListenMixPlan，量交给 MixMeasurement（用 SkyCut 自己的音频引擎离线按层渲，和成片同一份配置、同一段渲染代码），
// 结果交给 AIListenMixReport。它是 AI 起的长任务：`AIJobs.start` / `finish`（docs/architecture/ai-control-mcp.md 第四节第 59 条，
// 跑着时不让 App Nap 降速），排在 AIWorkQueue 的 mix 道上（一次一个，像导出、转写），在 MediaReadQueue.export 上渲
// （和导出的混音同一条宽度 1 的队列：两个离线渲不同时跑）。当场最多等 `inlineSeconds`：量完了当场回结果（60 秒、3 分钟的工程
// 按层量一遍约 1–2 秒），没量完回任务号，AI 用 get_job 拿同一份结果。
// 只读：不改工程、不进撤销。量的是调用这一刻的时间线（之后的改动不算）。离线引擎不碰声卡：预览的图空闲停着就一直停着、
// 正在播的预览照常出声（docs/architecture/audio-engine.md 第二节第 11 条）。
// `queued` is the job part on its own: listen voice=… (AIListenVoiceCheck) measures the voice the same way (2026-11-17).
// 不管什么：量法（MixMeasurement）、参数（AIListenMixPlan）、结果的样子（AIListenMixReport）。

@MainActor
enum AIListenMix {
    /// 当场最多等多久（秒）：客户端对一次调用大多只等一分钟；等不到就回任务号。
    static let inlineSeconds = 20.0

    static func listen(
        _ args: AIToolArguments, _ project: VideoEditProject, from: Double?, to: Double?, silenceDB: Double, minSilence: Double
    ) async throws -> AIToolResult {
        guard try args.string("file") == nil else {
            throw AIToolError("mix=true measures the timeline's mix: leave file out (listen with file measures a file on its own).")
        }
        guard try !(args.bool("beats") ?? false), try !(args.bool("cuts") ?? false) else {
            throw AIToolError("mix=true is its own measurement: call listen again for beats or cuts.")
        }
        let state = project.state
        // 只为了知道哪几条轨在混音里（不跑场景的响度量法）；真正量的那一份在任务里按成片的做法算。
        let layout = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        guard layout.hasSound else { throw AIToolError("Nothing on the timeline has sound.") }
        let plan = try AIListenMixPlan.make(
            args, state: state, config: layout, from: from, to: to, silenceDB: silenceDB, minSilence: minSilence
        )
        return try await queued(state, failure: "Could not measure the mix") { config, token, progress in
            let request = MixMeasurement.Request(config: config, layers: plan.layers, grid: plan.grid, frames: plan.frames)
            let result = try MixMeasurement.measure(request, isCancelled: { token.isCancelled }) { block in
                progress.update(block, of: request)
            }
            return .object(AIListenMixReport.json(result, plan: plan))
        }
    }

    /// One offline measurement of the timeline as a listen job: AIJobs (App Nap stays off while it runs), the mix lane (one
    /// at a time), `measure` on MediaReadQueue.export with the export's configuration of `state`; waits `inlineSeconds`.
    static func queued(
        _ state: TimelineState, failure: String,
        measure: @escaping @Sendable (AudioEngineConfig, ExportCancellationToken, AIListenMixProgress) throws -> JSONValue
    ) async throws -> AIToolResult {
        let token = ExportCancellationToken()
        let progress = AIListenMixProgress()
        let work = AIQueuedWork()
        let job = AIJobs.shared.start(.listen, progress: { work.started ? progress.fraction : nil }, cancel: {
            work.cancel(stop: { token.cancel() })
        })
        work.job = job
        AIWorkQueue.shared.submit(.mix, jobID: job.id) {
            work.started = true
            run(state, job: job, token: token, progress: progress, failure: failure, measure: measure)
        }
        await AIJobs.shared.wait(for: job, seconds: inlineSeconds)
        switch job.status {
        case .done:
            return .ok(job.detail ?? .object([:]))
        case .failed:
            throw AIToolError(job.message ?? "\(failure).")
        case .cancelled:
            throw AIToolError("Cancelled before the measurement finished.")
        case .running:
            var result: [String: JSONValue] = [
                "job_id": .string(job.id), "status": "running",
                "next_step": "Still measuring (long timeline or a busy queue). Wait with get_job; the result is the same as listen would return."
            ]
            if let position = AIWorkQueue.shared.position(of: job.id) {
                result["status"] = "queued"
                result["queue_position"] = .number(Double(position))
            }
            return .ok(.object(result))
        }
    }

    /// 在 MediaReadQueue.export 上渲、量、写结果，记下结局。
    private static func run(
        _ state: TimelineState, job: AIJobs.Job, token: ExportCancellationToken, progress: AIListenMixProgress, failure: String,
        measure: @escaping @Sendable (AudioEngineConfig, ExportCancellationToken, AIListenMixProgress) throws -> JSONValue
    ) {
        Task {
            let outcome = await MediaReadQueue.run(on: MediaReadQueue.export) { () -> Result<JSONValue, Error> in
                // 和成片同一份配置（段落、增益、场景的响度补偿、变速）：AudioEngineConfig.make 自己排序、展开转场。
                Result { try measure(AudioEngineConfig.make(from: state), token, progress) }
            }
            switch outcome {
            case .success(let detail):
                AIJobs.shared.finish(job, .done, detail: detail)
            case .failure(let error):
                if token.isCancelled || error is CancellationError {
                    AIJobs.shared.finish(job, .cancelled, message: "Cancelled; nothing was changed.")
                } else {
                    AIJobs.shared.finish(job, .failed, message: "\(failure): \(error.localizedDescription)")
                }
            }
        }
    }
}

/// 量到哪了（给 get_job 的 progress）：渲染线程写、主线程读。
final class AIListenMixProgress: Sendable {
    /// 千分比；还没开始渲是 −1。
    private let permille = Atomic<Int>(-1)

    var fraction: Double? {
        let value = permille.load(ordering: .relaxed)
        return value < 0 ? nil : Double(value) / 1000
    }

    /// The fraction done (0…1), for a measurement that counts it itself (listen voice=…).
    func update(fraction: Double) { permille.store(Int(min(1, max(0, fraction)) * 1000), ordering: .relaxed) }

    /// 渲完一块：按渲到的位置算（前面多渲的那几秒也算在里面）。
    func update(_ block: AudioStemRender.Block, of request: MixMeasurement.Request) {
        let grid = request.grid
        let first = Double(grid.start(ofFrame: request.frames.lowerBound))
        let last = Double(grid.start(ofFrame: request.frames.upperBound))
        let done = Double(block.position + Int64(block.frames))
        let fraction = min(1, max(0, (done - first) / max(1, last - first)))
        permille.store(Int(fraction * 1000), ordering: .relaxed)
    }
}
