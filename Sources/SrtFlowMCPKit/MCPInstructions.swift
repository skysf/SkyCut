import Foundation

// MARK: - 给 AI 的总说明（MCP 的 `instructions`）：入口 + 主动规矩 + 怎么读说明书
//
// 管什么：所有工具共用、AI 必须**主动**做的事 —— SkyCut 是什么、开头几步、几条规矩、什么时候读说明书（skycut_guide）。
// 不管什么：按任务分组的工具目录（2026-11-09 用户定搬进说明书的地图 MCPGuideMap，方案第八节第 1 条）；某一个工具怎么用（它的名片和说明书主题）；
// 出结果那一刻才用得上的规矩（要用户点头、等用户操作、用户按了停止……写在那个结果里）。四层怎么分见 docs/architecture/ai-control-mcp.md 第一节第 6 条。
//
// 为什么要短：Codex（代码模式）每打印一个工具条目就带一份整份总说明，2026-11-03 那批会话里重复的总说明占找工具输出的 32–59%；
// Claude Code 每轮都带着它。≤ 1,200 字（UTF-16），前 512 字自成一体、点到 open_folder / get_timeline / look / export_video / skycut_guide
// 和批量、同步、检查、审阅那几个入口（checks/MCP/CatalogTextChecks.swift、UsageExampleChecks.swift）。往这里加东西之前先问：
// 它是不是要 AI 主动去做？不是的话放进名片、说明书或者结果。只用英文。方案见 docs/plans/2026-11-09-mcp-guide.md 2.4。

public enum MCPInstructions {
    public static func text(providers: Set<MCPProvider>) -> String {
        text
    }

    public static let text = """
    SkyCut edits video projects on this Mac. Start: get_status, get_settings section=ai, skycut_guide (free map of every \
    tool by task). Then open_folder, open_project/new_project; get_timeline for fresh ids; look/listen/transcribe before \
    edits. Batch: edit_clips/set_texts/set_shapes. Replace narration + retime: sync_voiceover. Check output/seams: \
    inspect_video. Review: export_video preset=quick_review, then get_job.

    Rules:
    - Use only SkyCut tools and given/returned files: no ffmpeg, scripts or terminal on media; do not download media \
    (music/SFX: find_audio); say when a capability is missing.
    - Follow get_settings permission mode and conversation language.
    - set_view: full_access defaults visible unless told; ask mode asks once (visible/background).
    - Whole video: pick an editing style with recipes first; the user's words win.
    - undo round=true reverts this round; report project_saved_to.
    - Results with next_step, needs_confirmation or waiting_for_user: do what they say.
    - Before a tool's first use, read skycut_guide topic=<tool> if its description says so; after a failed call, read it \
    before retrying.
    """
}
