import Foundation

// MARK: - 给 AI 的总说明（MCP 的 `instructions`）：一份目录
//
// 管什么：所有工具共用的东西 —— SrtFlow 是什么、平常的顺序、几条必须**主动**做的规矩，和一份按需求分组的工具目录。
// 不管什么：某一个工具怎么用（写在它自己的说明里，Claude Code 用到那个工具才加载）；出结果那一刻才用得上的规矩
// （要用户点头、等用户操作、用户按了停止……写在那个结果里）。三层怎么分见 docs/architecture/ai-control-mcp.md 第一节第 6 条。
//
// **Claude Code 只读前 2,048 个字符**（JavaScript 的字符串长度，超了静默截掉、末尾加「… [truncated]」），Codex 要求前
// 512 个字符自成一体：所以开头一段就是完整的最短用法，配了提供方拼上「Paid」那一行也不许超 2,048。Claude Code 会话开始时只看得到
// 工具名和这份说明，目录是它知道「该去加载哪个工具」的依据，所以清单里的每个工具名都要在这里出现（checks/MCP/CatalogTextChecks.swift）。
// 只用英文。产品决定见 docs/plans/2026-09-27-mcp.md；为什么写成目录见 docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md。

public enum MCPInstructions {
    /// 存了 Sky Studio 的 Key 才有的那一行「Paid: …」，接在目录最后（没存就不提：客户端清单里也没有那两个工具）。2026-10-28 起
    /// generate_media、upscale_clip 都走 Sky Studio、花积分（收费方案第 6 刀）；云端配音也走 Sky Studio，不再多出一行。整份离 Claude Code
    /// 的 2,048 个字符只差几十个：这一行别再加长（checks/MCP/CatalogTextChecks.swift 量着）。花钱怎么问、每日上限写在两个工具自己的说明里：
    /// AI 调它之前一定会读到。
    static let skyStudioTools = "generate_media (image, video, music, sound effect), upscale_clip (sharper, larger): Sky Studio credits"

    public static func text(providers: Set<MCPProvider>) -> String {
        providers.contains(.skystudio) ? text + "\n- Paid: " + skyStudioTools : text
    }

    public static let text = """
    SkyCut is a video editor on the user's Mac. These tools edit projects open in SkyCut while the user \
    watches. Usual order: open_folder (the user's folder), open_project or new_project; get_timeline for ids; \
    look, listen and transcribe to see, hear and read the media (the only way); edit; export_video, then \
    get_job. Tool descriptions have the details; results say what to do next.

    Rules:
    - Unless the user said, ask once whether to show the edits in SkyCut or do them in the background; call set_view.
    - Edits need no OK: each is one undo step (undo round=true reverts the round).
    - Tell the user where a never-saved project was saved (project_saved_to).
    - Only use files the user gave you or these tools returned.
    - Do all the work with these tools: no ffmpeg, scripts or terminal on media, and do not download media. If \
    SkyCut cannot do it, say so.

    Tools by need:
    - Files: get_status, open_folder (or Finder selection), read_document (scripts), manage_files, open_project, \
    new_project, save_project, close_project
    - Whole video: recipes first, follow the style that fits (user's words win); save_recipe
    - Clips: add_clips, edit_clip (trim, speed, volume, fill 9:16, crop, animation), split_clip, delete_items, \
    duplicate_items, freeze_frame, set_keyframes
    - Record: record_screen (display, window or area, even while you work)
    - Talk and beat cuts: transcribe, cut_speech, listen beats=true, cut_to_beat
    - Picture: set_canvas (for 9:16, then edit_clip fit=fill each clip), set_transition, set_filter, set_text, \
    set_shape (also blur or mosaic a watermark)
    - Sound: find_audio (music, sound effects), add_clips sound_effect (whoosh, riser… made here), add_voiceover \
    (narration), set_track
    - Subtitles: generate_subtitles, translate_subtitles, get_subtitles, edit_subtitles, export_subtitles
    - Output: export_video; compress_videos, burn_subtitles, convert_subtitles (files only); get_job, cancel_job
    - View: set_view, seek
    """
}
