import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 在清理会话前快照归属，在回到空闲后统一送出回执；不驱动捕获，不改入轨事务。
@MainActor
struct ScreenRecordingCompletion {
    let session: ScreenRecordingSession
    let observer: ScreenRecordingObserver?
    let project: VideoEditProject
    let manifest: ScreenRecordingManifest?

    init(_ coordinator: ScreenRecordingCoordinator) {
        session = coordinator.session
        observer = coordinator.session.observer
        project = coordinator.targetProject ?? OpenProjects.shared.primary
        manifest = coordinator.manifest
    }

    func deliver(_ outcome: ScreenRecordingOutcome, retainedFiles: [ScreenRecordingReceipt.File]? = nil) {
        guard ScreenRecordingFeedback.shared.acceptsCompletion(session.receiptID) else { return }
        let ai = observer as? AIScreenRecordingJob
        if let ai, ai.job.status != .running { return }
        ai?.prepareCompletion(outcome)
        let job: AIJobs.Job = ai?.job ?? AIJobs.shared.start(.screenRecording, progress: { nil }, cancel: {})
        let ids = AIShortIDs(state: project.state)
        var receipt = ScreenRecordingReceipt(
            id: session.receiptID, jobID: job.id, ownerSession: ai?.job.session,
            status: .done, stop: session.stopCause ?? .setupError,
            projectID: project.shortID, projectName: project.projectName, projectGeneration: project.documentGeneration,
            background: OpenProjects.shared.isHeadless(project), began: session.didBeginCapture
        )
        let result: ScreenRecordingResult?
        switch outcome {
        case .added(let recording, let clipIDs):
            result = recording
            receipt.clips = clipIDs.compactMap { id in
                guard let slot = project.state.location(of: id)?.track else { return nil }
                return .init(id: ids.short(id), track: AITrackName.name(of: slot))
            }
            receipt.reason = project.notice ?? recording.partialReason
        case .savedOnly(let recording): result = recording
        case .awaitingDecision(let recording):
            result = recording
            receipt.waitingForDecision = true
        case .nothingRecorded:
            result = nil
            receipt.status = .cancelled
            if session.stopCause == nil { receipt.stop = .sourceCancelled }
        case .failed(let reason):
            result = nil
            receipt.status = .failed
            receipt.reason = reason
            receipt.files = retainedFiles ?? []
        }
        if let result {
            receipt.files = [.init(url: result.mainURL)]
            if let mic = result.microphoneURL { receipt.files.append(.init(url: mic, kind: "microphone")) }
            if let retainedFiles { receipt.files = retainedFiles }
            receipt.duration = result.duration
            receipt.width = Int(result.pixelSize.width)
            receipt.height = Int(result.pixelSize.height)
            receipt.reason = receipt.reason ?? result.partialReason
            receipt.incomplete = result.isPartial || receipt.reason != nil
        }
        ScreenRecordingFeedback.shared.publish(receipt)
        if let observer { observer.recordingEnded(outcome, receipt: receipt) }
        else { AIJobs.shared.finish(job, receipt.status.jobStatus, message: receipt.message, detail: receipt.json) }
    }

    /// 失败也核对留在磁盘上的精确路径；writing 的最终路径可能是原文件，不能拿来冒充本次录制。
    func retainedFiles() async -> [ScreenRecordingReceipt.File] {
        guard let manifest else { return [] }
        return await ScreenRecordingRetainedFiles.inspect(manifest)
    }
}

extension ScreenRecordingReceipt.Status {
    var jobStatus: AIJobs.Status {
        switch self {
        case .done: return .done
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}
