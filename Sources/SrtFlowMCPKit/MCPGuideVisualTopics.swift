import Foundation

// MARK: - 说明书：画面上的形状、关键帧、调色、定格（第一批，2026-11-10）
//
// 管什么：set_shape、set_keyframes、set_filter、freeze_frame 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCards）、docs/architecture/shapes.md（种类、动画只给画出来的形状）、
// cover-blur-mosaic.md（盖一块、text_scan 的 cover）、keyframe-animation.md（缓动、relative、挡住 edit_clip 的摆放）、
// filters.md（纯黑不抬）、freeze-frame.md（不到一帧的尾巴、tail_id）、official-film.md（source_frame 的证据）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideVisualTopics {
    static let setShape = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.setShape,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.setShape, """
            set_shape adds or changes one shape on the timeline; each call is one undo step.
            """),
            MCPGuideSection(name: "kinds", about: "lines, rectangles, squares, circles, arcs, blur and mosaic", text: """
            Kinds. kind (required when adding) is line, rectangle, square, circle, arc, blur or mosaic. Drawn shapes use color \
            (#RRGGBB or #RRGGBBAA) and line_width in pixels on a 1080-high frame (default 6); filled=true makes rectangles, \
            squares and circles solid. An arc starts at rotation degrees clockwise from 12 o'clock and covers sweep degrees \
            (default 270). blur and mosaic hide the picture beneath; strength is pixels on a 1080-high frame (blur 28, mosaic \
            22), and look text_scan gives cover boxes for burned-in subtitles and watermarks.
            """),
            MCPGuideSection(name: "placement", about: "position, size, rotation, timing, hiding, changing and deleting", text: """
            Placement. x and y are the centre as frame fractions; width and height are frame fractions (0.02–1), and square, \
            circle and arc use width for both. rotation turns a line (±90) or sets where an arc starts. start (default: the \
            playhead) and duration (default 3) set its time; hidden keeps it but leaves it out of the preview and the export. \
            Shapes sit under texts. shape_id changes an existing shape and only the passed fields change; delete it with \
            delete_items.
            """),
            MCPGuideSection(name: "animation", about: "entrance and exit animations for drawn shapes", text: """
            Animation. animation_in is none, fade, pop, wipe or draw (draw traces the outline from its start; a solid shape fills \
            in that way); animation_out plays the entrance backwards; both last 0.6 s unless their durations say otherwise. \
            Animations apply to drawn shapes only, not to blur or mosaic.
            """),
            MCPGuideSection(name: "results", about: "clamped values and the undo step", text: """
            Results. One undo step. Values outside the limits are clamped and come back as requested, applied and adjustments.
            """)
        ],
        examples: [
            ["kind": "rectangle", "x": 0.5, "y": 0.5, "width": 0.4, "height": 0.2],
            ["kind": "blur", "x": 0.85, "y": 0.08, "width": 0.2, "height": 0.08]
        ],
        related: ["look", "delete_items", "set_shapes"]
    )

    static let setKeyframes = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.setKeyframes,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.setKeyframes, """
            set_keyframes animates one clip; each call is one undo step.
            """),
            MCPGuideSection(name: "keys", about: "position, scale, rotation and opacity lists, and what replacing means", text: """
            Keys. position takes {time, x, y} (the centre, 0–1 on the frame; -2 to 3 for a picture bigger than the frame), scale \
            {time, value} (1 = the default fit, 0.02–8), rotation {time, degrees} clockwise, opacity {time, value} (0 invisible, \
            1 solid). Each list replaces that property's keys; [] removes them and keeps the static value. Properties you leave \
            out keep their keys.
            """),
            MCPGuideSection(name: "time_easing", about: "timeline seconds or relative 0–1, and the easing curves", text: """
            Time and easing. Times are timeline seconds inside the clip, or fractions 0–1 of the clip with relative=true. easing \
            applies to every move: easeInOut (default), easeIn, easeOut, linear (constant speed), snap (fast, then settles), \
            overshoot (past it, then back) or spring (bounces). A slow zoom: relative=true, scale [{time:0,value:1}, \
            {time:1,value:1.15}].
            """),
            MCPGuideSection(name: "interactions", about: "keys that block edit_clip placement, trims, clamping", text: """
            Interactions. Position or scale keys block edit_clip fit, x, y and scale until you remove them. After a trim, \
            edit_clip keyframes decides whether keys keep their frames, stretch or clear. Values are clamped to the runtime \
            keyframe_scale limits and points that land on the same time are merged; the result returns requested, applied and \
            adjustments.
            """)
        ],
        examples: [
            ["clip_id": "c1", "relative": true, "scale": [["time": 0, "value": 1], ["time": 1, "value": 1.15]]]
        ],
        related: ["edit_clip", "get_timeline"]
    )

    static let setFilter = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.setFilter,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.setFilter, """
            set_filter grades the picture over a time range; each call is one undo step.
            """),
            MCPGuideSection(name: "presets", about: "the ten looks and what each is for", text: """
            Presets. tealOrange (blockbuster teal shadows, warm skin), coldIron (cold, desaturated, hard, industrial), warmSun \
            (warm golden daylight), flatGrey (flat low-saturation documentary), nightGold (night with amber highlights, deep \
            blacks), fadedFilm (old faded film, lifted blacks), coldWhite (bright clean cool whites: products, interiors), \
            mistBlue (misty morning blue, low contrast), inkShadow (hard black and white), neon (cyberpunk magenta and cyan, full \
            saturation). Pure black stays black under every preset.
            """),
            MCPGuideSection(name: "range", about: "the time range, strength, what it covers, changing and hiding", text: """
            Range and strength. start (default: the playhead) and duration (default 3 s) set the range; strength is 0–1 (default \
            1). It grades every video track in that range, not texts or subtitles. filter_id changes an existing filter and only \
            the passed fields change; hidden keeps it but leaves it out of the preview and the export; delete it with \
            delete_items.
            """)
        ],
        examples: [["preset": "tealOrange", "start": 0, "duration": 10]],
        related: ["delete_items", "recipes"]
    )

    static let freezeFrame = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.freezeFrame,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.freezeFrame, """
            freeze_frame holds one frame as a still; each call is one undo step.
            """),
            MCPGuideSection(name: "holding", about: "which clip and frame, how long, and what moves", text: """
            Holding. time is the timeline time of the frame; clip_id picks the clip (default: the V1 clip at that time). \
            duration is 0.2–60 seconds (default 2). Later clips on that track move right; with Linkage on, content linked to the \
            clip follows; with Linkage off, other tracks stay. The frame is saved as a PNG next to the project.
            """),
            MCPGuideSection(name: "limits", about: "what cannot be frozen, and the tail after the last frame", text: """
            Limits. It refuses audio, images, hidden clips and V1 transitions. At the last used frame a remainder shorter than \
            one frame is dropped; a longer tail resumes after the hold, and the result names it tail_id.
            """),
            MCPGuideSection(name: "evidence", about: "source_frame details used by the official film flow", text: """
            Source evidence. source_frame reports the native requested and actual CMTime, the half-open used source window and \
            the source and PNG identities. It describes the upright_source frame, not composed pixels; incomplete or \
            out-of-window evidence cannot be a production anchor.
            """)
        ],
        examples: [["time": 12.5, "duration": 2]],
        related: ["split_clip", "get_timeline"]
    )
}
