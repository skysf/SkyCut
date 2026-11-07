import Foundation

// MARK: - 给 AI 的总说明（MCP 的 `instructions`）：一份目录
//
// 管什么：所有工具共用的东西 —— SrtFlow 是什么、平常的顺序、几条必须**主动**做的规矩，和一份按需求分组的工具目录。
// 不管什么：某一个工具怎么用（写在它自己的说明里，Claude Code 用到那个工具才加载）；出结果那一刻才用得上的规矩
// （要用户点头、等用户操作、用户按了停止……写在那个结果里）。三层怎么分见 docs/architecture/ai-control-mcp.md 第一节第 6 条。
//
// **Claude Code 只读前 2,048 个字符**（JavaScript 的字符串长度，超了静默截掉、末尾加「… [truncated]」），Codex 要求前
// 512 个字符自成一体：所以开头一段就是完整的最短用法，包含「Paid」那一行也不许超 2,048。Claude Code 会话开始时只看得到
// 工具名和这份说明，目录是它知道「该去加载哪个工具」的依据，所以清单里的每个工具名都要在这里出现（checks/MCP/CatalogTextChecks.swift）。
// 只用英文。产品决定见 docs/plans/2026-09-27-mcp.md；为什么写成目录见 docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md。

public enum MCPInstructions {
    /// 始终列出的「Paid: …」，接在目录最后（2026-10-30：不能靠中途添加 Key 后客户端重新发现工具）。2026-10-28 起
    /// generate_media、upscale_clip 都走 Sky Studio、花积分（收费方案第 6 刀）；云端配音也走 Sky Studio，不再多出一行。
    /// 整份守 2,048 字符上限（checks/MCP/CatalogTextChecks.swift）。花钱怎么问、每日上限写在两个工具自己的说明里：
    /// AI 调它之前一定会读到；具体参数示例放对应工具，不放目录。
    static let skyStudioTools = "generate_media (image/video/lipsync/cutout/music/SFX), upscale_clip: Sky Studio credits"

    public static func text(providers: Set<MCPProvider>) -> String {
        text
    }

    public static let text = """
    SkyCut edits projects on this Mac. Start get_status and get_settings section=ai; open_folder, \
    open_project/new_project; get_timeline for fresh ids. Inspect with look/listen/transcribe before edits. \
    Batch: edit_clips/set_texts/set_shapes. Replace narration + retime: sync_voiceover. Check output/seams: \
    inspect_video. Review: export_video preset=quick_review, then get_job. Use only these tools and given/returned files.

    Rules:
    - Follow get_settings permission mode and conversation-language guidance.
    - set_view: full_access defaults visible unless told otherwise; ask mode asks once about visible/background.
    - undo round=true reverts this round; report project_saved_to.
    - No ffmpeg, scripts or terminal on media; do not download media. Say when a capability is missing.

    Tools by need:
    - Files: open_folder (Finder selection), read_document, manage_files; open_project, new_project, save_project, close_project
    - Whole video: recipes first (user's words win); save_recipe
    - Clips: add_clips, edit_clip (trim/speed/volume/crop/9:16), edit_clips (batch); split_clip, delete_items, \
    duplicate_items, freeze_frame, set_keyframes
    - Picture: set_canvas, set_transition, set_filter; set_text, set_texts (batch titles); set_shape (blur/mosaic), set_shapes (batch)
    - Speech/beat cuts: transcribe, cut_speech; listen beats=true, cut_to_beat
    - Audio: find_audio (music/SFX), add_clips sound_effect (local SFX), add_voiceover (generate narration), \
    sync_voiceover (existing narration timing), set_track
    - Subtitles: generate_subtitles, translate_subtitles, get_subtitles, edit_subtitles, export_subtitles
    - Review: inspect_video (mixed audio seams/black/subtitles); export_video preset=quick_review (fast copy); get_job, cancel_job
    - File output: compress_videos, burn_subtitles, convert_subtitles
    - App: get_settings, set_settings; set_view, seek, record_screen
    - Paid: \(skyStudioTools)
    - Characters: list_characters, get_character
    """
}
