import Foundation

// MARK: - 说明书：读时间线和整轨 / 整段的改动（第二批，2026-11-10）
//
// 管什么：get_timeline、set_track、split_clip、delete_items、duplicate_items、set_transition、set_canvas 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCardsBatch2）、docs/architecture/mcp-edit-parameters.md（edit_limits、拒绝还是夹住）、
// timeline-linkage.md（联动的规矩、字幕剩不到一半就删）、timeline-clipboard.md（复制像粘贴一样落、撞上往上抬、分割后一对还是一对）、
// transition-handles.md（借余料、不够用首尾帧定格、被夹短）、docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md（set_transition 报
// 每条缝）、2026-10-03-set-canvas-fps-ignored-while-recording.md（录屏中挡改帧率）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideTimelineEditTopics {
    static let getTimeline = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.getTimeline,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.getTimeline, """
            get_timeline reads the whole timeline; it never changes anything.
            """),
            MCPGuideSection(name: "contents", about: "tracks, items, ids and settings in the result", text: """
            Contents. Every track (V1 main, V2 and up, A1 and up) with its clips, plus texts, shapes, filters and subtitles, \
            each with its id, timing and settings; the canvas, the frame rate, and the linkage and magnet switches. Ids can \
            change after edits that recreate items (split_clip, cut_speech, freeze_frame), so read it again before editing.
            """),
            MCPGuideSection(name: "limits", about: "edit_limits: native ranges and whether values fail or clamp", text: """
            Limits. edit_limits gives the native ranges SkyCut enforces and whether an out-of-range value is rejected or \
            clamped (for example crop, speed, scale, volume_db, image_source_duration and keyframe_scale). Use them instead of \
            guessing.
            """),
            MCPGuideSection(name: "credits", about: "music_credits for library music", text: """
            Music credits. music_credits lists the library music on the timeline with its credit line; pass the CC-BY credits \
            on to the user when you deliver.
            """)
        ],
        examples: [["project": "p2"]],
        related: ["edit_clip", "look", "conventions"]
    )

    static let setTrack = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.setTrack,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.setTrack, """
            set_track changes a whole track; each call is one undo step.
            """),
            MCPGuideSection(name: "fader", about: "track and master faders in dB", text: """
            Fader. volume_db is the track's fader in dB, on top of each clip's own volume and curve, clamped to \
            edit_limits.volume_db (the result returns requested, applied and adjustments). track master is the fader after all \
            tracks. Duck music under a voice-over by lowering its track; for a level that changes over time use edit_clip \
            volume_curve instead.
            """),
            MCPGuideSection(name: "hiding", about: "hiding a whole track from the preview and the export", text: """
            Hiding. hidden=true leaves the whole track out of the preview and the export without deleting it (not for master). \
            Track names are V1, V2… and A1, A2…, as in get_timeline.
            """)
        ],
        examples: [
            ["track": "A1", "volume_db": -12],
            ["track": "V2", "hidden": true]
        ],
        related: ["edit_clip", "get_timeline", "listen"]
    )

    static let splitClip = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.splitClip,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.splitClip, """
            split_clip cuts clips in two; each call is one undo step.
            """),
            MCPGuideSection(name: "where", about: "which clips are cut, and at what time", text: """
            Where. time is timeline seconds. Without clip_ids it cuts the V1 clip under that time; clip_ids cuts exactly those \
            clips at that time. A clip and its linked sound split into two linked pairs.
            """),
            MCPGuideSection(name: "results", about: "the new ids and removing a part", text: """
            Results. It returns the ids of the new right-hand pieces. To remove a part, split it out and delete it with \
            delete_items (ripple=true closes the gap on V1).
            """)
        ],
        examples: [
            ["time": 12.5],
            ["time": 30, "clip_ids": ["c1", "a1"]]
        ],
        related: ["delete_items", "edit_clip", "freeze_frame"]
    )

    static let deleteItems = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.deleteItems,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.deleteItems, """
            delete_items removes items from the timeline; each call is one undo step.
            """),
            MCPGuideSection(name: "what", about: "which ids can be deleted together", text: """
            What. ids can mix clips, texts, shapes, filters and subtitle lines (ids from get_timeline and get_subtitles). Media \
            files are never deleted; files are manage_files' job.
            """),
            MCPGuideSection(name: "ripple", about: "closing the gaps on V1", text: """
            Ripple. ripple=true closes the gaps this leaves on V1 by moving the later V1 clips left; without it the gaps stay.
            """),
            MCPGuideSection(name: "linkage", about: "what follows when Linkage is on", text: """
            Linkage. With Linkage on, what sits on deleted or moved V1 clips follows them: it is deleted with a deleted clip, \
            and a subtitle shrinks to the speech left under it and goes when less than half is left; music across clips stays. \
            With Linkage off, other tracks stay where they are.
            """)
        ],
        examples: [
            ["ids": ["c3", "t2"]],
            ["ids": ["c3"], "ripple": true]
        ],
        related: ["split_clip", "undo", "get_timeline"]
    )

    static let duplicateItems = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.duplicateItems,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.duplicateItems, """
            duplicate_items copies items; each call is one undo step.
            """),
            MCPGuideSection(name: "placement", about: "where the copies land", text: """
            Placement. The copies keep their spacing; the earliest lands at start (default: right after the last of them ends). \
            Landing works like paste: a clip that would overlap moves up to the next free video track (or another audio track), \
            groups keep their order, and linked audio comes along. track picks where a single group of clips goes (V1, V2… or \
            A1, A2…; the next number opens a new track).
            """),
            MCPGuideSection(name: "results", about: "the new ids", text: """
            Results. It returns the new ids; every copy is a new item, so edit the copies by those ids.
            """)
        ],
        examples: [
            ["ids": ["c2"]],
            ["ids": ["t1", "t2"], "start": 20]
        ],
        related: ["get_timeline", "add_clips"]
    )

    static let setTransition = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.setTransition,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.setTransition, """
            set_transition sets transitions between V1 clips; each call is one undo step.
            """),
            MCPGuideSection(name: "types", about: "the transition types and their length", text: """
            Types. type is crossFade, blackFade, whiteFade, pushLeft, pushRight, pushUp, pushDown, wipeLeft, wipeRight, wipeUp \
            or wipeDown; none removes it. duration is 0.1–3 seconds (default 0.5).
            """),
            MCPGuideSection(name: "where", about: "one cut or every cut, touching clips, handles", text: """
            Where. after_clip_id is the V1 clip before the cut; the two clips must touch. all=true applies it to every \
            touching pair on V1. A transition uses handles (media beyond the clips' ends); when there is not enough, it holds \
            the first or last frame, and a duration that does not fit is shortened.
            """),
            MCPGuideSection(name: "results", about: "what the result reports for each cut", text: """
            Results. For each cut it reports where the transition went, its real length and whether it was shortened or held \
            a frame.
            """)
        ],
        examples: [
            ["type": "crossFade", "after_clip_id": "c1"],
            ["type": "blackFade", "all": true, "duration": 0.8]
        ],
        related: ["get_timeline", "edit_clip"]
    )

    static let setCanvas = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.setCanvas,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.setCanvas, """
            set_canvas changes the output frame; each call is one undo step.
            """),
            MCPGuideSection(name: "shape", about: "ratios and what happens to the clips", text: """
            Shape. ratio is auto (follows the first V1 clip), 16:9, 9:16, 4:3, 3:4 or 1:1. 9:16 is for TikTok, Reels and \
            Shorts, 16:9 for YouTube. Clips keep their layout: to fill the new shape, reframe them with edit_clips fit=fill \
            (edit_clip's framing section explains how).
            """),
            MCPGuideSection(name: "frame_rate", about: "fps, and screen recordings", text: """
            Frame rate. fps is 24, 30 or 60. Screen recordings use the canvas fps, so it cannot change while one is recording.
            """)
        ],
        examples: [
            ["ratio": "9:16"],
            ["fps": 30]
        ],
        related: ["edit_clips", "edit_clip", "record_screen"]
    )
}
