import Foundation

// MARK: - 说明书：edit_clip 的主题（试点，2026-11-10）
//
// 管什么：edit_clip 名片写短之后，长话放在这里 —— 裁切和变速、取景（9:16、region）、位置大小、声音、动画和标记、换文件、结果和限制、坑。
// 出处：docs/architecture/ai-control-mcp.md 第四节第 2 条（给绝对值：改入点时起点不动）、第 11 条（画面怎么放：铺满 / 完整显示 / 位置大小 /
// 去黑边 / 对准主体 / region）、docs/architecture/mcp-edit-parameters.md（先全验、越界给合法值、requested / applied）、
// docs/architecture/sound-scenes.md、docs/architecture/audio-volume-curve.md、docs/bugfixes/2026-10-16-edit-clip-trim-semantics-undocumented.md、
// docs/bugfixes/2026-11-03-mcp-usage-guidance.md（没有 end）。只写英文（方案第八节第 7 条）。
// 不管什么：参数一行一行的类型和范围（fields 几节自动生成）、迁移了哪些工具（MCPGuideWrittenTopics）。

enum MCPGuideEditClipTopic {
    static let previousCard = "Edit one clip; edit_clips batches the same fields. region={x,y,width,height} selects the upright source rectangle "
        + "(0–1, top-left): fit=fit (default) shows it whole; fit=fill fills canvas. No crop, focus/follow or manual transforms with region. "
        + "Returns regions/transform and requested/applied/adjustments. Invalid values fail atomically with allowed/suggested; edit_limits "
        + "gives ranges. Trim: the timeline start stays fixed, the end moves (pass start too to keep the end). Overlaps fail; ripple shifts "
        + "later V1 clips. Otherwise fit uses the whole source or crop/remove_black_bars; fill aims at faces, people, text, then salient "
        + "objects, following unless follow=false. Animated position/scale blocks static placement. Never edits the file."

    static let written = MCPGuideWrittenTopics.Written(
        previousCard: previousCard,
        sections: [
            MCPGuideWrittenTopics.overview(previousCard, """
            edit_clip changes one clip already on the timeline (clip_id from get_timeline); add new clips with add_clips and change many \
            at once with edit_clips (same fields, one undo step). Each call is one undo step and never edits the media file.
            """),
            MCPGuideSection(name: "trim_speed", text: """
            Trimming and speed. source_in and source_out are seconds inside the media file, not timeline seconds. Changing source_in keeps \
            the clip's timeline start and moves its end; pass start too to keep the end where it was. Changing source_out moves the end. \
            This differs from dragging a trim handle in the editor on purpose: you give absolute values. For a still image, source_out is \
            its display length and must fit edit_limits.image_source_duration. speed sets playback speed (1 = normal) within \
            edit_limits.speed; a value outside fails. ripple=true on a V1 clip moves the later V1 clips by the same amount its end moved. \
            alone=true leaves linked clips (the separated sound or picture of a J/L cut) as they are, for example to trim one side of a \
            J/L cut. Clips with keyframes: keyframes=keep_frames (default) keeps the motion on its source frames, stretch re-times it to \
            the new window, clear removes it.
            """),
            MCPGuideSection(name: "framing", text: """
            Framing for the canvas shape (for example after set_canvas ratio=9:16). fit=fill covers the whole frame: SkyCut takes a window \
            of the source with the canvas shape and maps it onto the canvas, cropping up to 0.45 per side and then scaling and moving the \
            picture. It aims at faces, then people, then text (slides, screen recordings), then the most salient object, and follows a \
            moving subject with position keyframes unless follow=false (it jumps at shot changes). focus=text aims at text, focus=center \
            skips detection, focus_x / focus_y give the point yourself (0–1 on the source). fit=fit shows the whole picture (or the crop). \
            remove_black_bars detects letterbox or pillarbox bars and frames inside them. crop removes source edges (fractions per side, \
            up to edit_limits.crop); all 0 resets.

            region={x,y,width,height} selects an upright source rectangle (0–1 from the top-left, at least 2 pixels per side). fit=fit \
            (default) shows the rectangle whole; fit=fill centres it and fills the canvas. region replaces crop and placement and may go \
            past the usual crop limit. It cannot be combined with crop, focus or follow, or manual x / y / scale / rotation; clear a \
            rotation and any motion entrance or exit first. Results report the regions and the final transform.
            """),
            MCPGuideSection(name: "placement", text: """
            Position and size. x and y are the picture's centre on the canvas (0 left / top, 1 right / bottom); a zoomed-in picture can be \
            centred from -2 to 3 so its own edges reach the canvas edges. scale is the size relative to the default fit (1 = the cropped \
            picture fits the canvas), 0.05 to 6. Changing only the crop keeps the centre and size and never stretches the picture. \
            rotation turns it clockwise in degrees (-360 to 360), opacity is 0 to 1, flip_horizontal and flip_vertical mirror it. \
            A clip with position or scale keyframes refuses static placement: remove the keyframes with set_keyframes first.
            """),
            MCPGuideSection(name: "sound", text: """
            Sound. volume_db sets the clip's level in dB (0 = original), clamped to edit_limits.volume_db; on a clip with a volume_curve \
            it shifts the whole curve and reports saturation. volume_curve replaces the whole curve with points in timeline seconds and \
            dB ([] removes it), joined by straight lines. fade_in and fade_out are audio fades in seconds. muted silences the clip. \
            sound_scene puts the voice in a speaker (telephone, megaphone or radio: set distortion and tone) or a place (room, bathroom, \
            hall, outdoor, forest or valley: set room_size and distance); intensity is how much of the effect, all 0 to 1; kind=none \
            removes it.
            """),
            MCPGuideSection(name: "animation_markers", text: """
            Entrance, exit, markers and hiding. entrance and exit are none, fade, rise, pop, zoom or wipe; entrance_duration and \
            exit_duration are seconds (default 0.6 when one is chosen); animation_intensity (0 to 1, default 0.6) is how far rise, pop and \
            zoom move. A V1 transition replaces the entrance or exit on its edge. markers replaces all of the clip's markers with \
            {time (timeline seconds inside the clip), color, note}; [] removes them. hidden keeps the clip but leaves it out of the \
            preview and the export.
            """),
            MCPGuideSection(name: "file_swap", text: """
            Swapping the media. file replaces the clip's media but keeps its place on the timeline, its length and its settings; \
            source_in then starts inside the new file (default 0). Use it for a better take or a re-exported file. SkyCut never edits the \
            media file itself.
            """),
            MCPGuideSection(name: "results_limits", text: """
            Results and limits. All values are checked before anything changes: an invalid value fails the whole call with the allowed or \
            suggested values, and get_timeline reports edit_limits (crop, speed, scale, volume_db, image_source_duration and more). Values \
            that are clamped come back as requested, applied and adjustments. Overlapping another clip on the same track fails. With \
            linkage on, texts, shapes, audio and subtitles over a V1 clip move with it; the result reports linkage and magnet.
            """),
            MCPGuideSection(name: "pitfalls", text: """
            Pitfalls. source_in and source_out are file seconds: to cut a clip at a timeline second, use split_clip. There is no end \
            parameter: shorten a clip with source_out or with split_clip and delete_items. Changing source_in moves the clip's end, not \
            its start. fit, region, x / y and scale fail on a clip with position or scale keyframes until those keyframes are removed.
            """)
        ],
        examples: [
            ["clip_id": "c1", "source_in": 2.5, "source_out": 8],
            ["clip_id": "c1", "fit": "fill", "focus": "subject"],
            ["clip_id": "c1", "region": ["x": 0.1, "y": 0.2, "width": 0.5, "height": 0.6], "fit": "fill"]
        ],
        related: ["edit_clips", "split_clip", "set_keyframes", "conventions"]
    )
}
