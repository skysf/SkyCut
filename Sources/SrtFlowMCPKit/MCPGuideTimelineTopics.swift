import Foundation

// MARK: - 说明书：set_text、add_clips 的主题（试点，2026-11-10）
//
// 管什么：两个工具名片写短之后的长话：set_text 的排版、样式、时间和动画、滚动的数字、坑；add_clips 放在哪、曲库和合成音效、源时间和
// 静帧长度、坑。
// 出处：docs/architecture/ai-control-mcp.md 第四节第 2 条（放素材走手动那条路、撞上往上抬、同一次两段都要新开一条轨）、第 8 条
// （set_text 按成片排版、回 lines / block、折断和出画面的提示）、第 20、23、43 条（文字的零件、曲库与署名、合成音效的落点）、
// docs/architecture/text-overlays.md、docs/architecture/sound-effect-synth.md、docs/plans/2026-09-22-media-file-drop.md。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideTimelineTopics {
    // MARK: set_text

    static let setTextPreviousCard = "Add text, or edit text_id; omitted fields stay. Position is the block's centre, named or x/y canvas fractions. "
        + "Sizes use a 1080-high frame; colours #RRGGBB or #RRGGBBAA. Text wraps in box_width. Native clamping returns requested/applied/adjustments."

    static let setText = MCPGuideWrittenTopics.Written(
        previousCard: setTextPreviousCard,
        sections: [
            MCPGuideWrittenTopics.overview(setTextPreviousCard, """
            set_text adds one text on screen (a title, caption or label) or changes one (text_id from get_timeline). Change many texts in \
            one call with set_texts. Each call is one undo step.
            """),
            MCPGuideSection(name: "layout", text: """
            Layout. position is a named spot (top, upper_third, center, lower_third, bottom) or x / y, the block's centre as canvas \
            fractions. Text wraps inside box_width (a fraction of the frame width, default 0.8); alignment sets the lines inside the \
            block. font_size is pixels on a 1080-pixel-high frame and scales with the canvas: on a 9:16 frame (1920 high) the same number \
            looks smaller relative to the width, so read the sizes a style gives for that shape. The result reports lines and block (left, \
            top, right, bottom as fractions) and warns when a word breaks in the middle or the block leaves the frame: make the text \
            smaller, the box wider or the words shorter, then look.
            """),
            MCPGuideSection(name: "style", text: """
            Style. font is a family name installed on this Mac (for example PingFang SC, Helvetica Neue, Avenir Next); bold and italic; \
            color for the text; stroke_color and stroke_width for an outline ("none" removes it); shadow for a soft drop shadow; \
            background_color for a box behind the text ("none" removes it); letter_spacing adds pixels between letters (-20 to 80). \
            Colours are #RRGGBB or #RRGGBBAA.
            """),
            MCPGuideSection(name: "timing_animation", text: """
            Timing and animation. start is timeline seconds (default: the playhead), duration is seconds on screen (default 3, at least \
            0.2). animation_in and animation_out pick an entrance and exit (fade, rise, pop, typewriter, cascade, blur, focus, wipe, \
            strokeDraw); their durations default to 0.6 seconds and animation_intensity (0 to 1) sets how far they move. emphasis=breathe \
            adds a slow pulse while the text is on screen. hidden keeps the text but leaves it out of the preview and the export.
            """),
            MCPGuideSection(name: "numbers", text: """
            Rolling numbers. number shows a number rolling from one value to another instead of text (text is not needed): from, to, \
            decimals (0 to 4), prefix and suffix (for example "$" or " days"), thousands (commas, default true), seconds (how long it \
            rolls, default 1.5), delay (seconds before it starts) and style (count counts up, odometer spins each digit). Only the \
            fields you pass change; number.remove=true turns it back into plain text.
            """),
            MCPGuideSection(name: "pitfalls", text: """
            Pitfalls. A newline (or the two characters \\n) starts a new line. Each new text gets its own row on the timeline, and the row \
            order is the stacking order. font_size is clamped to 12 to 1000 and the result shows requested and applied. For many titles \
            use one set_texts call, not many set_text calls.
            """)
        ],
        examples: [
            ["text": "Day 1", "position": "lower_third", "font_size": 48],
            ["text_id": "t1", "number": ["from": 0, "to": 365, "style": "odometer"]]
        ],
        related: ["set_texts", "conventions", "recipes"]
    )

    // MARK: add_clips

    static let addClipsPreviousCard = "Add files, library audio (find_audio) or locally generated sound_effects in order. Each item supplies one source, "
        + "source_in/out, track and start; effects may use hit_at to place their loudest moment. Video/images append on their track (default V1); "
        + "audio starts at 0 on the first free audio track. Overlapping video lifts a track; insert=true pushes later V1 clips. One subtitle file "
        + "replaces the current subtitle track. External-file approval follows permission mode. All windows validate before insertion. Returns ids, "
        + "requested/applied/adjustments, hit_at and music credits."

    static let addClips = MCPGuideWrittenTopics.Written(
        previousCard: addClipsPreviousCard,
        sections: [
            MCPGuideWrittenTopics.overview(addClipsPreviousCard, """
            add_clips is the only way to put media on the timeline: files the user gave you or SkyCut made (generate_media results, \
            recordings), music and sound effects from find_audio, and sound effects made on this Mac. The whole call is one undo step.
            """),
            MCPGuideSection(name: "placement", text: """
            Where items land. Without start, video and images append to the end of their track (default V1); audio starts at 0 on the \
            first free audio track. With start, a video that would overlap is lifted to the track above (or track=new_video); insert=true \
            on V1 pushes the later V1 clips right instead. track names: V1 main, V2 and up for video above it, A1 and up for audio; \
            new_video and new_audio create a track, and two items in one call that both ask for a new track share the first one. \
            sound=separate also puts a video's sound on its own audio track, linked to the muted picture (for J/L cuts); sound=only \
            adds just its sound. One subtitle file (.srt, .vtt…) replaces the current subtitle track.
            """),
            MCPGuideSection(name: "music_sound_effects", text: """
            Music and sound effects. library_id is a track id from find_audio; SkyCut downloads it if needed, and export_video reports \
            the music_credits to pass on to the user. sound_effect makes a sound on this Mac (no download, no credits): preset is whoosh \
            (peak at 60%), swoosh (short, bright), suction (rises and stops dead; peak at the end), riser (builds; peak at the end), \
            downlifter (a low swell that falls), impact (long tail), boom (deep), hit, pop, click, tick, ding, sparkle (peak at the first \
            twinkle), beep, glitch or shutter; duration, pitch, brightness, size (dry to hall), variation (another take) and volume_db \
            (default -8) shape it. hit_at, for a made or a library sound effect, is the timeline second where its loudest moment lands \
            (a cut, a word appearing): SkyCut sets the start from it (overriding start); without it a made sound effect lands at the \
            playhead.
            """),
            MCPGuideSection(name: "windows", text: """
            Source windows. source_in and source_out are seconds inside the file (default: the whole file). For an image, source_out is \
            its display length (default 5 seconds) and must fit edit_limits.image_source_duration. Every window is checked before \
            anything is inserted; clamped values come back as requested, applied and adjustments, with the new ids, hit_at and music \
            credits.
            """),
            MCPGuideSection(name: "pitfalls", text: """
            Pitfalls. Relative paths are relative to the folder opened with open_folder. Files outside that folder ask once \
            (needs_confirmation) and the folder is remembered after the user agrees. Existing narration recordings are added with \
            add_clips; add_voiceover is only for narration spoken from text. To change a clip after adding it, use edit_clip with the \
            returned id.
            """)
        ],
        examples: [
            ["clips": [["file": "intro.mp4"], ["file": "music.m4a", "track": "A1", "start": 0]]],
            ["clips": [["sound_effect": ["preset": "whoosh"], "hit_at": 4.2]]]
        ],
        related: ["find_audio", "edit_clip", "conventions"]
    )
}
