import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 真实工具入口、回执派发与 UI 文案；不复制业务判断，不启动用户的 App。
extension FeedbackAssertions {
    func checkLateStop(context: AICallContext, target: VideoEditProject, original: AIScreenRecordingJob, receipt: ScreenRecordingReceipt) async throws {
        // 重录尝试替换了 current，但尚未开录：晚到 Stop 仍要回那段真正录好的视频。
        let pending = AICallContext.$current.withValue(context) {
            AIScreenRecordingJob(project: target, sourceDescription: "not started")
        }
        AIScreenRecordingTool.adopt(pending)
        let reply = try await AICallContext.$current.withValue(context) {
            try await AIScreenRecordingTool.run(AIToolArguments(["action": "stop"]), target)
        }
        require(reply.payload["status"] == "done" && reply.payload["job_id"] == .string(original.job.id), "late Stop returns the real completed job instead of a cancelled retry")
        require(reply.payload["file"] == .string(receipt.video!.url.path) && reply.payload["clip_ids"] == receipt.json["clip_ids"], "late Stop retains the full file path and clip ids")
        require(reply.payload["stopped_by"] == "user" && reply.payload["stop_method"] == "control_panel", "late AI Stop does not overwrite who actually stopped it")
        require(!(reply.payload["message"]?.stringValue ?? "").contains("nothing was recorded"), "late Stop never says the completed recording was empty")
        require(reply.payload["message"]?.stringValue?.hasPrefix("No screen recording is running.") == true,
                "late Stop explicitly says there is no active recording")
        let job = try await AIExportTools.job(AIToolArguments(["job_id": .string(original.job.id)]))
        require(job.payload["status"] == "done" && job.payload["file"] == reply.payload["file"], "get_job agrees with late Stop")
        require(job.payload["stopped_by"] == "user" && job.payload["stop_method"] == "control_panel", "get_job reports stop provenance")
        let status = AIScreenSources.statusJSON(listSources: false)
        require(status["last_recording"]?["job_id"] == .string(original.job.id), "get_status retains the actual recording after an unused retry")
        require(status["last_recording"]?["file"] == .string(receipt.video!.url.path), "get_status reports the retained path")
    }

    func checkOwnerNote(receipt: ScreenRecordingReceipt) async throws {
        // 走真实路由的错误回答：附言不能只加在 get_job 或成功回答上，不能被另一会话消费。
        let other = MCPBridge.Request(tool: "get_status", arguments: ["unexpected": true], client: "Test", session: "other-owner")
        let otherAnswer = await AIToolRouter.shared.handle(other, begin: { true })
        require(!otherAnswer.result.encodedString().contains("The user stopped the screen recording"), "another session cannot consume or receive the owner's note")
        let request = MCPBridge.Request(tool: "get_status", arguments: ["unexpected": true], client: "Test", session: "recording-owner")
        let answer = await AIToolRouter.shared.handle(request, begin: { true })
        let text = answer.result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        require(text.contains("The user stopped the screen recording") && text.contains(receipt.jobID), "the owner's next arbitrary tool result includes the recording stop note")
        require(text.contains(receipt.video!.url.path) && text.contains(receipt.projectID) && text.contains(receipt.clips[0].id), "note names file, target project and clip")
        require(answer.result["isError"] == true && (answer.result["content"]?.arrayValue?.count ?? 0) == 2, "the note preserves the original error result")
        let again = await AIToolRouter.shared.handle(request, begin: { true })
        require(!again.result.encodedString().contains("The user stopped the screen recording"), "a delivered note is consumed exactly once")
    }

    func checkFailureFiles(root: URL) async throws {
        let manager = FileManager.default
        let final = root.appendingPathComponent("existing-user-video.mov")
        try manager.copyItem(at: root.appendingPathComponent("recorded.mov"), to: final)
        let temporary = root.appendingPathComponent("recording.partial.mov")
        var manifest = ScreenRecordingManifest(sessionID: UUID(), startedAt: Date(), mainTemporaryPath: temporary.path, mainFinalPath: final.path)
        require(await ScreenRecordingRetainedFiles.inspect(manifest).isEmpty, "writing failure cannot claim an unrelated pre-existing final video")
        try manager.copyItem(at: final, to: temporary)
        let partial = await ScreenRecordingRetainedFiles.inspect(manifest)
        require(partial.count == 1 && partial[0].url == temporary && partial[0].usable && partial[0].temporary, "failed commit reports a usable retained temporary file after real probing")
        manifest.stage = .allCommitted
        let committed = await ScreenRecordingRetainedFiles.inspect(manifest)
        require(committed.count == 1 && committed[0].url == final && committed[0].usable, "post-commit import failure reports the actual committed file")
        try Data("broken video".utf8).write(to: final)
        let broken = await ScreenRecordingRetainedFiles.inspect(manifest)
        require(broken.count == 1 && !broken[0].usable, "an unreadable leftover must never be reported as usable")
        let missingVolume = root.appendingPathComponent("unmounted/recording.mov")
        let offline = ScreenRecordingManifest(sessionID: UUID(), startedAt: Date(), stage: .allCommitted,
            mainTemporaryPath: missingVolume.path + ".partial", mainFinalPath: missingVolume.path)
        let unavailable = await ScreenRecordingRetainedFiles.inspect(offline)
        require(unavailable.count == 1 && unavailable[0].unavailable && unavailable[0].url == missingVolume,
                "an unavailable volume stays inconclusive and retains the correct committed path")
    }

    func checkPresentation(receipt: ScreenRecordingReceipt) {
        AppLanguageStore.shared.language = .english
        let english = ScreenRecordingNoticeText.message(receipt)
        require(english.contains(receipt.video!.url.path) && english.contains("track V1") && english.contains("background and has no window"), "English success notice includes full path, track and background status")
        require(ScreenRecordingNoticeText.title(receipt) == "Recording saved", "English success title")
        AppLanguageStore.shared.language = .simplifiedChinese
        let chinese = ScreenRecordingNoticeText.message(receipt)
        require(chinese.contains("已保存到：") && chinese.contains("V1 轨道") && chinese.contains("此工程在后台运行，尚未打开窗口。"), "Chinese notice is localized with the same target facts")
        require(chinese.contains(receipt.video!.url.path), "paths are never translated")
        AppLanguageStore.shared.language = .spanish
        require(ScreenRecordingNoticeText.title(receipt) == "Grabación guardada", "Spanish completion title is present")
        AppLanguageStore.shared.language = .english
        var failed = receipt
        failed.status = .failed
        failed.reason = "The recording has no usable video."
        failed.files = []
        failed.clips = []
        require(ScreenRecordingNoticeText.message(failed).contains("No usable recording file was kept.") && ScreenRecordingNoticeText.message(failed).contains(failed.reason!), "failed notice reports reason and absence of usable media")
        print("ENGLISH NOTICE: \(ScreenRecordingNoticeText.title(receipt))\n\(english)")
        print("CHINESE NOTICE: 录屏已保存\n\(chinese)")
    }

    func checkPartialAndSources(target: VideoEditProject, result: ScreenRecordingResult) async {
        let coordinator = ScreenRecordingCoordinator.shared
        var session = ScreenRecordingSession()
        session.didBeginCapture = true
        session.stopCause = .streamError
        require(coordinator.beginAutomated(session, for: target), "partial fixture begins")
        var partial = result
        partial.isPartial = true
        partial.partialReason = "The stream was interrupted."
        let completion = ScreenRecordingCompletion(coordinator)
        completion.deliver(.awaitingDecision(partial))
        require(ScreenRecordingFeedback.shared.notices.last?.waitingForDecision == true, "partial media creates a nonmodal global decision notice")
        let before = ScreenRecordingFeedback.shared.notices.count
        completion.deliver(.savedOnly(partial))
        require(ScreenRecordingFeedback.shared.notices.count == before && ScreenRecordingFeedback.shared.notices.last?.waitingForDecision == false, "settling a partial updates its existing notice")
        coordinator.invalidateSession()
        // 实际停止入口的失败路径：缺少 writer 的起步会话必须收尾并全局报失败，不能只写后台工程 notice。
        var failing = ScreenRecordingSession()
        failing.driver = .ai
        require(coordinator.beginAutomated(failing, for: target), "failing fixture begins on the background target")
        for state in [ScreenRecordingState.choosingSource, .choosingDestination, .preparing, .countingDown(remaining: 0), .starting] {
            require(coordinator.transition(to: state), "failure fixture reaches \(state)")
        }
        await coordinator.stop(cause: .mcp)
        require(coordinator.state == .idle && ScreenRecordingFeedback.shared.notices.last?.status == .failed,
                "actual stop failure returns to idle and publishes a global failure notice")
        require(ScreenRecordingFeedback.shared.notices.last?.files.isEmpty == true,
                "actual stop failure explicitly records no usable leftover")
        require(ScreenRecordingFeedback.shared.notices.last?.stop == .mcp,
                "failure retains the real initiating stop method")
        for stop in [ScreenRecordingReceipt.Stop.mcp, .duration, .quit, .lowDisk, .writerError, .streamError, .activity, .cancelJob] {
            var receipt = ScreenRecordingFeedback.shared.latest!
            receipt.stop = stop
            require(receipt.json["stop_method"] == .string(stop.rawValue) && receipt.json["stopped_by"] == .string(stop.by), "stop source \(stop.rawValue) is available to MCP")
        }
        require(NSApp.windows.isEmpty, "failure and partial feedback do not create modal or project windows")
    }
}
