import Foundation
import SrtFlowMCPKit

// 联动的结果怎么报给 AI（AILinkageReport，2026-10-15）：挪了几样、删了几样之外，字幕收短了的、留在原地的各列出短 id 和一句话，
// 跟着没了的字幕报几句（deleted_subtitles）—— 改入点之后说的话被裁掉的字幕跟着没了（docs/bugfixes/2026-10-15-linkage-deletes-subtitles-whose-speech-was-trimmed.md），
// 只报一个 deleted AI 会以为删了段；留在原地的（段整个没了又不是真删，少见）人一眼看得见，AI 只能从结果里知道。
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
    check(both?["deleted_subtitles"] == nil, "no subtitle count when the deleted item was not a subtitle")

    let trimmed = AILinkageReport.json(TimelineLinkage.Report(moved: 58, deleted: 1, shortenedCues: [shortened], deletedCues: 1), ids: ids)
    checkEqual(trimmed?["deleted_subtitles"]?.doubleValue, 1, "a subtitle deleted with its trimmed speech is counted separately")
    check(trimmed?["note"]?.stringValue?.contains("trimmed away") == true, "and the note says why it went")
}
