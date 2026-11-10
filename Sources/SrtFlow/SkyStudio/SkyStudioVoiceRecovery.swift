import Foundation
import SrtFlowMCPKit

// MARK: - 可恢复旁白的 App 适配
// 管什么：输入快照往返、恢复文件读写、原工程核对、并发恢复去重；原始音频和记录与成句文件一起长久保留。
// 不管什么：执行步骤 / HTTP / 入轨（SkyStudioVoiceoverRun）；进度的数据合同在 SkyStudioVoiceCheckpoint。

@MainActor
final class SkyStudioVoiceRecovery {
    static var active: [String: String] = [:]
    let file: URL
    var value: SkyStudioVoiceCheckpoint
    private var saving: Task<Void, Error>?

    init(input: AIVoiceoverInput, project: VideoEditProject, plan: SkyStudioVoicePlan, file: URL) {
        self.file = file
        let track: Int?
        if case .audio(let index) = input.target { track = index } else { track = nil }
        value = SkyStudioVoiceCheckpoint(input: .init(
            lines: input.lines.map { .init(text: $0.text, start: $0.start) }, language: input.language,
            voice: plan.voice, model: input.model, note: input.choice.note, speed: input.speed,
            audioTrack: track, subtitles: input.subtitles, maxLines: input.maxLines, folder: input.folder, playhead: project.clock.time
        ), projectPath: project.documentURL?.standardizedFileURL.path,
            projectToken: AIProjectBinding.token(generation: project.documentGeneration), plan: plan)
    }

    private init(file: URL, value: SkyStudioVoiceCheckpoint) { self.file = file; self.value = value }

    func save() async throws {
        let snapshot = value, file = file, previous = saving
        let next = Task {
            _ = try? await previous?.value
            try await MediaReadQueue.run(on: MediaReadQueue.voice) {
                Result { try SkyStudioVoiceRecoveryStore.write(snapshot, to: file) }
            }.get()
        }
        saving = next
        do { try await next.value }
        catch { throw SkyStudioVoiceProcessingError(stage: .checkpoint, underlying: error) }
    }

    func input(for project: VideoEditProject) throws -> AIVoiceoverInput {
        let saved = value.input
        let samePath = value.projectPath.map { $0 == project.documentURL?.standardizedFileURL.path } ?? false
        guard samePath || value.projectToken == AIProjectBinding.token(generation: project.documentGeneration) else {
            throw AIToolError("This recovery belongs to another project. Open its original project and pass that project id; no audio was generated or inserted.")
        }
        // 声音和模型照记录（整段报价时定下的），恢复不重新认声音、不重新选模型。
        return AIVoiceoverInput(lines: saved.lines.map { .init(text: $0.text, start: $0.start) }, speed: saved.speed,
            language: saved.language, requestedVoice: saved.voice, ask: nil, model: saved.model,
            choice: .init(engine: .skyStudio(voice: saved.voice), note: saved.note),
            target: saved.audioTrack.map(TrackDropTarget.audio) ?? .newAudioBottom,
            subtitles: saved.subtitles, maxLines: saved.maxLines, generation: project.documentGeneration, folder: saved.folder)
    }

    /// 复用 add_voiceover 起恢复任务，get_job 仍是唯一的进度查询口；默认完全不提交付费生成。
    static func resumeIfAsked(_ args: AIToolArguments, project: VideoEditProject, services: SkyStudioVoiceServices? = nil) async throws -> AIToolResult? {
        guard let path = try args.string("resume") else {
            if args.has("generate_missing") { throw AIToolError("generate_missing requires resume=recovery_file.") }
            return nil
        }
        let allowed = Set(["resume", "generate_missing", "project", "confirm_token"])
        guard Set(args.raw.objectValue?.keys.map { $0 } ?? []).isSubset(of: allowed) else {
            throw AIToolError("With resume, only pass recovery_file as resume, optional generate_missing and project. Original lines and voice are read from the recovery record.")
        }
        let file = AIWorkspace.shared.resolve(path).standardizedFileURL.resolvingSymlinksInPath()
        if let id = active[file.path] { return .ok(["status": "started", "job_id": .string(id), "recovery_file": .string(file.path)]) }
        if let ask = try AIWorkspace.shared.confirmReading([file], verb: "read voiceover recovery", args: args, project: project) { return ask }
        let value = try await MediaReadQueue.run(on: MediaReadQueue.voice) { Result { try SkyStudioVoiceRecoveryStore.read(file) } }.get()
        let recovery = SkyStudioVoiceRecovery(file: file, value: value)
        let input = try recovery.input(for: project)
        // 记录里的文件也过既有读取授权；恢复文件不是任意路径读权限的通行证。
        let files = value.batches.compactMap(\.rawFile) + value.outputs.values.map(\.url)
        if let ask = try AIWorkspace.shared.confirmReading(files, verb: "recover voiceover audio", args: args, project: project) { return ask }
        return SkyStudioVoiceoverRun(input: input, project: project, recovery: recovery,
                                    generateMissing: try args.bool("generate_missing") ?? false, services: services).start()
    }
}

struct SkyStudioVoiceProcessingError: LocalizedError {
    let stage: SkyStudioVoiceCheckpoint.Stage
    let underlying: Error
    var errorDescription: String? { (underlying as? AIToolError)?.message ?? underlying.localizedDescription }
}
