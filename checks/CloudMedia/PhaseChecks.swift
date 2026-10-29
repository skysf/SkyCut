import Foundation
import SrtFlowMCPKit

// 云端任务的阶段与进度账（CloudJobPhase / CloudJobProgress / CloudPhaseBox，docs/architecture/sky-studio-jobs.md）：
// 阶段的名字 / 比例 / 排队位置 / 先后；同一阶段换比例不重记开始时刻、换阶段才重记；get_job 的几个字段；「1:12」「约 2 分钟」；
// 每个档位的典型时长折成的分钟数和面板上一直写的一样；同一阶段同一比例只报一次。

func runPhaseChecks() {
    // ---- 阶段
    checkEqual(CloudJobPhase.uploading(fraction: 0.5).name, "uploading", "the phase name")
    checkEqual(CloudJobPhase.queued(position: 3).name, "queued", "the queued phase name")
    checkEqual(CloudJobPhase.uploading(fraction: 0.5).fraction, 0.5, "an upload carries its byte fraction")
    checkEqual(CloudJobPhase.downloading(fraction: 0.25).fraction, 0.25, "a download carries its byte fraction")
    check(CloudJobPhase.processing.fraction == nil && CloudJobPhase.queued(position: 1).fraction == nil, "other phases have no fraction")
    checkEqual(CloudJobPhase.queued(position: 3).queuePosition, 3, "the queue position")
    check(CloudJobPhase.processing.queuePosition == nil, "only queued has a position")
    check(CloudJobPhase.uploading(fraction: nil).sameStep(as: .uploading(fraction: 1)), "a different fraction is the same step")
    check(CloudJobPhase.queued(position: 1).sameStep(as: .queued(position: 5)), "a different queue position is the same step")
    check(!CloudJobPhase.uploading(fraction: 1).sameStep(as: .queued(position: nil)), "upload and queue are different steps")
    let inOrder: [CloudJobPhase] = [.preparing, .uploading(fraction: nil), .queued(position: nil), .processing, .downloading(fraction: nil), .finishing]
    check(zip(inOrder, inOrder.dropFirst()).allSatisfy { $0.order < $1.order }, "the phases are ordered prepare < upload < queue < process < download < finish")
    checkEqual(CloudJobPhase.quantized(0.456), 0.45, "fractions are quantized to 1% steps, rounding down")
    checkEqual(CloudJobPhase.quantized(1.2), 1, "a fraction over 1 is clamped")
    checkEqual(CloudJobPhase.quantized(-0.1), 0, "a negative fraction is clamped")

    // ---- 进度账
    let t0 = Date(timeIntervalSince1970: 1_000)
    var progress = CloudJobProgress(phase: .uploading(fraction: nil), phaseStarted: t0, typicalSeconds: 140)
    progress = progress.advanced(to: .uploading(fraction: 0.5), now: t0.addingTimeInterval(10))
    checkEqual(progress.phaseStarted, t0, "a new fraction keeps the phase's start time")
    checkEqual(progress.phase, .uploading(fraction: 0.5), "but carries the new fraction")
    progress = progress.advanced(to: .queued(position: 2), now: t0.addingTimeInterval(30))
    checkEqual(progress.phaseStarted, t0.addingTimeInterval(30), "a new step restarts the phase clock")
    checkEqual(progress.phaseSeconds(now: t0.addingTimeInterval(42)), 12, "phase seconds count from the step's start")
    let queued = progress.json(now: t0.addingTimeInterval(42))
    checkEqual(queued["phase"], "queued", "get_job: phase")
    checkEqual(queued["phase_seconds"], 12, "get_job: phase_seconds")
    checkEqual(queued["queue_position"], 2, "get_job: queue_position")
    checkEqual(queued["typical_seconds"], 140, "get_job: typical_seconds")
    check(queued["transfer_percent"] == nil, "get_job: no transfer_percent while queued")
    let uploading = CloudJobProgress(phase: .uploading(fraction: 0.456), phaseStarted: t0).json(now: t0)
    checkEqual(uploading["transfer_percent"], 46, "get_job: transfer_percent is a rounded percentage")
    check(uploading["queue_position"] == nil && uploading["typical_seconds"] == nil, "get_job: nothing that is not known")
    let processing = CloudJobProgress(phase: .processing, phaseStarted: t0, typicalSeconds: 70).json(now: t0.addingTimeInterval(48.6))
    checkEqual(processing["phase_seconds"], 49, "get_job: phase_seconds is rounded")
    check(processing["queue_position"] == nil && processing["transfer_percent"] == nil, "get_job: processing has neither position nor percent")
    checkEqual(CloudJobProgress.clock(72), "1:12", "1:12")
    checkEqual(CloudJobProgress.clock(0), "0:00", "0:00")
    checkEqual(CloudJobProgress.clock(3599.9), "59:59", "whole seconds, rounding down")
    checkEqual(CloudJobProgress.minutes(20), 1, "under a minute still says about 1 min")
    checkEqual(CloudJobProgress.minutes(150), 3, "2.5 minutes rounds up")
    checkEqual(CloudJobProgress.minutes(140), 2, "2.33 minutes rounds down")

    // ---- 同一阶段同一比例只报一次
    let box = CloudPhaseBox()
    check(box.swap(.processing), "the first report goes through")
    check(!box.swap(.processing), "the same phase again is dropped")
    check(box.swap(.downloading(fraction: nil)), "a new phase goes through")
    check(!box.swap(.downloading(fraction: nil)), "the same phase and fraction is dropped")
    check(box.swap(.downloading(fraction: 0.5)), "a new fraction goes through")
}
