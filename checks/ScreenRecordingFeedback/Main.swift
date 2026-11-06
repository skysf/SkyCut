import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 独立测试 App 只执行对象与媒体回读，不运行 SrtFlowApp.main，不显示窗口、不开捕获、不碰安装包。
@main enum RecordingFeedbackChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.recordingfeedbackcheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Use the isolated recording feedback check bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        _ = NSApplication.shared
        let checks = FeedbackAssertions()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_RECORDING_FEEDBACK_CHECK_DIR"]!)
        do {
            let projects = OpenProjects.shared
            guard let target = projects.newProject(savingAs: root.appendingPathComponent("Background.skycut"), placement: .background) else {
                fatalError("Could not create the isolated background project")
            }
            checks.require(projects.isHeadless(target) && projects.window(of: target) == nil, "target has no window")
            let clip = EditClip(sourceURL: root.appendingPathComponent("recorded.mov"), sourceDuration: 42.5, timelineStart: 0)
            target.perform { $0.mainClips.append(clip) }
            let context = AICallContext(session: "recording-owner", client: "Test", project: target.shortID, stopsWith: target.shortID)
            let job = AICallContext.$current.withValue(context) {
                AIScreenRecordingJob(project: target, sourceDescription: "synthetic display")
            }
            AIScreenRecordingTool.adopt(job)
            var session = ScreenRecordingSession()
            session.driver = .ai
            session.observer = job
            session.didBeginCapture = true
            session.stopCause = .controlPanel
            let coordinator = ScreenRecordingCoordinator.shared
            checks.require(coordinator.beginAutomated(session, for: target), "automated setup begins on its own project")
            coordinator.cancelConfiguring()
            checks.require(coordinator.state == .configuring, "an unpresented manual setup sheet cannot cancel an AI recording")
            job.enteredCoordinator()
            let result = ScreenRecordingResult(
                mainURL: clip.sourceURL, duration: 42.5, pixelSize: CGSize(width: 320, height: 180), frameRate: .fallback
            )
            let completion = ScreenRecordingCompletion(coordinator)
            completion.deliver(.added(result, clipIDs: [clip.id]))
            coordinator.invalidateSession() // 清理夹具；迟到的 nothingRecorded 不得改写 done 或重新发布 notice。
            checks.require(job.job.status == .done, "the original recording job remains done after cleanup")
            let receipt = ScreenRecordingFeedback.shared.latest!
            checks.require(receipt.jobID == job.job.id && receipt.duration == 42.5, "the canonical receipt keeps the completed job and duration")
            checks.require(receipt.clips == [.init(id: AIShortIDs(state: target.state).short(clip.id), track: "V1")], "receipt uses real clip and track identities")
            checks.require(receipt.background && receipt.projectID == target.shortID, "receipt names the background target, not the visible primary")
            checks.require(ScreenRecordingFeedback.shared.notices.contains(receipt), "normal success produces a global visible notice")
            checks.require(projects.isHeadless(target) && NSApp.windows.isEmpty, "completion feedback never opens a project or modal window")
            try await checks.checkLateStop(context: context, target: target, original: job, receipt: receipt)
            try await checks.checkOwnerNote(receipt: receipt)
            try await checks.checkFailureFiles(root: root)
            checks.checkPresentation(receipt: receipt)
            await checks.checkPartialAndSources(target: target, result: result)
            ProjectTeardown.stopPreview(target)
            target.autosaveTask?.cancel()
        } catch {
            checks.require(false, "recording feedback production checks: \(error)")
        }
        ProjectTeardown.stopPreview(OpenProjects.shared.primary)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        checks.finish()
    }
}

@MainActor final class FeedbackAssertions {
    var failures = 0
    var count = 0
    func require(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
    func finish() -> Never {
        if failures > 0 { print("FAIL: \(failures) of \(count) recording feedback checks"); exit(1) }
        print("PASS: \(count) production recording feedback checks; no capture or user windows")
        exit(0)
    }
}
