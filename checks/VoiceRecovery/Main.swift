import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 真正的 App 对象回归：只注入网络 / 转写，执行真实落盘、恢复入口、音频解码、切句、字幕、入轨和 UndoManager。
@main enum VoiceRecoveryChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.voicerecoverycheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Voice recovery checks require the isolated test bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        _ = NSApplication.shared
        var failures = 0
        func require(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_VOICE_RECOVERY_CHECK_DIR"]!)
        do {
            // 第二批已经生成成功，真实分句算法收到空转写后失败；第三批还没有提交。
            let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("split"))
            let spent = SkyStudioSpendStore.shared.spentToday()
            let lines = [String](repeating: "Hello world.", count: 6)
            let first = try await fixture.wait(SkyStudioVoiceoverRun(input: fixture.input(lines: lines), project: fixture.project, services: fixture.services).start())
            require(first["status"] == "failed" && first["failure_stage"] == "local_split", "local split failure must be distinct from cloud generation")
            let file = first["recovery_file"]!.stringValue!
            let saved = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
            require(VoiceRecoveryHTTP.posts == 2, "failure stops after exactly two paid batches")
            require(SkyStudioSpendStore.shared.spentToday() == spent + 5, "successful cloud batches remain charged; ungenerated batches release their reservation")
            require(saved.missing == [2] && saved.batches[1].generated, "successful second batch must never become missing")
            require(saved.batches.prefix(2).allSatisfy { $0.rawFile.map { FileManager.default.fileExists(atPath: $0.path) } == true }, "both complete originals must survive failure")
            require(saved.outputs.count == 2 && saved.batches[1].remote != nil, "line outputs, mappings, cloud result and progress are durable")
            require(fixture.project.state.audioTracks.allSatisfy { $0.clips.isEmpty }, "failed processing must not insert a partial voiceover")
            // 克隆的参考录音（SkyCut 声音方案第六节）：只传一次、用途 voice_reference、传上去的是整段 12 秒的 44.1 kHz 单声道 16-bit WAV。
            let uploadPosts = VoiceRecoveryHTTP.log.filter { $0.0 == "POST" && $0.1.hasSuffix("/uploads") }
            require(uploadPosts.count == 1 && uploadPosts.first?.2["purpose"] == "voice_reference" && uploadPosts.first?.2["content_type"] == "audio/wav",
                    "the voice sample is uploaded once, as audio/wav with the voice_reference purpose")
            let wav = VoiceRecoveryHTTP.uploads.first ?? Data()
            func field(_ offset: Int, _ size: Int) -> Int { wav.count < 44 ? -1 : (0..<size).reduce(0) { $0 | Int(wav[wav.startIndex + offset + $1]) << (8 * $1) } }
            require(wav.count == 44 + 529_200 * 2 && field(22, 2) == 1 && field(24, 4) == 44_100 && field(34, 2) == 16,
                    "the uploaded voice sample is the whole 12 s as a 44.1 kHz mono 16-bit WAV")
            require(saved.input.note?.contains("Voice sample: all of reference.wav (0:12), 12 s of clear speech.") == true,
                    "the recovery record says which part of the recording became the voice sample")
            let firstFiles = saved.outputs.mapValues(\.url)
            let reads = fixture.keyReads
            SkyStudioSpendStore.shared.setDailyLimit(0)
            // 默认恢复仅本地：不读 Key、不报价、不上传、不生成第二批，也不开始第三批。
            let local = try await fixture.resume(file)
            require(local["status"] == "failed" && local["failure_stage"] == nil, "available audio recovers; missing generation is reported separately")
            require(VoiceRecoveryHTTP.posts == 2 && fixture.keyReads == reads, "local retry must never invoke cloud generation or even read the key")
            require(SkyStudioSpendStore.shared.spentToday() == spent + 5, "local retry must not reserve or charge credits")
            let afterLocal = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
            require(afterLocal.outputs.count == 4 && afterLocal.missing == [2], "default recovery processes the saved second batch and leaves only the ungenerated third")
            require(firstFiles.allSatisfy { afterLocal.outputs[$0.key]?.url == $0.value }, "already completed files must not be rewritten")
            let blocked = try await fixture.resume(file, generate: true)
            require(blocked["status"] == "failed" && blocked["code"] == "daily_budget_exceeded" && VoiceRecoveryHTTP.posts == 2,
                    "a hard budget blocks missing generation while retaining all recovered audio")
            SkyStudioSpendStore.shared.setDailyLimit(1_000)
            let beforeLocal = VoiceRecoveryHTTP.log.count
            let completed = try await fixture.resume(file, generate: true)
            require(completed["status"] == "done", "explicit missing-only generation completes the narration")
            require(completed["voice"]?["note"]?.stringValue?.contains("Voice sample: all of reference.wav") == true,
                    "the finished voiceover tells the AI which part of the recording was cloned")
            require(VoiceRecoveryHTTP.posts == 3, "recovery generates only the previously ungenerated third batch")
            require(SkyStudioSpendStore.shared.spentToday() == spent + 7.5, "missing-only generation reserves only the final batch")
            let newPosts = Array(VoiceRecoveryHTTP.log.dropFirst(beforeLocal)).filter { $0.0 == "POST" }
            require(newPosts.filter { $0.1.hasSuffix("/quote") }.count == 1 && !newPosts.contains { $0.1.hasSuffix("/uploads") }, "recovery quotes one missing batch and reuses the uploaded reference")
            let state = fixture.project.state
            let clips = state.audioTracks.flatMap(\.clips)
            require(clips.count == 6 && Set(clips.map(\.sourceURL)).count == 6, "final content must have exactly six distinct audio files")
            let cues = state.subtitleCues(of: .original)
            require(cues.count == 6 && Set(cues.map(\.id)).count == 6, "final content must have exactly six subtitles")
            let repeated = try await fixture.resume(file, generate: true)
            require(repeated["status"] == "done" && fixture.project.state == state && VoiceRecoveryHTTP.posts == 3, "repeated recovery must not duplicate audio/subtitles or pay again")
            // 模拟工程已落账、最终回执写盘前退出：预先写下的稳定片段身份必须仍能识别那次插入。
            var prepared = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: file))
            prepared.applied = nil
            try SkyStudioVoiceRecoveryStore.write(prepared, to: URL(fileURLWithPath: file))
            let receiptRecovered = try await fixture.resume(file)
            require(receiptRecovered["status"] == "done" && fixture.project.state == state && VoiceRecoveryHTTP.posts == 3,
                    "prepared insertion receipt must survive a missing final receipt without duplicating clips or subtitles")
            fixture.project.effectiveUndoManager!.undo()
            require(fixture.project.state.audioTracks.flatMap(\.clips).isEmpty && fixture.project.state.subtitleCues(of: .original).isEmpty, "one undo removes the complete recovered voiceover and subtitles")
            _ = try await fixture.resume(file)
            require(fixture.project.state.audioTracks.flatMap(\.clips).isEmpty, "retry after user undo must respect the saved insertion receipt")
            fixture.project.effectiveUndoManager!.redo()
            require(fixture.project.state == state, "one redo restores the complete recovered narration")

            // clone_seconds 不再「默认 10、夹在 5–30」：不到 10 秒当场拒；不给就到结尾（超过 3 分钟自动挑一段）。
            let referencePath = root.appendingPathComponent("split/reference.wav").path
            var refusedShort = false
            do { _ = try AIVoiceoverInput.cloneSource(AIToolArguments(["clone_from": .string(referencePath), "clone_seconds": 5])) } catch { refusedShort = true }
            require(refusedShort, "clone_seconds under 10 s is refused before any job starts")
            let open = try AIVoiceoverInput.cloneSource(AIToolArguments(["clone_from": .string(referencePath), "clone_start": 2]))
            require(open?.start == 2 && open?.seconds == nil && open?.end == nil, "without clone_seconds the voice sample runs to the end of the file")
            let named = try AIVoiceoverInput.cloneSource(AIToolArguments(["clone_from": .string(referencePath), "clone_start": 1, "clone_seconds": 45]))
            require(named?.end == 46, "clone_seconds is no longer capped at 30 s")

            // 云端明确失败 / 全退：只补这一批与后面未提交的批次；成功批次仍不重复。
            let cloud = try VoiceRecoveryFixture(folder: root.appendingPathComponent("cloud"))
            cloud.failSplitOnce = false
            VoiceRecoveryHTTP.cloudFailure = 1
            let failedCloud = try await cloud.wait(SkyStudioVoiceoverRun(input: cloud.input(lines: lines), project: cloud.project, services: cloud.services).start())
            require(failedCloud["failure_stage"] == "cloud_generation", "provider failure has its own stage")
            let cloudFile = failedCloud["recovery_file"]!.stringValue!
            let cloudProgress = try SkyStudioVoiceRecoveryStore.read(URL(fileURLWithPath: cloudFile))
            require(cloudProgress.missing == [1, 2] && cloudProgress.outputs.count == 2, "only the refunded failed batch and unstarted tail are missing")
            VoiceRecoveryHTTP.cloudFailure = nil
            let cloudDone = try await cloud.resume(cloudFile, generate: true)
            require(cloudDone["status"] == "done" && VoiceRecoveryHTTP.posts == 4, "partial cloud success only generates the failed and unstarted batches")
            require(cloud.project.state.audioTracks.flatMap(\.clips).count == 6 && cloud.project.state.subtitleCues(of: .original).count == 6, "partial cloud recovery has no duplicate content")

            // 长句跨批：第二批只需字幕对齐，失败后重新从两个原文件拼齐，不丢、不把第一片拼两次。
            let subtitle = try VoiceRecoveryFixture(folder: root.appendingPathComponent("subtitle"))
            subtitle.failSplitOnce = true
            let long = ["Hello world. Hello world. Hello world."]
            let failedSubtitle = try await subtitle.wait(SkyStudioVoiceoverRun(input: subtitle.input(lines: long), project: subtitle.project, services: subtitle.services).start())
            require(failedSubtitle["failure_stage"] == "subtitle_alignment", "subtitle alignment failure must be distinct from splitting and generation")
            let subtitleFile = failedSubtitle["recovery_file"]!.stringValue!
            require(VoiceRecoveryHTTP.posts == 2, "both parts of the long line were generated before subtitle failure")
            let subtitleDone = try await subtitle.resume(subtitleFile)
            require(subtitleDone["status"] == "done" && VoiceRecoveryHTTP.posts == 2, "subtitle recovery reuses both original batches")
            let single = subtitle.project.state.audioTracks.flatMap(\.clips)
            require(single.count == 1 && abs(single[0].timelineDuration - 12) < 0.2, "long-line recovery joins each six-second batch exactly once")
            require(!subtitle.project.state.subtitleCues(of: .original).isEmpty, "recovered long line includes aligned subtitles")

            // 一次就做完的克隆：参考是这一次传的，结果的 voice.note 也要说用了素材的哪一段（恢复时从记录里读，见上面）。
            let fresh = try VoiceRecoveryFixture(folder: root.appendingPathComponent("fresh"))
            fresh.failSplitOnce = false
            let freshDone = try await fresh.wait(SkyStudioVoiceoverRun(input: fresh.input(lines: ["Hello world."]), project: fresh.project, services: fresh.services).start())
            require(freshDone["status"] == "done" && freshDone["voice"]?["note"]?.stringValue?.contains("Voice sample: all of reference.wav") == true,
                    "a clone finished in one run tells the AI which part of the recording was used")

            let cancelled = try VoiceRecoveryFixture(folder: root.appendingPathComponent("cancelled"))
            cancelled.failSplitOnce = false
            cancelled.cancelSplitOnce = true
            let stopped = try await cancelled.wait(SkyStudioVoiceoverRun(input: cancelled.input(lines: lines), project: cancelled.project, services: cancelled.services).start())
            require(stopped["status"] == "cancelled" && VoiceRecoveryHTTP.posts == 2, "local cancellation retains both paid batches and stays cancelled through typed processing errors")
            let stoppedFile = stopped["recovery_file"]!.stringValue!
            let resumedStop = try await cancelled.resume(stoppedFile)
            require(resumedStop["completed_line_indices"] == [0, 1, 2, 3] && VoiceRecoveryHTTP.posts == 2,
                    "cancelled local processing resumes existing audio without paying again")

            // 应答未知没有原单号：永不把它当成 missing，即使显式 generate_missing 也不能重新 POST。
            let unknown = try VoiceRecoveryFixture(folder: root.appendingPathComponent("unknown"))
            unknown.failSplitOnce = false
            VoiceRecoveryHTTP.unknownSubmission = true
            let uncertain = try await unknown.wait(SkyStudioVoiceoverRun(input: unknown.input(lines: ["Hello world."]), project: unknown.project, services: unknown.services).start())
            let unknownFile = uncertain["recovery_file"]!.stringValue!
            require(uncertain["unknown_batch_indices"] == [0], "unknown submission retains its original identity")
            _ = try await unknown.resume(unknownFile, generate: true)
            require(VoiceRecoveryHTTP.posts == 1, "unknown submission cannot be regenerated by recovery")
        } catch {
            failures += 1
            print("FAIL: production voice recovery checks: \(error)")
        }
        ProjectTeardown.stopPreview(OpenProjects.shared.primary)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        if failures > 0 { print("FAIL: \(failures) production voice recovery checks"); exit(1) }
        print("PASS: production voice recovery: second-batch split failure, local-only retry, missing-only generation, subtitle recovery, stable files, durable receipt, six clips/cues, one undo/redo and unknown-submit refusal")
        exit(0)
    }
}
