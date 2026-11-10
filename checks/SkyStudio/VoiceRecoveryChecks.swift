import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 恢复记录（version 2：整段报价时服务器的选择、每批实际跑的模型 / 有没有换备用）真写真读，以及已知原单恢复只 GET；
// 中途换了备用（声音 PR 4）：还没交的批照备用的那份（pendingSelection），各句不全是同一个模型时报 line_models。
// 实际任务 / 音频 / 字幕 / 撤销由 check-voice-recovery 运行 App 目标文件验证。
func runVoiceRecoveryChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-checkpoint-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let lines = [String](repeating: "Hello world.", count: 6)
        let catalog = SkyStudioCatalog(models: [SkyStudioModel(id: "index-tts-2", kind: "voice_clone", title: "Clone",
                                                               limits: ["max_characters_by_language": ["other": 30]])])
        let draft = try SkyStudioVoicePlan.draft(lines: lines, kind: "voice_clone", voice: sampleVoiceID, model: "auto", language: "en", catalog: catalog)
        let selection: JSONValue = ["model": "index-tts-2", "reference_language": "en"]
        let quoted: JSONValue = ["credits": 7.5, "voice_plan": ["selection": selection, "rule": "en_80"],
                                 "batches": .array(draft.speech.map { _ in ["credits": 2.5] }), "one_time": []]
        guard let quote = SkyStudioQuote(json: quoted) else { return check(false, "the recovery fixture quote reads") }
        let plan = try SkyStudioVoicePlan.quoted(draft, quote: quote)
        checkEqual(plan.batches.count, 3, "six lines pack into three cloned batches under a 30-character cap")
        let input = SkyStudioVoiceCheckpoint.Input(lines: lines.map { .init(text: $0) }, language: "en", voice: sampleVoiceID, speed: 1,
            subtitles: true, folder: folder, playhead: 7)
        var checkpoint = SkyStudioVoiceCheckpoint(input: input, projectPath: "/test/project.skycut", projectToken: "run-p1", plan: plan)
        checkpoint.willSubmit(0)
        guard var done = SkyStudioJobStatus(json: ["job_id": "original-1", "status": "done", "credits_charged": 2.5,
            "result": ["url": "http://127.0.0.1/voice.wav", "words": [["word": "Hello", "start": 0, "end": 1]],
                       "model": "index-tts-2", "fallback_used": false, "voice_plan": ["selection": selection]]]) else {
            return check(false, "a finished voice job reads")
        }
        checkpoint.received(done, at: 0)
        checkEqual(checkpoint.batches[0].model, "index-tts-2", "the model that actually read the batch is recorded")
        checkEqual(checkpoint.batches[0].fallbackUsed, false, "and whether Sky Studio switched to its fallback")
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
        checkEqual(read.version, 2, "recovery records are version 2")
        checkEqual(read.plan.voicePlan.selection, selection.objectValue ?? [:], "the whole segment's selection survives a disk round trip")
        check(read.plan.batches.allSatisfy { $0.request.params["plan"] == selection }, "every saved batch request carries that selection")
        checkEqual(read.batches[1].model, "index-tts-2", "each batch's actual model survives")
        let detail = read.detail(recoveryFile: file.path)
        checkEqual(detail["voice_plan"]?["selection"], selection, "get_job reports the voice_plan")
        checkEqual(detail["batches"]?.arrayValue?.first?["model"], "index-tts-2", "get_job reports each batch's model")
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
        for version in [1, 99] {
            checkpoint.version = version
            try SkyStudioVoiceRecoveryStore.write(checkpoint, to: file)
            do { _ = try SkyStudioVoiceRecoveryStore.read(file); check(false, "a version \(version) record must be rejected (only version 2)") }
            catch { check(true, "a version \(version) record is rejected (only version 2)") }
        }
    } catch { check(false, "voice checkpoint checks: \(error)") }
    fallbackSwitchChecks(folder: folder)

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

/// 声音 PR 4（SkyCut 声音方案 8.4）：整段带着自动备用；第二批在服务器上换了备用之后，还没交的批照备用的那份，记录里每句是哪个模型读的。
private func fallbackSwitchChecks(folder: URL) {
    do {
        let lines = [String](repeating: "Hello world.", count: 6)
        let catalog = SkyStudioCatalog(models: [SkyStudioModel(id: "index-tts-2", kind: "voice_clone", title: "Clone",
                                                               limits: ["max_characters_by_language": ["other": 30]])])
        let draft = try SkyStudioVoicePlan.draft(lines: lines, kind: "voice_clone", voice: sampleVoiceID, model: "auto", language: "en", catalog: catalog)
        let backup: JSONValue = ["model": "minimax-speech-2.8-hd", "reference_language": "en"]
        let selection: JSONValue = ["model": "index-tts-2", "reference_language": "en", "fallback": backup]
        let quoted: JSONValue = ["credits": 7.5, "voice_plan": ["selection": selection, "rule": "en_80",
                                 "fallback": ["selection": backup, "available": true, "auto": true, "one_time": .null]],
                                 "batches": .array(draft.speech.map { _ in ["credits": 2.5] }), "one_time": []]
        guard let quote = SkyStudioQuote(json: quoted) else { return check(false, "a quote with an automatic fallback reads") }
        let plan = try SkyStudioVoicePlan.quoted(draft, quote: quote)
        let input = SkyStudioVoiceCheckpoint.Input(lines: lines.map { .init(text: $0) }, language: "en", voice: sampleVoiceID, speed: 1,
            subtitles: true, folder: folder, playhead: 0)
        var checkpoint = SkyStudioVoiceCheckpoint(input: input, projectPath: nil, projectToken: "run-p1", plan: plan)
        checkEqual(checkpoint.pendingSelection, selection.objectValue ?? [:], "before any switch, unsent batches carry the script's selection")
        checkEqual(checkpoint.lineModels == nil, true, "nothing read yet: no line_models")
        func finish(_ index: Int, model: String, fallback: Bool) {
            checkpoint.willSubmit(index)
            if let done = SkyStudioJobStatus(json: ["job_id": .string("original-\(index)"), "status": "done", "credits_charged": 2.5,
                "result": ["url": "http://127.0.0.1/voice.wav", "model": .string(model), "fallback_used": .bool(fallback),
                           "voice_plan": ["selection": selection]]]) {
                checkpoint.received(done, at: index)
            }
        }
        finish(0, model: "index-tts-2", fallback: false)
        checkEqual(checkpoint.lineModels == nil, true, "every finished batch read by the same model: no line_models")
        finish(1, model: "minimax-speech-2.8-hd", fallback: true)
        checkEqual(checkpoint.pendingSelection, backup.objectValue ?? [:], "after a batch fell back, unsent batches carry voice_plan.fallback.selection")
        let models = checkpoint.lineModels?.map { "\($0.line):\($0.model):\($0.fallbackUsed)" } ?? []
        checkEqual(models, ["0:index-tts-2:false", "1:index-tts-2:false", "2:minimax-speech-2.8-hd:true", "3:minimax-speech-2.8-hd:true"],
                   "line_models lists the lines that were read, with their model (batches not read yet are not guessed)")
        checkEqual(checkpoint.detail(recoveryFile: "/r.json")["line_models"]?.arrayValue?.count, 4, "get_job reports line_models")
        let file = folder.appendingPathComponent("fallback-recovery.json")
        try SkyStudioVoiceRecoveryStore.write(checkpoint, to: file)
        checkEqual(try SkyStudioVoiceRecoveryStore.read(file).pendingSelection, backup.objectValue ?? [:],
                   "the switch survives a disk round trip (worked out from the recorded fallback_used, no new field)")
    } catch { check(false, "fallback switch checks: \(error)") }
}
