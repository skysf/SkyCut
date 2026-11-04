import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 恢复记录真写真读，以及已知原单恢复只 GET；实际任务 / 音频 / 字幕 / 撤销由 check-voice-recovery 运行 App 目标文件验证。
func runVoiceRecoveryChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-checkpoint-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let lines = [String](repeating: "Hello world.", count: 6)
        let model = SkyStudioModel(id: "test-clone", kind: "voice_clone", title: "Clone", params: ["language": ["en_us"]],
                                   limits: ["max_characters_by_language": ["en_us": 30]])
        let plan = try SkyStudioVoicePlan.make(lines: lines, model: model, voice: "cloned voice", language: "en")
        let input = SkyStudioVoiceCheckpoint.Input(lines: lines.map { .init(text: $0) }, language: "en", voice: "cloned voice", speed: 1,
            subtitles: true, folder: folder, playhead: 7)
        var checkpoint = SkyStudioVoiceCheckpoint(input: input, projectPath: "/test/project.skycut", projectToken: "run-p1", plan: plan)
        checkpoint.willSubmit(0)
        var done = SkyStudioJobStatus(jobID: "original-1", state: .done)
        done.result = SkyStudioJobResult(json: ["url": "http://127.0.0.1/voice.wav", "words": [["word": "Hello", "start": 0, "end": 1]]])
        done.creditsCharged = 2.5
        checkpoint.received(done, at: 0)
        checkpoint.batches[0].rawFile = folder.appendingPathComponent("batch-0.wav")
        checkpoint.willSubmit(1)
        done.jobID = "original-2"
        checkpoint.received(done, at: 1)
        checkpoint.issue = .init(stage: .localSplit, batch: 1, message: "alignment failed")
        let file = folder.appendingPathComponent("voiceover-recovery.json")
        try SkyStudioVoiceRecoveryStore.write(checkpoint, to: file)
        let read = try SkyStudioVoiceRecoveryStore.read(file)
        checkEqual(read.missing, [2], "cloud success plus local failure preserves exactly the missing third batch")
        checkEqual(read.plan.batches.map(\.speech), plan.batches.map(\.speech), "batch-to-line mappings survive a disk round trip")
        checkEqual(read.plan.batches.map(\.request.idempotencyKey), plan.batches.map(\.request.idempotencyKey), "all original submission keys survive")
        checkEqual(read.batches[1].remote, checkpoint.batches[1].remote, "the successful second result URL and word metadata remain recoverable")
        checkEqual(read.input.playhead, 7, "recovery retains the original placement anchor")
        let detail = read.detail(recoveryFile: file.path)
        checkEqual(detail["failure_stage"], "local_split", "local failure is not reported as cloud failure")
        checkEqual(detail["not_generated_batch_indices"], [2], "result explicitly lists only ungenerated batches")
        checkEqual(detail["recovery"]?["tool"], "add_voiceover", "recovery reuses the existing tool")
        checkEqual(detail["recovery"]?["arguments"]?["resume"], .string(file.path), "result contains executable recovery arguments")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        checkEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "recovery text and result URLs are private")
        checkpoint.willSubmit(2)
        checkEqual(checkpoint.missing, [], "a possibly accepted submission cannot be treated as missing")
        checkEqual(checkpoint.unresolved, [2], "unknown submission is retained for original-job lookup")
        checkpoint.batches[2].retryable = true
        checkEqual(checkpoint.missing, [2], "only explicit no-charge evidence releases a failed batch for generation")
        checkpoint.outputs[99] = .init(url: folder.appendingPathComponent("bad.m4a"), duration: 1, words: [])
        try SkyStudioVoiceRecoveryStore.write(checkpoint, to: file)
        do { _ = try SkyStudioVoiceRecoveryStore.read(file); check(false, "corrupt output line index must not reach the renderer") }
        catch { check(true, "corrupt output line index rejected") }
        for line in lines.indices { checkpoint.outputs[line] = .init(url: folder.appendingPathComponent("local-\(line).m4a"), duration: 1, words: []) }
        checkpoint.outputs[99] = nil
        let localDetail = checkpoint.detail(recoveryFile: file.path)
        checkEqual(localDetail["not_generated_line_indices"], [], "completed local fallback lines are not falsely reported as missing narration")
        checkEqual(localDetail["not_generated_batch_indices"], [], "completed local fallback does not tell MCP to generate cloud batches")
        checkpoint.outputs = [:]
        checkpoint.version = 99
        try SkyStudioVoiceRecoveryStore.write(checkpoint, to: file)
        do { _ = try SkyStudioVoiceRecoveryStore.read(file); check(false, "newer checkpoint format must be rejected") }
        catch { check(true, "newer checkpoint format rejected") }
    } catch { check(false, "voice checkpoint checks: \(error)") }

    SkyStudioStub.reset { _ in .http(200, sampleDoneJobFor("job-1")) }
    var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
    run.sleep = SleepLog().sleep
    let checkpoints = UpdateLog()
    run.checkpoint = { status in checkpoints.add(.status(status)) }
    do {
        let result = try await run.resume("job-1")
        checkEqual(result.state, .done, "a previously successful cloud job can be recovered")
        checkEqual(SkyStudioStub.log.map(\.method), ["GET"], "known job recovery never submits a paid POST")
        checkEqual(checkpoints.phases, ["done"], "original server identity is checkpointed before recovery returns")
    } catch { check(false, "original job recovery: \(error)") }
}
