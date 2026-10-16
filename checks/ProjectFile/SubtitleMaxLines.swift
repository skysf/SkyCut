import Foundation
import SrtFlowCore

// 第 46 组：生成的字幕一条最多几行跟着工程走（`TimelineState.subtitleMaxLines`，2026-10-16 用户定：默认都是单行，
// 除非在生成面板上调成两行、或者 AI 的 max_lines=2）。按需写键（单行不落键）、缺键 = 单行、文件里写了别的数夹成 1 或 2。
// 编法见 scripts/check-project-file.sh。

func checkSubtitleMaxLines(root: URL) throws {
    let folder = root.appendingPathComponent("lines")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("p.srtflowproj")
    var state = TimelineState()
    checkEqual(state.subtitleMaxLines, 1, "新工程默认单行")

    // ---- 单行（默认）：不写键，读回来是单行 ----
    try VideoEditProjectIO.save(state, to: path)
    let oneRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    check((oneRaw?["timeline"] as? [String: Any])?["subtitleMaxLines"] == nil, "单行不写 subtitleMaxLines 键（按需写键）")
    checkEqual(try VideoEditProjectIO.load(from: path).timeline.subtitleMaxLines, 1, "缺键读作单行（老工程都没有这个键）")

    // ---- 两行：写键、往返不丢 ----
    state.subtitleMaxLines = 2
    try VideoEditProjectIO.save(state, to: path)
    let twoRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual((twoRaw?["timeline"] as? [String: Any])?["subtitleMaxLines"] as? Int, 2, "两行写 subtitleMaxLines: 2")
    checkEqual(try VideoEditProjectIO.load(from: path).timeline.subtitleMaxLines, 2, "往返不丢两行")

    // ---- 文件里写了别的数（手改、以后的版本）：夹成 1 或 2 ----
    for (written, expected) in [(0, 1), (5, 2), (-3, 1)] {
        var raw = twoRaw ?? [:]
        var timeline = raw["timeline"] as? [String: Any] ?? [:]
        timeline["subtitleMaxLines"] = written
        raw["timeline"] = timeline
        let odd = folder.appendingPathComponent("odd-\(written).srtflowproj")
        try JSONSerialization.data(withJSONObject: raw).write(to: odd)
        checkEqual(try VideoEditProjectIO.load(from: odd).timeline.subtitleMaxLines, expected, "文件里写了 \(written) 夹成 \(expected)")
    }
}
