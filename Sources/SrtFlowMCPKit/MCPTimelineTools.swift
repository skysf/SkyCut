import Foundation

// MARK: - 工具说明：时间线（读、放素材、改片段、切、删、转场、文字、滤镜、画面比例）
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPTimelineTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .getTimeline:
            return MCPToolDefinition(
                .getTimeline, title: "Read the timeline",
                description: """
                Read all tracks, clips, texts, shapes and subtitles with ids, timing, settings, canvas and frame rate. \
                edit_limits gives native ranges and reject/clamp policies. Read before editing for fresh ids; music_credits lists library music.
                """,
                readOnly: true
            )
        case .addClips:
            return addClips
        case .editClip:
            return editClip
        case .setKeyframes:
            return MCPToolDefinition(
                .setKeyframes, title: "Keyframes",
                description: """
                Animate position (centre x/y), scale (1 = default fit), rotation and opacity. Each list replaces that property's \
                keys; [] removes them, keeping static values. Times are timeline seconds within the clip, or fractions 0–1 \
                with relative=true. Default easing: easeInOut. Slow zoom: relative=true, scale [{time:0,value:1},{time:1,value:1.15}]. \
                Position/scale keys block edit_clip fit/x/y/scale. Returns requested/applied/adjustments for native clamping and merged points.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("Clip id from get_timeline."),
                    "relative": MCPSchema.boolean("Times are fractions 0–1 of the clip instead of seconds."),
                    "easing": MCPSchema.string("Curve of every move: easeInOut (default), easeIn, easeOut, linear (constant speed), snap (fast, then settles), overshoot (past it, back), spring (bounces).", oneOf: MCPVocabulary.keyframeEasings),
                    "position": MCPSchema.array(of: MCPSchema.object([
                        "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                        "x": MCPSchema.number("Centre across, 0–1 on the frame (-2…3 for a picture bigger than the frame).", minimum: MCPFramingLimits.center.lowerBound, maximum: MCPFramingLimits.center.upperBound),
                        "y": MCPSchema.number("Centre down, same range.", minimum: MCPFramingLimits.center.lowerBound, maximum: MCPFramingLimits.center.upperBound)
                    ], required: ["time", "x", "y"]), "Position."),
                    "scale": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                    "value": MCPSchema.number("Size, 1 = fits; clamps to runtime keyframe_scale limits.", minimum: MCPFramingLimits.keyframeScale.lowerBound, maximum: MCPFramingLimits.keyframeScale.upperBound)
                ], required: ["time", "value"]), "Scale."),
                    "rotation": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                    "degrees": MCPSchema.number("Clockwise degrees.")
                ], required: ["time", "degrees"]), "Rotation."),
                    "opacity": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds.", minimum: 0),
                    "value": MCPSchema.number("0 = invisible, 1 = solid.")
                ], required: ["time", "value"]), "Opacity.")
                ], required: ["clip_id"])
            )
        case .setTrack:
            return MCPToolDefinition(
                .setTrack, title: "Track settings",
                description: """
                Change a whole track: its fader (volume_db, on top of each clip's own volume) and whether it is \
                hidden (left out \
                of the preview and the export). track "master" is the fader after all tracks. Use it to duck music under a \
                voice-over or mute a whole track.
                """,
                input: MCPSchema.object([
                    "track": MCPSchema.string("V1, V2… / A1, A2…, or master."),
                    "volume_db": MCPSchema.number("Fader dB; clamps to edit_limits.volume_db. Returns requested/applied/adjustments."),
                    "hidden": MCPSchema.boolean("Hide or show the whole track (not for master).")
                ], required: ["track"])
            )
        case .splitClip:
            return MCPToolDefinition(
                .splitClip, title: "Split clips",
                description: """
                Cut clips in two at a timeline time. Without clip_ids it cuts the V1 clip under that time. \
                Returns the ids of the new right-hand pieces.
                """,
                input: MCPSchema.object([
                    "time": MCPSchema.number("Timeline time in seconds where to cut.", minimum: 0),
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "Only cut these clips.")
                ], required: ["time"])
            )
        case .freezeFrame:
            return MCPToolDefinition(
                .freezeFrame, title: "Freeze frame",
                description: """
                Hold the picture: the clip is cut at that moment and a still of that frame is inserted for duration \
                seconds (default 2); later clips on the same track move right by that much (Linkage on: what sits on them \
                follows; off: other tracks stay). Without clip_id it freezes the V1 clip at that time. Not for \
                audio, images, hidden clips, or a moment \
                inside a V1 transition. The still is a PNG next to the project. To end on a clip's last frame, give a time \
                inside that frame: a leftover shorter than one frame is dropped, a longer one keeps playing after the still \
                (tail_id in the result).
                """,
                input: MCPSchema.object([
                    "time": MCPSchema.number("Timeline time of the frame to hold.", minimum: 0),
                    "clip_id": MCPSchema.string("The clip to freeze (default: the V1 clip at that time)."),
                    "duration": MCPSchema.number("Seconds to hold (default 2).", minimum: 0.2, maximum: 60)
                ], required: ["time"])
            )
        case .deleteItems:
            return MCPToolDefinition(
                .deleteItems, title: "Delete",
                description: """
                Delete clips, texts, filters or subtitle lines by id; kinds can be mixed. ripple=true closes the gaps this \
                leaves on V1 by moving the later V1 clips left. Linkage on: what sits on deleted or moved V1 clips follows \
                (a subtitle shrinks to the speech left under it, and goes when less than half is left); off: other tracks stay.
                """,
                input: MCPSchema.object([
                    "ids": MCPSchema.array(of: MCPSchema.string("Id from get_timeline or get_subtitles."), "What to delete.", minItems: 1),
                    "ripple": MCPSchema.boolean("Close the gaps left on V1.")
                ], required: ["ids"]),
                destructive: true
            )
        case .duplicateItems:
            return MCPToolDefinition(
                .duplicateItems, title: "Duplicate",
                description: """
                Copy clips, texts, shapes, filters or subtitle lines (ids can be mixed) and place the copies with the same \
                spacing, the earliest at start (default: right after the last of them ends). Landing works like \
                paste: a clip \
                that would overlap goes up to the next free video track (or another audio track), groups keep their order, \
                linked audio comes along. track picks where a single group of clips goes. Returns the new ids.
                """,
                input: MCPSchema.object([
                    "ids": MCPSchema.array(of: MCPSchema.string("Id from get_timeline or get_subtitles."), "What to copy.", minItems: 1),
                    "start": MCPSchema.number("Timeline time for the earliest copy.", minimum: 0),
                    "track": MCPSchema.string("V1, V2… or A1, A2… (the next number opens a new track): where the copied clips should go.")
                ], required: ["ids"])
            )
        case .setTransition:
            return MCPToolDefinition(
                .setTransition, title: "Set a transition",
                description: """
                Set the transition between a V1 clip and the V1 clip right after it; the two must touch. \
                type none removes it. all=true applies it to every touching pair on V1.
                """,
                input: MCPSchema.object([
                    "after_clip_id": MCPSchema.string("The V1 clip before the cut."),
                    "all": MCPSchema.boolean("Apply to every touching pair of V1 clips."),
                    "type": MCPSchema.string("Transition.", oneOf: MCPVocabulary.transitions),
                    "duration": MCPSchema.number("Seconds (default 0.5).", minimum: 0.1, maximum: 3)
                ], required: ["type"])
            )
        case .setText:
            return setText
        case .setShape:
            return MCPToolDefinition(
                .setShape, title: "Shape",
                description: """
                Add a line, rectangle, square, circle, arc, blur or mosaic, or edit shape_id; only passed fields change. \
                x/y and width/height are frame fractions; square/circle/arc use width for both. Rotation turns a line, or \
                starts an arc clockwise from 12 o'clock (sweep = extent). Shapes sit under texts. blur/mosaic hide the \
                picture beneath; look text_scan supplies cover boxes. Sizes/strength use a 1080-high frame. Animations \
                apply to drawn shapes only. Native clamping returns requested/applied/adjustments; delete with delete_items.
                """,
                input: MCPSchema.object([
                    "shape_id": MCPSchema.string("Change this shape instead of adding one."),
                    "kind": MCPSchema.string("Shape (required when adding).", oneOf: ["line", "rectangle", "square", "circle", "arc", "blur", "mosaic"]),
                    "start": MCPSchema.number("Timeline start in seconds (default: the playhead).", minimum: 0),
                    "duration": MCPSchema.number("Seconds on screen (default 3).", minimum: 0.2),
                    "x": MCPSchema.number("Horizontal centre, 0–1.", minimum: 0, maximum: 1),
                    "y": MCPSchema.number("Vertical centre, 0–1.", minimum: 0, maximum: 1),
                    "width": MCPSchema.number("Width (or a line's length) as a fraction of the frame.", minimum: 0.02, maximum: 1),
                    "height": MCPSchema.number("Rectangle height as a fraction of the frame.", minimum: 0.02, maximum: 1),
                    "rotation": MCPSchema.number("Clockwise degrees: a line's angle (±90), or where an arc starts from 12 o'clock.", minimum: -360, maximum: 360),
                    "sweep": MCPSchema.number("Arcs only: degrees the arc covers, clockwise (default 270).", minimum: 1, maximum: 359),
                    "color": MCPSchema.string("#RRGGBB or #RRGGBBAA."),
                    "line_width": MCPSchema.number("Pixels on a 1080-high frame (default 6).", minimum: 1, maximum: 24),
                    "strength": MCPSchema.number("blur/mosaic only, pixels on a 1080-high frame (blur 28, mosaic 22).", minimum: 2, maximum: 80),
                    "filled": MCPSchema.boolean("Rectangles, squares and circles: solid instead of an outline."),
                    "animation_in": MCPSchema.string("Entrance; draw traces the outline from its start (a solid shape fills in that way).", oneOf: MCPVocabulary.shapeAnimations),
                    "animation_out": MCPSchema.string("Exit: the entrance played backwards.", oneOf: MCPVocabulary.shapeAnimations),
                    "animation_in_duration": MCPSchema.number("Entrance seconds (default 0.6).", minimum: 0.1, maximum: 5),
                    "animation_out_duration": MCPSchema.number("Exit seconds (default 0.6).", minimum: 0.1, maximum: 5),
                    "hidden": MCPSchema.boolean("Hide it without deleting it.")
                ])
            )
        case .setFilter:
            return MCPToolDefinition(
                .setFilter, title: "Filter",
                description: """
                Add a colour filter over a time range (it grades every video track there, not texts or subtitles), \
                or change one \
                when filter_id is given; only the fields you pass change. Presets: tealOrange (blockbuster teal \
                shadows, warm \
                skin), coldIron (cold, desaturated, hard, industrial), warmSun (warm golden daylight), flatGrey (flat \
                low-saturation documentary), nightGold (night with amber highlights, deep blacks), fadedFilm (old \
                faded film, \
                lifted blacks), coldWhite (bright clean cool whites: products, interiors), mistBlue (misty morning \
                blue, low \
                contrast), inkShadow (hard black and white), neon (cyberpunk magenta and cyan, full saturation).
                """,
                input: MCPSchema.object([
                    "filter_id": MCPSchema.string("Change this filter instead of adding one."),
                    "preset": MCPSchema.string("Look.", oneOf: MCPVocabulary.filterPresetIDs),
                    "start": MCPSchema.number("Timeline start in seconds (default: the playhead).", minimum: 0),
                    "duration": MCPSchema.number("Seconds (default 3).", minimum: 0.1),
                    "strength": MCPSchema.number("0 to 1 (default 1).", minimum: 0, maximum: 1),
                    "hidden": MCPSchema.boolean("Hide it without deleting it.")
                ])
            )
        case .setCanvas:
            return MCPToolDefinition(
                .setCanvas, title: "Canvas",
                description: """
                Set the output frame shape and/or frame rate. auto follows the first V1 clip; \
                9:16 is for TikTok, Reels and Shorts; 16:9 for YouTube. Clips keep their layout: to fill a new shape, \
                call edit_clip fit=fill on each clip.
                """,
                input: MCPSchema.object([
                    "ratio": MCPSchema.string("Frame shape.", oneOf: MCPVocabulary.canvasRatios),
                    "fps": MCPSchema.integer("Frames per second: 24, 30 or 60.", minimum: 24, maximum: 60)
                ])
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    private static var addClips: MCPToolDefinition {
        let soundEffect = MCPSchema.object([
            "preset": MCPSchema.string(
                "whoosh (hit at 60%), swoosh (short, bright), suction (rises, stops dead: hit = end), riser (builds: hit = end), " +
                    "downlifter (low swell, falls), impact (long tail), boom (deep), hit, pop, click, tick, ding, " +
                    "sparkle (hit = first twinkle), beep, glitch, shutter.",
                oneOf: MCPVocabulary.soundEffectPresets
            ),
            "duration": MCPSchema.number("Seconds, 0.05-10 (default: the preset's own, 0.05-2).", minimum: 0.05, maximum: 10),
            "pitch": MCPSchema.number("Pitch multiplier 0.25-4 (default 1).", minimum: 0.25, maximum: 4),
            "brightness": MCPSchema.number("0 dark to 1 bright (default 0.5).", minimum: 0, maximum: 1),
            "size": MCPSchema.number("Space: 0 dry to 1 hall (default: the preset's own).", minimum: 0, maximum: 1),
            "variation": MCPSchema.integer("0-999: another take of the same sound.", minimum: 0, maximum: 999),
            "volume_db": MCPSchema.number("Clip dB (default -8); clamps to edit_limits.volume_db, returned as requested/applied.")
        ], description: "Instead of file: a sound effect made on this Mac (no download, no fal); place it with hit_at.")
        let item = MCPSchema.object([
            "file": MCPSchema.string("Path of a video, image, audio or subtitle file (absolute, or relative to the opened folder)."),
            "library_id": MCPSchema.string("Instead of file: a music track id from find_audio (SkyCut downloads it if needed)."),
            "sound_effect": soundEffect,
            "hit_at": MCPSchema.number(
                "For sound_effect or a library sound effect: the timeline second its loudest moment lands on (a cut, a word " +
                    "appearing); SkyCut sets the start (overrides start). Default for sound_effect: the playhead.",
                minimum: 0
            ),
            "source_in": MCPSchema.number("Where to start in the file, seconds (default 0).", minimum: 0),
            "source_out": MCPSchema.number("Where to stop in the file, seconds (default: the end). For an image: display length (default 5), checked against edit_limits.image_source_duration."),
            "track": MCPSchema.string(MCPSchema.trackDescription),
            "start": MCPSchema.number("Timeline start in seconds.", minimum: 0),
            "sound": MCPSchema.string(
                "Video file: separate also puts its sound on an audio track, linked to the muted picture (J/L cuts); only adds just its sound.",
                oneOf: MCPVocabulary.clipSounds
            )
        ])
        return MCPToolDefinition(
            .addClips, title: "Add clips",
            description: """
            Add files, library audio (find_audio) or locally generated sound_effects in order. Each item supplies one source, \
            source_in/out, track and start; effects may use hit_at to place their loudest moment. Video/images append on \
            their track (default V1); audio starts at 0 on the first free audio track. Overlapping video lifts a track; \
            insert=true pushes later V1 clips. One subtitle file replaces the current subtitle track. External-file approval \
            follows permission mode. All windows validate before insertion. Returns ids, requested/applied/adjustments, hit_at and music credits.
            """,
            input: MCPSchema.object([
                "clips": MCPSchema.array(of: item, "Clips to add, in timeline order.", minItems: 1),
                "insert": MCPSchema.boolean("On V1 with a start time: push later V1 clips right instead of lifting to another track."),
                "confirm_token": MCPSchema.confirmToken
            ], required: ["clips"])
        )
    }

    private static var editClip: MCPToolDefinition {
        let crop = MCPSchema.object([
            "left": MCPSchema.number("Source fraction from left; see edit_limits.crop. Outside range fails; use region."),
            "right": MCPSchema.number("Fraction to cut from the right.", minimum: 0, maximum: 0.45),
            "top": MCPSchema.number("Fraction to cut from the top.", minimum: 0, maximum: 0.45),
            "bottom": MCPSchema.number("Fraction to cut from the bottom.", minimum: 0, maximum: 0.45)
        ], description: "Remove source edges; all 0 resets.")
        return MCPToolDefinition(
            .editClip, title: "Change a clip",
            description: """
            Edit one clip; edit_clips batches the same fields. region={x,y,width,height} selects the upright source \
            rectangle (0–1, top-left): fit=fit (default) shows it whole; fit=fill fills canvas. No crop, focus/follow \
            or manual transforms with region. Returns regions/transform and requested/applied/adjustments. Invalid values fail atomically with allowed/suggested; edit_limits gives ranges. Trim: the timeline start stays fixed, \
            the end moves (pass start too to keep the end). Overlaps fail; ripple shifts later V1 clips. \
            Otherwise fit uses the whole source or crop/remove_black_bars; fill aims at faces, people, text, then \
            salient objects, following unless follow=false. Animated position/scale blocks static placement. Never edits the file.
            """,
            input: MCPSchema.object([
                "clip_id": MCPSchema.string("Clip id from get_timeline."),
                "file": MCPSchema.string(
                    "Swap media; keep place, length and settings. source_in starts inside the new file (default 0)."
                ),
                "start": MCPSchema.number("New timeline start, seconds.", minimum: 0),
                "track": MCPSchema.string(MCPSchema.trackDescription),
                "source_in": MCPSchema.number("New start inside the source file, seconds. The clip's timeline start stays; its end moves.", minimum: 0),
                "source_out": MCPSchema.number("New source end, seconds; image length must fit edit_limits.image_source_duration. Timeline end moves.", minimum: 0),
                "speed": MCPSchema.number("Playback speed (1 = normal); see edit_limits.speed. Outside range fails."),
                "volume_db": MCPSchema.number("Clip dB (0 = original); clamps to edit_limits.volume_db. Shifts any volume_curve; reports saturation."),
                "muted": MCPSchema.boolean("Silence the clip."),
                "hidden": MCPSchema.boolean("Hide the clip from preview and export without deleting it."),
                "fade_in": MCPSchema.number("Audio fade-in, seconds.", minimum: 0),
                "fade_out": MCPSchema.number("Audio fade-out, seconds.", minimum: 0),
                "fit": MCPSchema.string("fill: cover the whole frame; fit: show the whole picture.", oneOf: ["fill", "fit"]),
                "focus": MCPSchema.string("With fit=fill: aim at the subject (default), at the text, or the centre.", oneOf: ["subject", "text", "center"]),
                "focus_x": MCPSchema.number("With fit=fill: source X to centre (0 left, 1 right).", minimum: 0, maximum: 1),
                "focus_y": MCPSchema.number("With fit=fill: source Y to centre (0 top, 1 bottom).", minimum: 0, maximum: 1),
                "follow": MCPSchema.boolean("With fit=fill: follow moving subjects (default true)."),
                "crop": crop,
                "region": MCPSchema.object([
                    "x": MCPSchema.number("Left edge.", minimum: 0, maximum: 1),
                    "y": MCPSchema.number("Top edge.", minimum: 0, maximum: 1),
                    "width": MCPSchema.number("Width (>0).", minimum: 0, maximum: 1),
                    "height": MCPSchema.number("Height (>0).", minimum: 0, maximum: 1)
                ], required: ["x", "y", "width", "height"], description: "Upright source, top-left, inside 0–1; ≥2 pixels/side. Replaces crop/placement. No auto-framing or manual transforms; clear rotation/motion entrance/exit first."),
                "remove_black_bars": MCPSchema.boolean("Detect/crop black bars (instead of crop)."),
                "x": MCPSchema.number("Canvas centre X: 0 left, 1 right; -2–3 reaches zoomed edges.", minimum: MCPFramingLimits.center.lowerBound, maximum: MCPFramingLimits.center.upperBound),
                "y": MCPSchema.number("Canvas centre Y: 0 top, 1 bottom; -2–3.", minimum: MCPFramingLimits.center.lowerBound, maximum: MCPFramingLimits.center.upperBound),
                "scale": MCPSchema.number("Size relative to default fit (1); outside range fails.", minimum: MCPFramingLimits.scale.lowerBound, maximum: MCPFramingLimits.scale.upperBound),
                "rotation": MCPSchema.number("Clockwise degrees.", minimum: -360, maximum: 360),
                "opacity": MCPSchema.number("0 = invisible, 1 = solid.", minimum: 0, maximum: 1),
                "flip_horizontal": MCPSchema.boolean("Mirror left-right."),
                "flip_vertical": MCPSchema.boolean("Mirror top-bottom."),
                "entrance": MCPSchema.string("How the picture comes in (a V1 transition replaces entrance / exit on its edge).", oneOf: MCPVocabulary.clipAnimations),
                "entrance_duration": MCPSchema.number("Seconds (default 0.6 when an entrance is chosen).", minimum: 0),
                "exit": MCPSchema.string("How the picture goes out.", oneOf: MCPVocabulary.clipAnimations),
                "exit_duration": MCPSchema.number("Seconds (default 0.6 when an exit is chosen).", minimum: 0),
                "animation_intensity": MCPSchema.number("Rise/pop/zoom distance, 0–1 (default 0.6).", minimum: 0, maximum: 1),
                "volume_curve": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds, inside the clip.", minimum: 0),
                    "db": MCPSchema.number("dB; clamps to edit_limits.volume_db and reports actual points.")
                ], required: ["time", "db"]), "Volume points in timeline seconds and dB, replacing the whole curve ([] removes it); straight lines between them."),
                "sound_scene": MCPSchema.object([
                    "kind": MCPSchema.string("Scene.", oneOf: MCPVocabulary.soundScenes),
                    "intensity": MCPSchema.number("How much of the effect, 0–1.", minimum: 0, maximum: 1),
                    "distortion": MCPSchema.number("Speaker scenes, 0–1.", minimum: 0, maximum: 1),
                    "tone": MCPSchema.number("Speaker scenes, 0–1.", minimum: 0, maximum: 1),
                    "room_size": MCPSchema.number("Room and outdoor scenes, 0–1.", minimum: 0, maximum: 1),
                    "distance": MCPSchema.number("Room and outdoor scenes, 0–1.", minimum: 0, maximum: 1)
                ], description: "A speaker (telephone, megaphone, radio: distortion, tone) or a place (the others: room_size, distance); kind none removes it."),
                "markers": MCPSchema.array(of: MCPSchema.object([
                    "time": MCPSchema.number("Timeline seconds, inside the clip.", minimum: 0),
                    "note": MCPSchema.string("Note shown on the marker."),
                    "color": MCPSchema.string("Colour.", oneOf: MCPVocabulary.markerColors)
                ], required: ["time"]), "This clip's markers (replaces all of them; [] removes them all)."),
                "ripple": MCPSchema.boolean("On V1: move the later V1 clips by the same amount the clip's end moves."),
                "alone": MCPSchema.boolean("Leave its linked clips (separated sound or picture) as they are, e.g. to trim one side of a J/L cut."),
                "keyframes": MCPSchema.string("keep_frames (default: motion stays on its source frames), stretch (re-timed to the new window) or clear.", oneOf: MCPVocabulary.keyframePolicies)
            ], required: ["clip_id"])
        )
    }

    private static var setText: MCPToolDefinition {
        MCPToolDefinition(
            .setText, title: "Text",
            description: """
            Add text, or edit text_id; omitted fields stay. Position is the block's centre, named or x/y canvas fractions. \
            Sizes use a 1080-high frame; colours #RRGGBB or #RRGGBBAA. Text wraps in box_width. Native clamping returns requested/applied/adjustments.
            """,
            input: MCPSchema.object([
                "text_id": MCPSchema.string("Change this text instead of adding one."),
                "text": MCPSchema.string("The words; a newline (or the two characters \\n) starts a new line."),
                "start": MCPSchema.number("Timeline start in seconds (default: the playhead).", minimum: 0),
                "duration": MCPSchema.number("Seconds on screen (default 3).", minimum: 0.2),
                "position": MCPSchema.string("Named spot.", oneOf: MCPVocabulary.textPositions),
                "x": MCPSchema.number("Horizontal centre, 0–1.", minimum: 0, maximum: 1),
                "y": MCPSchema.number("Vertical centre, 0–1.", minimum: 0, maximum: 1),
                "box_width": MCPSchema.number("Wrap width as a fraction of the frame width (default 0.8).", minimum: 0.05, maximum: 1),
                "font": MCPSchema.string("Font family name, e.g. PingFang SC, Helvetica Neue, Avenir Next."),
                "font_size": MCPSchema.number("Pixels at 1080 height, scaled with canvas height (default 96). Native limits returned in result.", minimum: 12, maximum: 1000),
                "bold": MCPSchema.boolean("Bold."),
                "italic": MCPSchema.boolean("Italic."),
                "color": MCPSchema.string("Text colour."),
                "alignment": MCPSchema.string("Line alignment inside the block.", oneOf: MCPVocabulary.textAlignments),
                "stroke_color": MCPSchema.string("Outline colour; \"none\" removes the outline."),
                "stroke_width": MCPSchema.number("Outline width in pixels.", minimum: 0.5, maximum: 24),
                "shadow": MCPSchema.boolean("Soft drop shadow."),
                "background_color": MCPSchema.string("Box behind the text; \"none\" removes it."),
                "letter_spacing": MCPSchema.number("Extra space between letters, pixels (0 = normal).", minimum: -20, maximum: 80),
                "rotation": MCPSchema.number("Clockwise degrees.", minimum: -360, maximum: 360),
                "animation_in": MCPSchema.string("Entrance animation.", oneOf: MCPVocabulary.textAnimations),
                "animation_out": MCPSchema.string("Exit animation.", oneOf: MCPVocabulary.textAnimations),
                "animation_in_duration": MCPSchema.number("Entrance seconds (default 0.6).", minimum: 0),
                "animation_out_duration": MCPSchema.number("Exit seconds (default 0.6).", minimum: 0),
                "animation_intensity": MCPSchema.number("How far the animations move, 0–1 (default 0.6).", minimum: 0, maximum: 1),
                "emphasis": MCPSchema.string("Loops while on screen: breathe = a slight slow pulse.", oneOf: MCPVocabulary.textEmphasis),
                "number": MCPSchema.object([
                    "from": MCPSchema.number("Start value."),
                    "to": MCPSchema.number("End value."),
                    "decimals": MCPSchema.integer("Digits after the point (default 0).", minimum: 0, maximum: 4),
                    "thousands": MCPSchema.boolean("Group thousands with commas (default true)."),
                    "prefix": MCPSchema.string("Before the number, e.g. \"$\"."),
                    "suffix": MCPSchema.string("After the number, e.g. \"+\" or \" days\"."),
                    "style": MCPSchema.string("count counts up; odometer spins each digit.", oneOf: MCPVocabulary.numberStyles),
                    "seconds": MCPSchema.number("How long it rolls (default 1.5).", minimum: 0.1, maximum: 20),
                    "delay": MCPSchema.number("Seconds to wait before rolling.", minimum: 0, maximum: 60),
                    "remove": MCPSchema.boolean("true turns it back into plain text.")
                ], description: "Show a number rolling from one value to another instead of text (text is not needed); only the fields you pass change."),
                "hidden": MCPSchema.boolean("Hide it without deleting it.")
            ])
        )
    }
}
