import Foundation

// MARK: - 说明书的地图：不带 topic 回的那一页
//
// 管什么：按任务分组的全部工具（带用户会说的词：9:16、配乐、口头禅、马赛克……）和通用主题的名字。2026-11-09 用户定：工具目录从总说明搬到这里
// （方案第八节第 1 条，改了 2026-09-30「总说明是目录、每个工具名都要在目录里」那条板）—— Codex 每打印一个工具条目就带一份整份总说明，
// 目录放在总说明里就是每个条目都背一份；Claude Code 本来就把工具名单独列给模型，地图在这里一次读全。
// 不管什么：总说明（MCPInstructions：入口和主动规矩）、某个工具怎么用（那个工具的主题）、通用主题的内容（MCPGuideSharedTopics）。
// 守卫（checks/MCP/GuideChecks.swift）：清单里**每个工具名都在这里**（整词）、≤ 5,000 字（UTF-16，量回答的 JSON 文字）、
// 提到的名字都真的存在、只用英文。新加工具时在合适的那一行加上它的名字和一两个用户会说的词。

enum MCPGuideMap {
    static let text = """
    SkyCut map: every tool by task. skycut_guide topic=<tool> gives that tool's guide; shared topics: rules, conventions, \
    paid, workflows, errors.
    Start: get_status (plan, projects, jobs; models=true for paid models), get_settings / set_settings (language, \
    permission mode, budgets), skycut_guide (this manual)
    Files: open_folder (a folder or the Finder selection), read_document (scripts, notes, PDF, Word), manage_files (move, \
    rename, Trash; asks first)
    Projects: open_project, new_project, save_project, close_project, set_view (watch or background), seek (show a \
    moment), undo (one step, or round=true for this round)
    See and hear: get_timeline (ids, tracks, edit_limits), look (frames, shots, faces, burned-in text, watermarks, black \
    bars), listen (levels, silence, beats, cut check), transcribe (words with times)
    Whole video: recipes (editing styles: pick one before cutting a whole video, tell the user which), save_recipe (keep \
    the user's own style)
    Clips: add_clips (files, library music, add_clips sound_effect for local sound effects), edit_clip (trim, speed, \
    volume, fades, crop, 9:16 reframe, position, animation, file swap), edit_clips (batch), split_clip, delete_items, \
    duplicate_items, freeze_frame, set_keyframes (animate position, size, rotation, opacity)
    Speech and beat cuts: cut_speech (filler words, pauses, retakes), cut_to_beat (cut V1 to music beats)
    Picture: set_canvas (9:16, 1:1, 16:9, frame rate), set_transition, set_filter (looks, colour), set_text / set_texts \
    (titles), set_shape / set_shapes (lines, boxes, circles, arcs; blur or mosaic to hide logos, faces, watermarks)
    Audio: find_audio (music and sound effects), add_voiceover (narration spoken from text), sync_voiceover (retime \
    pictures and titles to existing narration), set_track (track volume, mute or hide a track, master fader)
    Voices: list_voices (presets, my voices), manage_voices (clone my voice from a recording, design, rename, delete)
    Subtitles: generate_subtitles, translate_subtitles, get_subtitles, edit_subtitles (text, timing, style), \
    export_subtitles (subtitle files)
    Check and export: inspect_video (seams, black frames, subtitle problems), export_video (final, or \
    preset=quick_review for a fast small copy), get_job (wait for any job), cancel_job
    Files without a project: compress_videos, burn_subtitles, convert_subtitles
    Screen: record_screen (the screen, a window or an area, with the microphone if wanted)
    Paid, Sky Studio credits: \(paidTools)
    """

    /// 花积分的那一行（2026-10-30：始终列出，不能靠中途加了 Key 之后客户端重新发现工具；2026-10-28 起都走 Sky Studio）。
    static let paidTools = "generate_media (images, camera angles, image upscale, videos, lipsync, background cutout, music, sound effects), " +
        "upscale_clip (sharper, larger clips), manage_characters (create and headshot; import, edits and deletion are free), " +
        "add_voiceover (Sky Studio voices; SkyCut and Mac voices are free), manage_voices (design; recordings, rename and deletion are free); " +
        "free: list_characters, get_character, list_voices"
}
