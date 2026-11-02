import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 旁白可恢复的进度（纯值）
// 管什么：原文 / 批次 / 原单身份 / 完整音频 / 本地分析 / 成句文件 / 入轨回执；恢复只对 missing 批次允许付费。
// 不管什么：HTTP、音频处理、工程；磁盘读写在 SkyStudioVoiceRecoveryStore，App 适配在 SkyStudioVoiceRecovery。

struct SkyStudioVoiceCheckpoint: Codable, Sendable {
    struct Line: Codable, Sendable {
        var text: String
        var start: Double?
    }

    struct Input: Codable, Sendable {
        var lines: [Line]
        var language: String
        var voice: String
        var note: String?
        var speed: Double
        var cloneURL: URL?
        var cloneStart: Double?
        var cloneSeconds: Double?
        var audioTrack: Int?
        var subtitles: Bool
        var maxLines: Int?
        var folder: URL
        var playhead: Double
    }

    struct Analysis: Codable, Sendable {
        var words: [TimedWord]
        var slices: [SkyStudioVoiceSplit.Slice]
    }

    struct Output: Codable, Sendable {
        var url: URL
        var duration: Double
        var words: [TimedWord]
    }

    enum Stage: String, Codable, Sendable {
        case cloudGeneration = "cloud_generation"
        case download, checkpoint
        case localSplit = "local_split"
        case subtitleAlignment = "subtitle_alignment"
        case fileWrite = "file_write"
        case insertion
    }

    struct Issue: Codable, Sendable {
        var stage: Stage
        var batch: Int?
        var message: String
    }

    struct Batch: Codable, Sendable {
        var submitted = false
        var serverID: String?
        var remote: JSONValue?
        var rawFile: URL?
        var analysis: Analysis?
        var charged: Double = 0
        var uncertain: Double = 0
        /// 仅明确未扣费 / 全退且没有成品时允许重新生成。未知结果绝不变成 missing。
        var retryable = false
        var generated: Bool { remote != nil || rawFile != nil }
        var missing: Bool { !generated && (!submitted || retryable) }
    }

    var version = 1
    var id = UUID()
    var input: Input
    var projectPath: String?
    var projectToken: String
    var plan: SkyStudioVoicePlan
    var batches: [Batch]
    var outputs: [Int: Output] = [:]
    var referenceURL: URL?
    var landingIDs: [UUID] = []
    /// 一旦入轨成功，即使用户随后撤销，也不能因重试自动再加。
    var applied: JSONValue?
    var issue: Issue?

    init(input: Input, projectPath: String?, projectToken: String, plan: SkyStudioVoicePlan) {
        self.input = input
        self.projectPath = projectPath
        self.projectToken = projectToken
        self.plan = plan
        batches = plan.batches.map { _ in Batch() }
    }

    var missing: [Int] { batches.indices.filter { batches[$0].missing } }
    var unresolved: [Int] { batches.indices.filter { !batches[$0].generated && !batches[$0].missing } }
    var ready: Bool { input.lines.indices.allSatisfy { outputs[$0] != nil } }

    /// 在 POST 之前先写 submitted，崩溃 / 断网也不会把可能付过费的批次当成未生成。
    mutating func willSubmit(_ index: Int) {
        batches[index].submitted = true
        batches[index].retryable = false
        batches[index].serverID = nil
    }

    mutating func received(_ result: SkyStudioJobStatus, at index: Int) {
        batches[index].serverID = result.jobID
        if let remote = result.result { batches[index].remote = .object(remote.metadata) }
        if let charge = result.billing?.netCharged ?? result.creditsCharged {
            batches[index].charged = charge
            batches[index].uncertain = 0
        }
    }

    func detail(recoveryFile: String) -> [String: JSONValue] {
        func list(_ indices: [Int]) -> JSONValue { .array(indices.map { .number(Double($0)) }) }
        let completed = input.lines.indices.filter { outputs[$0] != nil }
        let generatedLines = Set(plan.batches.indices.filter { batches[$0].generated }.flatMap { plan.batches[$0].speech.parts.map(\.line) })
        let pending = generatedLines.subtracting(completed).sorted()
        let missingBatches = missing.filter { plan.batches[$0].speech.parts.contains { outputs[$0.line] == nil } }
        let missingLines = Set(missingBatches.flatMap { plan.batches[$0].speech.parts.map(\.line) }).subtracting(completed).sorted()
        let batchDetails: [JSONValue] = batches.indices.map { index in
            let batch = batches[index]
            let locallyCompleted = plan.batches[index].speech.parts.allSatisfy { outputs[$0.line] != nil }
            var value: [String: JSONValue] = [
                "batch_index": .number(Double(index)),
                "state": .string(batch.generated ? "generated" : (locallyCompleted ? "completed_locally" : (batch.missing ? "not_generated" : "cloud_outcome_unknown"))),
                "parts": .array(plan.batches[index].speech.parts.map { ["line_index": .number(Double($0.line)), "text": .string($0.text)] }),
                "submission_key": .string(plan.batches[index].request.idempotencyKey)
            ]
            if let id = batch.serverID { value["skystudio_job_id"] = .string(id) }
            if let file = batch.rawFile { value["complete_batch_file"] = .string(file.path) }
            if let remote = batch.remote { value["remote_result"] = remote }
            return .object(value)
        }
        var result: [String: JSONValue] = [
            "recovery_file": .string(recoveryFile), "batches": .array(batchDetails),
            "completed_line_indices": list(completed), "pending_recovery_line_indices": list(pending),
            "not_generated_line_indices": list(missingLines), "not_generated_batch_indices": list(missingBatches),
            "unknown_batch_indices": list(unresolved), "list_indices_are_zero_based": true,
            "files": .array(completed.compactMap { outputs[$0].map { .string($0.url.path) } }),
            "credits_charged": .number(batches.reduce(0) { $0 + $1.charged }),
            "credits_unknown": .number(batches.reduce(0) { $0 + $1.uncertain }),
            "inserted": .bool(applied != nil),
            "recovery_state": .string(applied != nil ? "complete" : (!unresolved.isEmpty ? "cloud_outcome_unknown" : (ready ? "ready_to_insert" : (pending.isEmpty ? "generation_needed" : "local_processing_needed")))),
            "recovery": ["tool": "add_voiceover", "arguments": ["resume": .string(recoveryFile)],
                         "generate_missing_arguments": ["resume": .string(recoveryFile), "generate_missing": true]]
        ]
        if let issue {
            result["failure_stage"] = .string(issue.stage.rawValue)
            result["recovery_issue"] = .string(issue.message)
        }
        result["next_step"] = .string(applied != nil
            ? "Already inserted. Do not add these lines again; repeating resume will not insert audio or subtitles."
            : "Call add_voiceover with resume=recovery_file. Default recovery only processes existing audio / original jobs and never pays to generate. "
                + "When local recovery succeeds, set generate_missing=true to generate only not_generated batches. Unknown outcomes only query original jobs; never resubmit them. Wait with get_job.")
        return result
    }
}

enum SkyStudioVoiceRecoveryStore {
    static func write(_ checkpoint: SkyStudioVoiceCheckpoint, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(checkpoint).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(_ url: URL) throws -> SkyStudioVoiceCheckpoint {
        let checkpoint = try JSONDecoder().decode(SkyStudioVoiceCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.version == 1, !checkpoint.input.lines.isEmpty, checkpoint.input.lines.count <= 50,
              !checkpoint.plan.batches.isEmpty, checkpoint.input.folder.isFileURL,
              checkpoint.input.audioTrack.map({ $0 >= 0 }) ?? true,
              checkpoint.input.speed.isFinite, (0.5...2).contains(checkpoint.input.speed),
              checkpoint.batches.count == checkpoint.plan.batches.count,
              checkpoint.outputs.allSatisfy({ checkpoint.input.lines.indices.contains($0.key) && $0.value.url.isFileURL && $0.value.duration.isFinite && $0.value.duration > 0 }),
              checkpoint.landingIDs.isEmpty || (checkpoint.landingIDs.count == checkpoint.input.lines.count && Set(checkpoint.landingIDs).count == checkpoint.landingIDs.count),
              checkpoint.plan.batches.allSatisfy({ !$0.speech.parts.isEmpty && $0.speech.parts.allSatisfy { checkpoint.input.lines.indices.contains($0.line) } }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return checkpoint
    }
}
