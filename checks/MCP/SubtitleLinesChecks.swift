import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 字幕几行（generate_subtitles / add_voiceover 的 max_lines，2026-10-16 用户定：默认都是单行，AI 要两行得说）：
// 参数只认 1 和 2；配音的字幕配置带上行数 —— 两行时整句一条、中间一个换行，默认照旧拆成几条单行；
// 两个工具的 schema 都收 max_lines 且上限 2、说明写着默认单行。编法见 scripts/check-mcp.sh。

func runSubtitleLinesChecks() {
    func parse(_ object: [String: JSONValue]) throws -> Int? { try AISubtitleLines.parse(AIToolArguments(.object(object))) }
    do {
        checkEqual(try parse([:]), nil, "max_lines：没给是 nil（按工程记的）")
        checkEqual(try parse(["max_lines": 2]), 2, "max_lines：2 = 一条能占两行")
        checkEqual(try parse(["max_lines": 1]), 1, "max_lines：1 = 单行")
    } catch {
        check(false, "max_lines：合法的值不该抛错：\(error)")
    }
    checkThrows("max_lines：3 行不认") { _ = try parse(["max_lines": 3]) }
    checkThrows("max_lines：0 不认") { _ = try parse(["max_lines": 0]) }
    checkThrows("max_lines：要整数") { _ = try parse(["max_lines": 1.5]) }
    checkEqual(AISubtitleLines.key, "max_lines", "参数名和说明里的一致")

    // 配音的字幕：默认单行、说了两行才两行。
    let one = AIVoiceoverSubtitles.config(languageCode: "en", frameDuration: 1.0 / 24, maxLineEms: .infinity)
    checkEqual(one.maxLineCount, 1, "配音的字幕：没说几行就是单行")
    let two = AIVoiceoverSubtitles.config(languageCode: "en", frameDuration: 1.0 / 24, maxLineEms: .infinity, maxLineCount: 2)
    checkEqual(two.maxLineCount, 2, "配音的字幕：max_lines=2 带进分段配置")
    checkEqual(two.splitsAtClauses, false, "配音的字幕：两行照样不按逗号拆")
    let narration = "the quick brown fox jumps over the lazy dog near the river bank".split(separator: " ")
    let words: [TimedWord] = narration.enumerated().map { index, word in
        let start = Double(index) * 0.4
        return TimedWord(text: (index == 0 ? "" : " ") + word, start: start, end: start + 0.35)
    }
    let piece = AIVoiceoverSubtitles.Piece(clipID: UUID(), timelineStart: 0, duration: 6, laneRank: 1, words: words)
    var single = TimelineState()
    _ = AIVoiceoverSubtitles.add([piece], language: "en", config: one, to: &single)
    let singleTexts = single.subtitleCues(of: .original).map(\.text)
    check(singleTexts.count >= 2 && singleTexts.allSatisfy { !$0.contains("\n") }, "配音的字幕默认单行：放不下的拆成几条 \(singleTexts)")
    var double = TimelineState()
    _ = AIVoiceoverSubtitles.add([piece], language: "en", config: two, to: &double)
    let doubleTexts = double.subtitleCues(of: .original).map(\.text)
    checkEqual(doubleTexts.count, 1, "配音的字幕两行：整句一条 \(doubleTexts)")
    check(doubleTexts.first.map { $0.filter { $0 == "\n" }.count } == 1, "配音的字幕两行：中间正好一个换行 \(doubleTexts)")

    // 工具说明：两个工具都收 max_lines（1…2），generate_subtitles 写着默认单行、只在用户要两行时传 2。
    for tool in [MCPToolName.generateSubtitles, .addVoiceover] {
        let property = tool.definition.inputSchema["properties"]?["max_lines"]
        checkEqual(property?["minimum"]?.intValue, 1, "\(tool.rawValue)：收 max_lines，下限 1")
        checkEqual(property?["maximum"]?.intValue, 2, "\(tool.rawValue)：max_lines 上限 2")
    }
    let description = MCPToolName.generateSubtitles.definition.description
    check(description.contains("Each subtitle is one line") && description.contains("max_lines=2 only when the user wants"),
          "generate_subtitles 的说明写着默认单行、只在用户要两行时传 2")
    check(MCPToolName.getSubtitles.definition.description.contains("max_lines"), "get_subtitles 的说明提到回 max_lines")
}
