import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 真正的 App 对象回归：只注入网络 / 转写，执行真实落盘、恢复入口、音频解码、切句、字幕、入轨和 UndoManager。
// 回任务号之前的那几步（整段报价、预留、退本机、认声音）在 StartChecks.swift。
@main enum VoiceRecoveryChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.voicerecoverycheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Voice recovery checks require the isolated test bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_VOICE_RECOVERY_CHECK_DIR"]!)
        do {
            try await recoveryChecks(root)
            try await runVoiceStartChecks(root)
            try await runVoiceRecoveryTimingChecks(root)
            try await runVoiceConcurrencyChecks(root)
            try await runVoiceLibraryChecks(root)
            try await runVoiceLibraryUIChecks(root)
            try await runVoiceFallbackFeeChecks(root)
            await runVoicePaidAudioChecks(root)
        } catch {
            VoiceCheckLog.failures += 1
            print("FAIL: production voice recovery checks: \(error)")
        }
        ProjectTeardown.stopPreview(OpenProjects.shared.primary)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        if VoiceCheckLog.failures > 0 { print("FAIL: \(VoiceCheckLog.failures) production voice recovery checks"); exit(1) }
        print("PASS: production voice: whole-segment quote before job_id, one selection per segment, budget / refusal / local fallback before paying, "
            + "batches read together within the audio slots and landed in order, mid-script fallback for later batches, fallback_needs_one_time "
            + "then missing-only recovery, second-batch split failure, local-only retry, missing-only generation with the saved selection, "
            + "estimated long line, stable files, durable receipt, six clips/cues, one undo/redo, unknown-submit refusal, packed narration, "
            + "eleven-v4 / estimated subtitle timing, model install before paying and re-quote when it fails, script words in subtitles, mixed timing"
            + "; voice library: list with an outage, consent before upload, delete by permission mode with a storage retry, design fee, library narration asking / skipping / building the MiniMax version, a mid-script fallback fee asked in get_job and answered with resume (skip or build)"
            + "; paid audio never stuck: a Traditional Chinese batch transcribed in Simplified, long-line halves at 24 kHz and 44.1 kHz, "
            + "a packed batch without usable word times on a Mac that cannot transcribe; voice.note in get_job while running and after a failure")
        exit(0)
    }

    /// 声音库的声音（合批的那一摊）：六句三批，先把几批都拿到本机、再按顺序切句（声音 PR 4）。第三批云端没做成（钱退了），前两批做好了；
    /// 恢复时第二批本机切句先失败一次，之后只补第三批。
    @MainActor static func recoveryChecks(_ root: URL) async throws {
        let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("split"))
        let spent = SkyStudioSpendStore.shared.spentToday()
        let lines = [String](repeating: "Hello world.", count: 6)
        VoiceRecoveryHTTP.cloudFailure = 2
        let first = try await fixture.wait(fixture.clone(lines))
        VoiceRecoveryHTTP.cloudFailure = nil
        require(first["status"] == "failed" && first["failure_stage"] == "cloud_generation", "a refunded cloud failure ends the job at the cloud stage")
        let file = first["recovery_file"]!.stringValue!
        let saved = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
        require(VoiceRecoveryHTTP.posts == 3, "every batch was sent once")
        require(SkyStudioSpendStore.shared.spentToday() == spent + 5, "successful cloud batches remain charged; the refunded batch releases its reservation")
        require(saved.missing == [2] && saved.batches[0].generated && saved.batches[1].generated, "successful batches must never become missing")
        require(saved.batches.prefix(2).allSatisfy { $0.rawFile.map { FileManager.default.fileExists(atPath: $0.path) } == true }, "both complete originals must survive failure")
        require(saved.batches[1].remote != nil, "mappings, cloud result and progress are durable")
        require(fixture.project.state.audioTracks.allSatisfy { $0.clips.isEmpty }, "failed processing must not insert a partial voiceover")
        let selection = saved.plan.voicePlan.selection
        require(saved.version == 2 && selection["model"] == "index-tts-2", "the recovery record (version 2) keeps the quote's selection")
        require(VoiceRecoveryHTTP.bodies("/jobs").allSatisfy { $0["params"]?["plan"]?.objectValue == selection },
                "every batch was sent with the same selection")
        require(VoiceRecoveryHTTP.bodies("/uploads").isEmpty, "a library voice uploads no reference while reading")
        let reads = fixture.keyReads
        SkyStudioSpendStore.shared.setDailyLimit(0)
        // 默认恢复仅本地：不读 Key、不报价、不生成第三批。第二批的本机切句先失败一次（真实分句算法收到空转写）。
        let split = try await fixture.resume(file)
        require(split["status"] == "failed" && split["failure_stage"] == "local_split", "local split failure must be distinct from cloud generation")
        let afterSplit = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
        require(afterSplit.outputs.count == 2 && afterSplit.missing == [2], "the first batch's lines are kept while the second batch's split failed")
        let firstFiles = afterSplit.outputs.mapValues(\.url)
        let local = try await fixture.resume(file)
        require(local["status"] == "failed" && local["failure_stage"] == nil, "available audio recovers; missing generation is reported separately")
        require(VoiceRecoveryHTTP.posts == 3 && fixture.keyReads == reads, "local retry must never invoke cloud generation or even read the key")
        require(SkyStudioSpendStore.shared.spentToday() == spent + 5, "local retry must not reserve or charge credits")
        let afterLocal = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
        require(afterLocal.outputs.count == 4 && afterLocal.missing == [2], "default recovery processes the saved second batch and leaves only the ungenerated third")
        require(firstFiles.allSatisfy { afterLocal.outputs[$0.key]?.url == $0.value }, "already completed files must not be rewritten")
        let blocked = try await fixture.resume(file, generate: true)
        require(blocked["status"] == "failed" && blocked["code"] == "daily_budget_exceeded" && VoiceRecoveryHTTP.posts == 3,
                "a hard budget blocks missing generation while retaining all recovered audio")
        SkyStudioSpendStore.shared.setDailyLimit(1_000)
        // 恢复补批次：照记录的选择再报价（params.plan）。服务器这次要是自己选，会选成别的模型（rechoose）—— 不带选择就被认出来。
        VoiceRecoveryHTTP.rechoose = true
        let beforeLocal = VoiceRecoveryHTTP.log.count
        let completed = try await fixture.resume(file, generate: true)
        require(completed["status"] == "done", "explicit missing-only generation completes the narration")
        require(VoiceRecoveryHTTP.posts == 4, "recovery generates only the previously ungenerated third batch")
        require(SkyStudioSpendStore.shared.spentToday() == spent + 7.5, "missing-only generation reserves only the final batch")
        let newPosts = Array(VoiceRecoveryHTTP.log.dropFirst(beforeLocal)).filter { $0.0 == "POST" }
        let requotes = newPosts.filter { $0.1.hasSuffix("/quote") }.map(\.2)
        require(requotes.count == 1 && requotes.first?["params"]?["plan"]?.objectValue == selection
                && requotes.first?["params"]?["batches"] == .array([.string(saved.plan.batches[2].speech.prompt)]),
                "recovery quotes only the missing batch, with the saved selection (it never chooses a model again)")
        require(newPosts.filter { $0.1.hasSuffix("/jobs") }.allSatisfy { $0.2["params"]?["plan"]?.objectValue == selection },
                "the missing batch is sent with the same selection as the rest")
        VoiceRecoveryHTTP.rechoose = false
        let state = fixture.project.state
        let clips = state.audioTracks.flatMap(\.clips)
        require(clips.count == 6 && Set(clips.map(\.sourceURL)).count == 6, "final content must have exactly six distinct audio files")
        let cues = state.subtitleCues(of: .original)
        require(cues.count == 6 && Set(cues.map(\.id)).count == 6, "final content must have exactly six subtitles")
        let repeated = try await fixture.resume(file, generate: true)
        require(repeated["status"] == "done" && fixture.project.state == state && VoiceRecoveryHTTP.posts == 4, "repeated recovery must not duplicate audio/subtitles or pay again")
        // 模拟工程已落账、最终回执写盘前退出：预先写下的稳定片段身份必须仍能识别那次插入。
        var prepared = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
        prepared.applied = nil
        try SkyStudioVoiceRecoveryStore.write(prepared, to: URL(fileURLWithPath: file))
        let receiptRecovered = try await fixture.resume(file)
        require(receiptRecovered["status"] == "done" && fixture.project.state == state && VoiceRecoveryHTTP.posts == 4,
                "prepared insertion receipt must survive a missing final receipt without duplicating clips or subtitles")
        fixture.project.effectiveUndoManager!.undo()
        require(fixture.project.state.audioTracks.flatMap(\.clips).isEmpty && fixture.project.state.subtitleCues(of: .original).isEmpty, "one undo removes the complete recovered voiceover and subtitles")
        _ = try await fixture.resume(file)
        require(fixture.project.state.audioTracks.flatMap(\.clips).isEmpty, "retry after user undo must respect the saved insertion receipt")
        fixture.project.effectiveUndoManager!.redo()
        require(fixture.project.state == state, "one redo restores the complete recovered narration")

        // 云端明确失败 / 全退：后面还没交的不再交，只补这一批与后面未提交的批次；成功批次仍不重复。
        let cloud = try VoiceRecoveryFixture(folder: root.appendingPathComponent("cloud"))
        cloud.failSplitOnce = false
        VoiceRecoveryHTTP.cloudFailure = 1
        let failedCloud = try await cloud.wait(cloud.clone(lines))
        require(failedCloud["failure_stage"] == "cloud_generation", "provider failure has its own stage")
        let cloudFile = failedCloud["recovery_file"]!.stringValue!
        let cloudProgress = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: cloudFile))
        require(VoiceRecoveryHTTP.posts == 2, "after the second batch failed, the third was never sent")
        require(cloudProgress.missing == [1, 2] && cloudProgress.batches[0].generated, "only the refunded failed batch and unstarted tail are missing")
        VoiceRecoveryHTTP.cloudFailure = nil
        let cloudDone = try await cloud.resume(cloudFile, generate: true)
        require(cloudDone["status"] == "done" && VoiceRecoveryHTTP.posts == 4, "partial cloud success only generates the failed and unstarted batches")
        require(cloud.project.state.audioTracks.flatMap(\.clips).count == 6 && cloud.project.state.subtitleCues(of: .original).count == 6, "partial cloud recovery has no duplicate content")

        // 普通旁白的长句跨批（在句末分开）：第二批的转写一个词都没有 —— 声音是好的，这一句按字数估、不让整段失败（声音 PR 5），
        // 两批各付一次、拼回一句不丢不重。
        let subtitle = try VoiceRecoveryFixture(folder: root.appendingPathComponent("subtitle"))
        subtitle.failSplitOnce = true
        let long = ["Hello world. Hello world. Hello world."]
        let estimatedLine = try await subtitle.wait(subtitle.started(subtitle.narrate(long)))
        require(estimatedLine["status"] == "done" && estimatedLine["subtitle_timing"] == "estimated",
                "a long line whose second batch could not be transcribed is estimated, not failed (got \(estimatedLine["status"] ?? .null))")
        require(VoiceRecoveryHTTP.bodies("/jobs").map { $0["prompt"]?.stringValue ?? "" } == ["Hello world. Hello world.", "Hello world."],
                "the long line was split at a sentence end")
        require(VoiceRecoveryHTTP.posts == 2, "both parts of the long line were generated once")
        let single = subtitle.project.state.audioTracks.flatMap(\.clips)
        require(single.count == 1 && abs(single[0].timelineDuration - 12) < 0.2, "the long line joins each six-second batch exactly once")
        require(!subtitle.project.state.subtitleCues(of: .original).isEmpty, "the long line still has subtitles")

        let cancelled = try VoiceRecoveryFixture(folder: root.appendingPathComponent("cancelled"))
        cancelled.failSplitOnce = false
        cancelled.cancelSplitOnce = true
        let stopped = try await cancelled.wait(cancelled.clone(lines))
        require(stopped["status"] == "cancelled" && VoiceRecoveryHTTP.posts == 3, "local cancellation retains every paid batch and stays cancelled through typed processing errors")
        let stoppedFile = stopped["recovery_file"]!.stringValue!
        let resumedStop = try await cancelled.resume(stoppedFile)
        require(resumedStop["status"] == "done" && resumedStop["completed_line_indices"] == [0, 1, 2, 3, 4, 5] && VoiceRecoveryHTTP.posts == 3,
                "cancelled local processing resumes existing audio without paying again")

        // 应答未知没有原单号：永不把它当成 missing，即使显式 generate_missing 也不能重新 POST。
        let unknown = try VoiceRecoveryFixture(folder: root.appendingPathComponent("unknown"))
        unknown.failSplitOnce = false
        VoiceRecoveryHTTP.unknownSubmission = true
        let uncertain = try await unknown.wait(unknown.started(unknown.narrate(["Hello world."])))
        let unknownFile = uncertain["recovery_file"]!.stringValue!
        require(uncertain["unknown_batch_indices"] == [0], "unknown submission retains its original identity")
        _ = try await unknown.resume(unknownFile, generate: true)
        require(VoiceRecoveryHTTP.posts == 1, "unknown submission cannot be regenerated by recovery")
    }
}
