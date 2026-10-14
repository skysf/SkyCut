import Foundation
import SrtFlowMCPKit

// 联动的结果怎么报给 AI（AILinkageReport，2026-10-15）：挪了几样、删了几样之外，字幕收短了的、留在原地的各列出短 id 和一句话 ——
// 改入点之后被裁掉那截上的字幕留在原地，人在时间线上一眼看得见，AI 只能从结果里知道（docs/bugfixes/2026-10-15-linkage-moves-subtitles-as-a-block.md）。
// 编法见 scripts/check-mcp.sh。

func runLinkageReportChecks() {
    let shortened = UUID()
    let left = UUID()
    let ids = AIShortIDs([shortened, left])
    check(AILinkageReport.json(TimelineLinkage.Report(), ids: ids) == nil, "nothing followed: no linkage entry")

    let onlyLeft = AILinkageReport.json(TimelineLinkage.Report(leftCues: [left]), ids: ids)
    check(onlyLeft != nil, "a subtitle left behind is worth reporting even when nothing moved")
    checkEqual(onlyLeft?["left_subtitles"]?.arrayValue?.compactMap(\.stringValue), [ids.short(left)], "its short id is listed")
    check(onlyLeft?["note"]?.stringValue?.contains("delete_items") == true, "and the note says how to clean it up")

    let both = AILinkageReport.json(TimelineLinkage.Report(moved: 4, deleted: 1, shortenedCues: [shortened]), ids: ids)
    checkEqual(both?["moved"]?.doubleValue, 4, "moved count")
    checkEqual(both?["deleted"]?.doubleValue, 1, "deleted count")
    checkEqual(both?["shortened_subtitles"]?.arrayValue?.compactMap(\.stringValue), [ids.short(shortened)], "shortened subtitles are listed")
    check(both?["note"]?.stringValue?.contains("get_subtitles") == true, "and the AI is told to check their text")
    check(both?["left_subtitles"] == nil, "no left list when nothing was left behind")
}
