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

            Add on-screen text (titles, captions, labels) or change one (text_id); omitted fields stay. Batch: set_texts. Position is \
            the block's centre: a named spot or x/y canvas fractions. Colours #RRGGBB or #RRGGBBAA. One undo step; clamped values \
            return requested/applied/adjustments.
            """),
            MCPGuideSection(name: "layout", about: "position, box_width, alignment, font_size, and the lines / block in the result", text: """
            Layout. position is a named spot (top, upper_third, center, lower_third, bottom) or x / y, the block's centre as canvas \
            fractions. Text wraps inside box_width (a fraction of the frame width, default 0.8); alignment sets the lines inside the \
            block. font_size is pixels on a 1080-pixel-high frame and scales with the canvas: on a 9:16 frame (1920 high) the same number \
            looks smaller relative to the width, so read the sizes a style gives for that shape. The result reports lines and block (left, \
            top, right, bottom as fractions) and warns when a word breaks in the middle or the block leaves the frame: make the text \
            smaller, the box wider or the words shorter, then look.
            """),
            MCPGuideSection(name: "style", about: "font, color, outline, shadow, background box, letter spacing", text: """
            Style. font is a family name installed on this Mac (for example PingFang SC, Helvetica Neue, Avenir Next); bold and italic; \
            color for the text; stroke_color and stroke_width for an outline ("none" removes it); shadow for a soft drop shadow; \
            background_color for a box behind the text ("none" removes it); letter_spacing adds pixels between letters (-20 to 80). \
            Colours are #RRGGBB or #RRGGBBAA.
            """),
            MCPGuideSection(name: "timing_animation", about: "start, duration, entrance and exit animations, emphasis, hidden", text: """
            Timing and animation. start is timeline seconds (default: the playhead), duration is seconds on screen (default 3, at least \
            0.2). animation_in and animation_out pick an entrance and exit (fade, rise, pop, typewriter, cascade, blur, focus, wipe, \
            strokeDraw); their durations default to 0.6 seconds and animation_intensity (0 to 1) sets how far they move. emphasis=breathe \
            adds a slow pulse while the text is on screen. hidden keeps the text but leaves it out of the preview and the export.
            """),
            MCPGuideSection(name: "numbers", about: "rolling numbers with number", text: """
            Rolling numbers. number shows a number rolling from one value to another instead of text (text is not needed): from, to, \
            decimals (0 to 4), prefix and suffix (for example "$" or " days"), thousands (commas, default true), seconds (how long it \
            rolls, default 1.5), delay (seconds before it starts) and style (count counts up, odometer spins each digit). Only the \
            fields you pass change; number.remove=true turns it back into plain text.
            """),
            // 出处：docs/architecture/motion-presets.md（三套的样子和时间照南极样片、一套 = 普通的字和形状 + 组的标记、换一套字不变、
            // hit_at 整套挪、标题挪了 / 改了字别的跟着走）。
            MCPGuideSection(name: "motion_presets", about: "motion_preset: ready-made animated titles and credits, hit_at, small_text, swapping and moving one", text: """
            Motion presets. motion_preset puts a ready-made animated title on the timeline in one call: ordinary texts and shapes \
            you can still change one by one afterwards (set_text, set_shape, delete_items). frame_reveal: a thin box draws around \
            the title, then lets go while the words stay (credits such as FROM / SKY STUDIO). focus_pull: thin wide-spaced words \
            pull into focus and blur away at the end (calm credits). title_counter: the title pops in, a short line draws under \
            it and a number rolls like a slot machine (needs number with at least to; suffix for units, e.g. " KM"). text is the \
            title; small_text is a small line above it ("" removes it), small_text_below=true puts it under (e.g. PRESENTS). hit_at is the \
            timeline second it lands on (a drum hit or a cut; default start, then the playhead); duration runs from hit_at to the \
            end (default 3, title_counter 3.5). x / y or position place the whole group; font and color change the title and the \
            small line. Sizes follow the frame's short side, so the same call works on 9:16. With text_id of any text in a group: \
            motion_preset swaps it for another preset and keeps the words; hit_at alone moves the whole group. Moving or retyping \
            the title brings the rest along. The result's motion_preset lists the ids of every piece; get_timeline marks them.
            """),
            MCPGuideSection(name: "pitfalls", about: "newlines, timeline rows and stacking, clamped font_size, batches with set_texts", text: """
            Pitfalls. A newline (or the two characters \\n) starts a new line. Each new text gets its own row on the timeline, and the row \
            order is the stacking order. font_size is clamped to 12 to 1000 and the result shows requested and applied. For many titles \
            use one set_texts call, not many set_text calls.
            """)
        ],
        examples: [
            ["text": "Day 1", "position": "lower_third", "font_size": 48],
            ["text_id": "t1", "number": ["from": 0, "to": 365, "style": "odometer"]],
            ["text": "SKY STUDIO", "small_text": "FROM", "motion_preset": "frame_reveal", "hit_at": 25.25],
            ["text": "POLE TO POLE", "motion_preset": "title_counter", "number": ["to": 20004, "suffix": " KM"], "hit_at": 58.79]
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
            // 2026-11-17 (MCP-2, MCP-4): an A-number past the last audio track is created; audio that does not fit on its track goes
            // on another new track; moves are adjustments (ai-control-mcp.md section 4 item 2, AITrackLanding).
            MCPGuideSection(name: "placement", about: "where items land: tracks, start, insert, new tracks, separate sound, subtitle files", text: """
            Where items land. Without start, video and images append to their track (default V1); audio without track starts at 0 \
            on the first free audio track. With start, overlapping video is lifted a track (or use new_video); insert=true on V1 \
            pushes later V1 clips right. Tracks: V1 main, V2+ video above it, A1+ audio; missing A-numbers are created (A1 to A7 in \
            one call, numbered without gaps). new_video and new_audio: one new track per call. Audio that does not fit on its track \
            goes on another new track, never on one with sound; moved items get a track entry in adjustments. sound=separate puts a \
            video's sound on a linked audio track (J/L cuts); sound=only adds just its sound. One subtitle file replaces the subtitles.
            """),
            // hit / hit_at for files and library music since 2026-11-18 (MCP-43; AIClipHit, ai-control-mcp.md section 4 item 43).
            MCPGuideSection(name: "music_sound_effects", about: "library_id from find_audio, sound effects made on this Mac, presets, hit_at and hit", text: """
            Music and sound effects. library_id is a track id from find_audio; SkyCut downloads it if needed, and export_video reports \
            the music_credits to pass on to the user. sound_effect makes a sound on this Mac (no download, no credits): preset is whoosh \
            (peak at 60%), swoosh (short, bright), suction (rises and stops dead; peak at the end), riser (builds; peak at the end), \
            downlifter (a low swell that falls), impact (long tail), boom (deep), hit, pop, click, tick, ding, sparkle (peak at the first \
            twinkle), beep, glitch or shutter; duration, pitch, brightness, size (dry to hall), variation (another take) and volume_db \
            (default -8) shape it. Without hit_at a made sound effect lands at the playhead. duration is the clip length (at least 0.1 \
            seconds); tails (impact, boom, riser) run past it: audible_duration says how long it is heard, end where the clip ends.
            Landing a hit. hit_at is the timeline second a hit lands on (a cut, a word appearing, a title), for a sound effect, music or \
            any file with sound: SkyCut sets the start from it (overriding start). hit is the source second that lands there ("second \
            9.66 of the music on 7.30"); without it, a made or library sound effect's loudest moment, and for a file or library music \
            its strongest accent between source_in and source_out (listen beats=true lists the accents and where the music stops by \
            itself). When the start would fall before 0:00, the clip starts later in its source instead, so the hit still lands on \
            hit_at. The reply gives hit_at and hit as placed. Images take start.
            """),
            MCPGuideSection(name: "windows", about: "source_in / source_out, image length, checks before inserting, what comes back", text: """
            Source windows. source_in and source_out are seconds inside the file (default: the whole file). For an image, source_out is \
            its display length (default 5 seconds) and must fit edit_limits.image_source_duration. Every window is checked before \
            anything is inserted (a failed call changes nothing); clamped values come back as requested, applied and adjustments, \
            with the new ids, hit_at and music credits. When a window crosses a cut inside the file itself (generated clips often switch shots), the result adds \
            source_cuts: the source_frame, how many frames of the other shot are in and a suggested_source_in or \
            suggested_source_out. It is only a reminder; nothing is changed. look shots=true lists every cut of a file.
            """),
            MCPGuideSection(name: "pitfalls", about: "relative paths, files outside the folder, narration recordings, changing clips afterwards", text: """
            Pitfalls. Relative paths are relative to the folder opened with open_folder. Files outside that folder ask once \
            (needs_confirmation) and the folder is remembered after the user agrees. Existing narration recordings are added with \
            add_clips; add_voiceover is only for narration spoken from text. To change a clip after adding it, use edit_clip with the \
            returned id.
            """)
        ],
        examples: [
            ["clips": [["file": "intro.mp4"], ["file": "music.m4a", "track": "A1", "start": 0]]],
            ["clips": [["sound_effect": ["preset": "whoosh"], "hit_at": 4.2]]],
            ["clips": [["file": "music.mp3", "track": "A1", "hit": 9.66, "hit_at": 7.3]]]
        ],
        related: ["find_audio", "edit_clip", "conventions"]
    )
}
