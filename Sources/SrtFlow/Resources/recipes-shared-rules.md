## Rules for every recipe

1. Know the footage before cutting: open_folder, then look files (all short files at once) or look shots=true (long videos),
   transcribe anything with speech, listen for levels and silences. Choose shots by what they show, not by file names.
2. Ask once which platform the video is for if the user has not said: TikTok, Douyin, Xiaohongshu, Reels or Shorts → 9:16;
   YouTube or Bilibili → 16:9.
3. 9:16 safe area: the platform's buttons and captions cover the top 10%, bottom 20% and right 12% of the frame. Keep big
   text, subtitles and anything that must be read outside them (text y between 0.12 and 0.75, x between 0.08 and 0.85).
4. Text: one main point per screen; at most two fonts in a video; short lines (Chinese ≤ 8 characters, English ≤ 5 words);
   never over faces or the main subject (compare set_text's block with look).
5. Sound: something is heard within the first 0.5 s. With speech, music sits about 10 dB under the voice only while words
   are spoken (Voice and music, 1); without speech, music around −18 dB. At the end the music finishes on its own ending
   (taste rule 20 below) or fades out (fade_out) — never a hard stop.
6. Never invent numbers, reviews, student counts, prices or links; use only what the footage and the user give.
7. Before exporting, go through the recipe's checklist: look at the key moments of the timeline (the start, the first frame of
   each part, the end) and measure the whole mix with listen mix=true. Then do "Look again before export" below, which ends
   with the inspect_video report every delivery needs.
8. When done, tell the user which recipe you followed, the length, the shape and where the video is; with library music, give
   the credit lines (music_credits).
9. Subtitles: set how they look with edit_subtitles style before generate_subtitles or add_voiceover subtitles=true (lines are
   cut to fit that size). It changes only this project, never the user's Burn In Subtitles page. Word highlight only lights
   lines SkyCut made from speech or a voiceover (get_subtitles tells lines_with_word_times).
10. Sizes count against the frame's height: set_text font_size and the subtitle style size are pixels on a frame 1080
    high, and a 9:16 frame is 1920 high, so the same number draws 1.78× larger across its width. A recipe names the shape
    its sizes are for; a single number is for 16:9 — on 9:16 divide it by 1.8.
11. If generate_media is among your tools: use it only for what the footage cannot give (a missing establishing shot, a
    real-world sound such as ambience, a crowd or an animal, music when find_audio has nothing that fits), never to
    replace footage the user has, and never present generated pictures as the user's own footage (the terms of use for
    generated content are Sky Studio's; music_credits covers only library music). It spends the user's Sky Studio
    credits (without a Sky Studio key it answers with an error; then skip this rule), and skycut_guide topic=paid has the
    rules for paid work. Keep in mind while you edit: tell the user the price before making anything (quote_only=true);
    draft video with the low-cost draft SkyCut picks for the model (leave resolution out) and remake only the shots you
    keep, quoting first and going by what each call returns. needs_confirmation, whatever the reason: ask the user the
    result's question in the chat and call again with confirm_token only if they agree. daily_budget_exceeded is the
    daily hard credit limit: stop there, as nothing started or was charged and no token or permission mode gets past it;
    tell the user they can raise it in SkyCut Settings → Sky Studio, change it with set_settings only when they ask you
    to, and never split or shrink a request to get under it.
12. Sound effects, in this order: first find_audio kind=sound_effect for a recorded or produced one (whooshes, impacts,
    risers, wind, ice, water, mechanical…; place it with add_clips library_id and hit_at); when nothing fits, add_clips
    sound_effect makes one on this Mac (whoosh, swoosh, suction, riser, downlifter, impact, boom, hit, pop, click, tick,
    ding, sparkle, beep, glitch, shutter): give hit_at = the timeline second the hit must land on (a cut, a word
    appearing) and SkyCut sets the start. Both sit at -8 dB under speech; change volume_db if needed. generate_media is
    only for real-world sounds neither has; find_audio is also where music comes from.
13. Voiceover can spend credits too: with a Sky Studio key, add_voiceover reads the default preset, the roles and voice_…
    voices with Sky Studio, which spends credits; SkyCut's own voices and the Mac's are free. Only when Sky Studio cannot
    be used this time (no connection, a server error, a key it does not accept) does a preset or role switch to a local
    voice, before anything is paid, and voice.note in the result says so: go by it. When Sky Studio refuses the request
    itself (say a named model that does not fit the voice or the language), the call returns that error: nothing is
    charged and the voice does not change. skycut_guide topic=add_voiceover and topic=paid have the details; keep these
    in mind:
    - Narrating new lines: before the job_id comes back, add_voiceover quotes the whole script once and reserves that
      against the daily credit limit. Tell the user the credits in the result (get_job reports what was charged).
    - A voice_… voice that must first be built for this language (a one-time fee) returns that step instead:
      needs_confirmation, or a job of kind voice_enroll (already_building when that version is already being built, with
      nothing new charged). Those credits build the voice, not the narration, which is not read or reserved yet: follow
      next_step (build it, or skip_one_time=true to read without the fee) and call add_voiceover again once it is built.
    - daily_budget_exceeded stops it like any paid work: nothing started; switch to a local voice only if the user asks.
    - Sky Studio voices ignore speed.

## Sound belongs to the picture

These four sections (this one, Cuts, Voice and music, Title cards) hold in every style; only the user's own words
override them.

1. What makes a sound on screen is heard: cars, ships, water, animals, fire, drums, rain, machines, breathing (a thing
   heard in the last 8 s may give way to a voice or the music). Why: a silent car makes the place feel fake. How:
   add_clips keeps a video's own sound, so check it with listen (describe=true says what it holds); when there is none,
   add one under that shot (find_audio kind=sound_effect, else generate_media under rule 11).
2. A scene in one place keeps its own sound, mostly as it is, and may push its key action up 4–6 dB. Mute it only for
   lip-sync replaced by a clean take of the same line, a montage carried by narration and music, or near-silent footage,
   and replace what you mute with a sound that belongs to the picture. Why: without it only music and narration remain.
   How: edit_clip volume_db, muted, volume_curve.
3. A sound stays with the shots that show its source: a thing's sound may lead its picture by up to about 1 s and ends
   within 2 frames after the picture cuts away; one ambience layer per place, at most 2 s over either side and under the
   voice unless on purpose (a shout in a storm); indoors, the outside wind is gone within 2 s. A deliberate linger (a hit's
   tail over black) is named in the beat sheet. Why: a sound from elsewhere moves the people somewhere else. How: match
   add_clips start and length to the shot, with fade_in and fade_out; synthesized effects can run long, so check their
   end with listen; volume_curve after the cut.
4. A voice plays over its speaker or the speaker's place: off-screen lines and announcements start at most 1 s before and
   end at most 0.3 s after that picture, never outlasting it. Why: an announcement over two people in a car becomes their
   line. How: transcribe for sentence times, get_timeline for the shot under each.
5. Lip-sync plays only that person's take of that line, within 3 frames; no narration or other voice over anyone talking
   on screen. Why: a moving mouth with another voice looks fake. How: look and transcribe, then move start (frames =
   seconds × the fps in get_timeline); for a clean take, mute the clip and put the take at the same start.
6. Generated video usually has its own sound, which can carry a low drone the picture does not show, as loud as a voice.
   Measure it before deciding what stays: keep what belongs to the picture, lower or mute the rest and anything covering
   speech; when you cannot tell what it is, ask the user to listen. Why: a shot of wind can hide a drone that buries the
   narration. How: listen file=… or clip_id=… with describe=true says what it holds every 3 s (low_drone, broadband_noise,
   speech_like…), in words, not a verdict; edit_clip voice_band_db lowers only the voice band of a rumble whose low hits
   must stay.

## Cuts

1. Every cut gets a sound crossing, written in the beat sheet: (1) overlap (frames); (2) the next sound early or the last
   one late (frames); (3) a bed (ambience or music) under the cut, raised first to within 6 dB of the louder side; only
   what its volume limit leaves uncovered comes off the louder side; (4) a deliberate hard
   switch on a music accent, a hit or a line's first word (say which); (5) gain so both sides meet (dB). A big jump in place
   sound (about 6 dB or more) needs one of the first four. Why: a bare switch between two places sounds broken. How:
   compare listen clip_id=… from=… to=… level_db over the half second on each side; set_transition after_clip_id=… makes
   each in one undo step, the picture never moving (all=true: every V1 cut): (1) sound=crossfade; (2) sound=lead or lag;
   (3) set_transition sound=bed; (4) sound=cut or on_beat, a hit placed with add_clips hit_at; (5) sound=gain.
2. In and out points go by frames, not round seconds, and never cross a cut inside the source (out at least one frame
   before it, in on it at the earliest; a deliberate one is named with its frame). Why: a rounded "3.5 s" let two frames
   of another shot flash by. How: look shots=true on each file first (generated videos often hold several shots); add_clips
   and edit_clip return source_cuts when a window still crosses one, with a suggested_source_in or suggested_source_out;
   frames are seconds × the fps in get_timeline.
3. A speaking shot holds at least the whole line; never cut someone else's short shot into a line (show the listener after
   it); quick cutting only where no one speaks or only narration runs. Why: a face cut into a sentence appears from
   nowhere. How: transcribe; listen cuts=true.

## Voice and music

1. Under speech, dip the music about 10 dB only while words are spoken (down 0.3–0.5 s before a line, back 0.5 s after,
   not between words), and leave no hole where the whole mix stays under −36 dBFS for 1.5 s unless it is a held breath.
   Why: deep, long ducking sounds like the video broke. How: set_track duck_others_db on the voice's track dips every
   other layer under each line in one call (lines from transcribe, or a narration's own pauses); volume_curve for other
   shapes; set_track volume_db; inspect_video from=0 silence_db=-36 min_silence=1.5 finds holes.
2. A voice must be clear against everything else together, not just the music: measure a shot's own sound before laying
   narration on it, and when a line is hard to hear, lower the layer that covers it under that line instead of the music
   again. Why: music lowered twice did not help when the shot's own rumble covered the line. How: listen voice=A1 (or auto)
   scores each narration line against the whole mix and names the layers covering it most (maskers); lower that one under
   the line (volume_curve, edit_clip volume_db, or voice_band_db for a rumble whose low hits must stay) and check again.
   A voice in a clip's own sound is not scored: compare listen clip_id=… from/to levels over the line. For may_be_hard, or
   when unsure, ask the user to listen.
3. One piece of music per chapter, changing where the story changes (a new piece may enter 0.5–1.2 s early, or everything
   switches on one frame); after the opening, a dialogue scene starts without music, which enters on the laugh or the
   event (under narration or a talking head the music just dips, 1); a piece with no job you can name (carry, mood,
   drive) goes, and ambience or a quiet bed takes its place. Why: wall-to-wall music or scraps tie nothing together.
   How: volume_curve for out, cut and fade.
4. With music, it is heard within 3 s of the first picture, quiet but with some melody, not a bare drone; a video opening
   on dialogue, a talking head or narration may hold it until that first line ends. Why: a bare opening is flat. How:
   start the music at 0 and raise it with volume_curve.
5. Generated music does not follow the seconds in its prompt: ask for more than the chapter needs, naming the mood, the
   instruments, where it builds, stops and comes back, and how it ends; then measure it and put the place where it stops
   and comes back by itself on the cut that must go from quiet to loud, in two pieces when needed. Why: four generated
   tracks came back 3–9× too long, none on its seconds; their own stops then landed three cuts within a frame. How:
   generate_media kind=music under rule 11; its get_job music (or listen file=… beats=true) gives stops ([from, to], to
   being the hit that brings it back) and strongest_accents; add_clips hit=<that second> hit_at=<the cut>; a second piece
   is the same file added again from the stop.

## Title cards

Opening, company, title and end cards go where no one speaks (never over the hook line or the tightest stretch), on an
empty, dark enough part of the picture (white text leaves bright ones), and stay readable at least 3 s each (set_text
duration); a call to action on the last frame follows its style instead. Company and name cards: thin, widely spaced
type, in slowly and out quickly, about 1 s after a hit (short of room: in on an accent, out on a cut), company and names
on separate cards. A title lands on a big hit of the music, the heaviest when it closes the video. Taste rule 11 is for
labels, not these cards. Why: a card over speech, or one that flashes by, is neither heard nor read. How: set_text
motion_preset (focus_pull or frame_reveal for credits, title_counter) with hit_at where it comes in, or start,
letter_spacing and animation_in focus or fade; look at that moment.

## Plan before you cut

Before the first edit, write a beat sheet and show it to the user in a few lines, then carry on (they can stop you or undo
the round; wait for an OK only when they asked to see plans first):

- One sentence: "This video tells <who> that <what>."
- One row per shot (very short shots may share one): its seconds; its job (hook, build, peak, rest, end); the file with in
  and out points in frames; the size, where the subject sits and faces, and what leads the eye there; what moves, as a
  verb (slams in, drifts, holds still, draws itself, counts up); its sound: what on screen makes a sound, the footage's own
  sound kept, muted or replaced (by what), who speaks when (lip-sync, off-screen or narration), the second of the key
  moment that music changes and hits follow; the handover: the picture cut and the sound crossing (Cuts, 1).
- Name the rhythm before cutting, e.g. "fast-fast-HOLD-fast-PEAK-rest-end": where is the peak, where does the video breathe?
- A shot with no job is cut; no edit starts before every row is filled, so a silent car or a voice on the wrong shot
  shows up on paper first.

## Taste for every style

What separates an edited video from an assembled one. When a style says otherwise, the style wins.

Pace
1. Vary shot lengths on purpose: the longest shot is at least 3× the shortest, and the same length (within 0.2 s) never
   comes three times in a row. A held shot after a run of quick ones hits harder than more speed.
2. Each part builds, breathes and resolves: it starts with energy, holds one calm moment, and ends decisively.
3. Cut on something: the end of a movement, a look or a gesture, a word. Cut on the beat where the music drives (the build
   and the peak; cut_to_beat does it) and where the picture asks elsewhere — a video cut on every beat feels mechanical.
4. Let moments land: keep 0.5–1 s after a line or an important moment before cutting away. In action, cut during the
   movement (the next shot picks it up under way); only a section's last action (a fall, a landing) finishes, with the
   hit on it.
5. Change the shot size or the angle at every cut (a wide shot, then a close one; not two wide shots of the same thing). A
   jump cut is fine only when it is meant (talking heads, vlog energy).

Picking shots
6. Use the best 20–30% of the footage: sharp, well lit, a clear subject, faces with expression. Drop soft, shaky or dull
   shots even when they are on topic; a shorter video of strong shots beats a longer one.
7. Open on the strongest picture you have, not the first one filmed.

Transitions
8. A transition says something. A hard cut is the default and the strongest; crossFade = time passes or a feeling goes on;
   blackFade = a chapter ends, the video starts or ends; whiteFade = a flash for a reveal; pushes and wipes = energy, in
   promos and vlogs. Besides hard cuts use at most two kinds in one video, and at most one decorative transition in any 10 s.

Motion
9. Not every shot moves. Mix still shots, slow push-ins (set_keyframes scale 1 → 1.04–1.08 over the shot), slow drifts
   (position x or y moving 0.02–0.04 over the shot) and the footage's own movement. For a drift on a picture that exactly
   fills the frame, use scale at least 1 + 2 × the drift to avoid exposing an edge (0.03 drift needs 1.06). Never the same
   move on two shots in a row and never a move on every shot: a still shot after moving ones is a breath.
10. Easing carries the feeling: easeInOut for camera-like moves (a push, a drift), easeOut for things that arrive and
    settle, easeIn for things that leave, linear only for a very slow drift through a whole shot; snap for a fast push-in or
    a crash zoom (0.2–0.3 s), overshoot for a picture that pops into place (a picture-in-picture arriving), spring for
    something playful. Never overshoot or spring on a slow camera move, and at most one of them in any 10 s.
11. Asymmetry and offsets: entrances take longer than exits (text animation_in_duration 0.5–0.8 s, animation_out_duration
    0.3–0.4 s). A text starts 0.2–0.3 s after the cut under it, not on the cut. Texts of one group arrive one after another,
    0.1–0.2 s apart and the whole group within 0.5 s, the most important one first.
12. Punch in on emphasis in talking-head footage: split_clip where the key line starts and make the second piece 1.12–1.2×
    bigger, framing the face (edit_clip scale; or set_keyframes scale with the same value at the start and the end when the
    clip has keyframes); go back to the wider framing at the next idea. One camera then feels like two. At most one punch-in
    every 8–10 s. A move instead of a cut: set_keyframes scale 1 → 1.15 over 0.2–0.3 s with easing snap.

Text
13. One accent colour for the whole video, taken from the footage or the brand; all other text white or near-black.
    Emphasise with weight, size or that colour — one of them at a time — and never with italics.
14. Hierarchy: one big thing per screen; a title is 2–3× the size of a label; at most two fonts and two weights.
15. Big bold sans-serif headlines read best with letter_spacing 0 or slightly negative (down to −2); small labels and
    elegant capitals with wide letter_spacing (10–40).
16. Place text on purpose: on a third or along an edge of the picture, with the same margin every time (at least 6% of the
    frame); centred only for titles and solemn moments.

Sound
17. Sound starts the video: the first sound comes with or before the first picture.
18. The music's strongest moment is the video's peak: slide the music (its start, or source_in) so its hit or drop lands on
    the peak, rather than cutting the pictures to wherever the music happens to peak. listen beats=true lists its
    strongest_accents; add_clips hit_at=<the peak> lands the strongest one there (hit=<a second> picks another); for a
    placed clip, move its start by the peak minus the accent's time.
19. A breath before the peak when no one is speaking: 0.3–1 s of near-silence before the biggest moment (volume_curve, or
    a stop in the track itself), then the hit on the action's cut. If the moment falls inside a line, keep the music
    level until the line ends: a dip mid-line sounds as if the music just died.
20. End on the music's own ending: place the track so its last note ends with the video (listen beats=true gives ends_at,
    where its own sound is over: add_clips hit=<ends_at> hit_at=<the video's end>). If it is too long, keep its start
    and its real ending and take out a middle part: split_clip at two downbeats (listen beats=true gives them) a whole
    number of bars apart (4, 8 or 16), delete the middle with delete_items, move the ending to a new_audio track so it
    starts where the first part stops, and give the first part fade_out 0.1 and the ending fade_in 0.1. Fade out in the
    middle of a phrase only when nothing else works.
21. J-cuts and L-cuts are one of the crossings in Cuts, 1: the next scene's sound 0.3–1 s before its picture, or a voice
    carrying over the next picture (a video's own sound: add_clips sound=separate first).
22. Added effects punctuate, they do not decorate: at most one every 2–3 s, the biggest on the peak, none in quiet
    moments. Sounds of things on screen do not count.

## AI tells to avoid

These make a video look generated; check the timeline for each before export:
- every shot the same length, or every cut on a beat;
- a crossFade (or any decorative transition) between every two shots;
- a slow push-in on every shot;
- every text centred, starting exactly on the cut, all with the same animation;
- a sound effect on every cut and every word;
- music starting at full volume at 0 s and fading out in the middle of a phrase;
- text over faces, a box behind every text, more than one accent colour;
- a filter at full strength, or a different filter for each part;
- opening on a logo, a slow fade-in or the least interesting shot;
- the same choices in every video, whatever the footage.

## Look again before export

After the style's checklist, judge the video as a viewer — with look and listen, not from memory. Fix what fails, then tell
the user in one line what you checked.
1. Poster: look at the peak moment alone (size large). Would it work as a still? If not, change the shot, the framing or the
   text.
2. At a glance: look at 4–6 key moments together (size small). Is it clear in each what matters most?
3. Rhythm: list the shot lengths from get_timeline. Do they follow the beat sheet (quick in the build, held at the rests)? If
   most are within 0.3 s of each other, recut.
4. Rests or gaps: find the stretches with no new shot, text or sound event. Are they rests you planned, or gaps where the
   video just stops?
5. Sound: listen mix=true around the peak and the end. Is there a breath before the peak, and does the music end with the
   picture?
6. Cuts frame by frame: given file=… on an export_video preset=quick_review copy, inspect_video (7) scans every frame for
   stray_frames, flashes and black_frame, and each clip against its source's own cuts (source_cut); look at the 4 frames
   before and after each cut it reports (look times=[those 8] size=small, one cut a call), or at every cut without a
   copy. Why: a 2-frame flash hides between samples 0.25 s apart.
7. Before delivering, run inspect_video over the whole timeline (with file=… on that copy) and wait with get_job. Fix what
   is wrong and inspect again; then mark each finding you meant (a hard switch or a held breath from the beat sheet) with
   intentional={job_id, key, reason} and tell the user what you marked and why. Findings point at the rules above:
   audio_cut_jump (Cuts, 1), audio_linger (Sound belongs to the picture, 3), audio_voice_masked (Voice and music, 2),
   audio_hole (Voice and music, 1), sentence_cut (Cuts, 3). Why: it is the last check before the user listens.

## Learning a style from a reference video

When the user gives you a reference video (a trailer, an ad, a scene from a film they like) and wants its style:
- Measure it with SkyCut's tools: look shots=true (where it cuts, how long each shot is), listen beats=true (tempo, where the
  music hits and drops, the silences), text_scan=true (title cards — ignore burned-in subtitles unless the user asks about
  them) and look at a few frames (framing, colour, type, how text sits).
- Write what you measured as a style with save_recipe, in the same sections as these styles: the bar, structure by the
  second, pace (the median and range of shot lengths in each part), transitions and how often, motion, text, sound, taste,
  avoid and a checklist. Numbers, not adjectives.
- Learn the grammar, not the content: never reuse its footage, music, logos or title designs.
- Never download a reference from the web; ask the user for the file.
