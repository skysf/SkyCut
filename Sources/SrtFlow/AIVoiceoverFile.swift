import Foundation
import SrtFlowCore

// MARK: - 旁白文件的名字只在一处挑（本机 / 云端共用）
// 管什么：按句子起名、撞名加编号；尚未写完的路径也先占住，两个并行任务不能挑到同一个名字。
// 不管什么：合成或写文件的内容、入轨。

@MainActor
enum AIVoiceoverFile {
    private static var claimed: Set<String> = []

    static func make(
        text: String, folder: URL, write: @MainActor (URL) async throws -> AISpeechSynthesis.Output
    ) async throws -> AISpeechSynthesis.Output {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = ExportFileName.stem(from: AIVoiceoverPlacement.fileStem(text), droppingExtension: "m4a", fallback: "Voiceover")
        let url = ExportFileName.unoccupied(in: folder, stem: stem, pathExtension: "m4a") {
            FileManager.default.fileExists(atPath: $0.path) || claimed.contains($0.path)
        }
        claimed.insert(url.path)
        defer { claimed.remove(url.path) }
        return try await write(url)
    }
}
