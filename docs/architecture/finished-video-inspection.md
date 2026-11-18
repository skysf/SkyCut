# 成片疑点检查

`inspect_video` 是只报告的 MCP 入口。它不会提交时间线、挪播放头、改样式或登记撤销。
因为会写临时试听证据，工具的 `readOnlyHint` 为 false；这不代表会改工程。

调用时冻结工程、样式与范围，返回任务号。`get_job` 给结局、疑点和 JPEG 拼图；`cancel_job`
沿现有任务取消。任务绑定调用的工程，关闭工程和停止都复用已有归属规则。

## 范围与证据

- Since 2026-11-17 the default scope is the whole timeline.`from/to` 改成明确的时间范围，
  超出工程、反向范围先拒绝。范围只选择检查对象，不把片段截成新的素材。
- 声音从 `ExportAudioMixdown.render` 来：与正式导出相同的引擎、增益、推子、声音场景和限幅。
  只加 WAV 容器，不重编码或归一；电平、静音判法用 `AIListenTool.waveform` 和 `AIAudioLevels`。
- 素材切口：电平上有没有停顿复用 `AISpeechHearing` / `AICutCheck`（和 `listen cuts=true` 同一份）；**算不算切在说话上只拿人声判**
  （`AIInspectionSpeech`，[案例](../bugfixes/2026-11-16-inspection-reports-sound-onsets-as-speech.md)）：
  - 入点在文件开头、出点在文件结尾（差不到一帧）的那一头不查：什么都没切掉（合成音效、旁白、从头放的音乐都从第 0 秒开始）。
  - 证据只有两样：这一段转写缓存里的词（识别器原样的源秒）；没有转写时，原文字幕里记着出处的句子（配音、生成字幕的
    `CueMeta.provenance`），只在出处那一段用到的源秒范围里算数。有声又落在词 / 句里面才报 `audio_cutoff`；有证据但没在说话
    （音乐、音效、环境声、底噪）不报。
  - 没有证据的不当成切在说话上：片段 id 列进 `speech_unchecked`，叫 AI 先对有人声的几段 transcribe。不启动转写或收费生成。
  渐变已把边界声音压低时不报截断。
- 音频重叠只报同轨或重复源的并发段；原生主轨互补交叉淡变不报。不同源跨轨的同时说话
  无法仅凭几何可靠判断，这一版不报；它不做语义上的语音分离。
- 时间线画面走 `AIFrameComposer`，文件走 `AIFrameSampler`；黑帧按 `AIBlackBars` 的亮度图判断。
  按 0.5 秒采样，先放结尾和范围边界，一次最多 120 帧；`sampled_picture_times` 和
  `omitted_picture_samples` 如实给范围。连着几帧都黑的合成一条、写从哪到哪。纯音频工程不查黑场。
- **给了 `file`，整个文件每一帧都扫一遍**（夹帧、闪白、6 秒以上不动、黑场，`frame_scan` 写扫了多少帧），扫到了黑场只用逐帧的那一份；
  **每段看得见的画面对着它自己的素材**，跨过素材里的刀、露出不到 8 帧另一个镜头的报 `source_cut`（时间线和成片都查）。
  门槛、来历、范围和回归见 [夹帧提醒与成片逐帧扫](stray-frames.md)。画面那一半在 `AIInspectionPicture`。
- 字幕使用 `subtitleStyle(appWide:)`、`subtitleScreenBlocks()`、`AISubtitleBoxes`，字体、字号、
  折行、行距、布局、隐藏状态与工程一致；不强加其他平台的字幕规范，也不改字幕。
  同轨时间重叠、独立拖框的跨轨墨迹相交、时间或画布越界都报疑点；原生双语叠排不报碰撞。
- 最多列 150 个疑点，超出的数量另报；证据优先给结尾，最多 6 张截图、6 个不超过 3 秒的
  原声道 WAV。截图时刻和试听范围逐项列出。证据在当前进程的临时目录，不写进用户工程；
  用户 App 退出/系统清理临时目录后不能依赖这些路径，调用方需要及时查看。

分析取样与疑点证据截图分开。`image=true` 表示允许返回疑点图片；没有疑点或没有
可截图的画面时，`screenshot_times=[]` 且没有图像内容是正常结果，不添加“无法绘图”提示。
`sampled_picture_times` 仍说明黑帧分析取样，不能把无证据截图当成没有执行分析。
只有实际请求了疑点截图却没取得图片时，才沿 `AILookTool.finish` 报告绘图失败；
分析本身缺帧仍须按原合同返回 `coverage_complete:false` 与 `limitations`，不能因为
没有截图而改称完整通过。

传 `file` 时必须是当前时间线的成片，长度允许最多两帧或 0.1 秒的容器误差；画面、声音
读实际文件，字幕和源切口仍按冻结的工程检查。长度相同**不能证明内容相同**，结果明确说明；
文件做出来以后工程又改过（`AIInspectionFreshness`：比文件的创建时间和工程的存盘 / 没存的改动），开工的回答和结果都先给
`attention`，叫 AI 重新导出再查（[夹帧提醒与成片逐帧扫](stray-frames.md)第五节）；
烧进文件的字幕没有独立结构，不通过 OCR 猜字号后覆盖工程样式。读未授权文件夹沿用
`AIWorkspace.confirmReading`。

## 结论口径

每条只有 `suspected:true`、类型、时间范围、原因和相关条目，没有“自动修复”入口。
黑场、停顿、音乐交叠、响着收尾都可能是有意安排；没有疑点也不等于成片通过认证。
波形读不完整直接失败；部分画面或源切口读不到、采样达到上限时，
`coverage_complete:false` 加 `limitations`/遗漏数量，不能称作检查全部通过。
逐词高亮放大的瞬时外沿、语义上重复说话仍需人工复核；没给 `file` 时画面只是抽帧，不到 0.5 秒的闪帧也要人工复核
（交片前用导出的文件查，每一帧都过）。Stray frames, flashes, stillness and black may be intentional; project-persistent review decisions are described below.

## 验证与人工回归

`scripts/check-video-inspection.sh` 使用独立 bundle 与合成工程，走实际任务、混音、波形、
画面和字幕管线，验证六种疑点、MCP 图像内容、试听文件、范围、隐藏、取消和无编辑。
它接在 `scripts/check-all.sh` 第一组，不启动已安装 App。

Test clients must distinguish a wait response from a terminal job result. `AIJobs.wait` caps each
wait at 30 seconds to leave room in a client's request deadline; a running reply is legitimate.
The main inspection harness polls up to four times while the job is running, like the existing
delivery harness, and keeps the shell's 480-second outer deadline. Failed/cancelled results remain
failures of a successful-analysis assertion, and an exhausted running job cannot count as done.
The `job-polling` check case controls pending and terminal observations without replacing real
analysis; the normal check still runs all real-tool assertions. See the
[pending-job regression case](../bugfixes/2026-11-17-inspection-job-wait-still-running.md).

「切在说话上」的判法另有 `SpeechRuleChecks`：纯值规则逐条测，再用一直有声的正弦音工程走真工具 ——
没有人声证据的切口不报、列进 `speech_unchecked`，字幕记着在说话的那一刻报一次，文件自己的头尾不报。
反向：`cuts` 换回只看电平、不跳过文件头尾的判法，守卫在前两条上变红。
真实连续画面和声音的 5–6 秒范围应完成分析、无疑点、无截图并且不报绘图失败；
实际请求图片却缺帧仍有失败提示。反向只撤掉 `image && !wanted.isEmpty` 的条件，
守卫必须在干净范围的错误提示断言变红。

实际后台 MCP 小回归入口为 `scripts/gui-smoke/sky-studio/inspection.py`：按
[GUI 冒烟流程](../testing/gui-smoke-testing.md)四之八启动独立测试 App，提供 8 秒蓝画面与
连续正弦音的 `work/inspection-source.mp4` 合成夹具，脚本仅用 MCP 创建、入轨、检查、
保存并关闭自有后台工程。它不调用生成，并核对假服务没有准入任务、没有收费写请求。

发版前人工检查：

- [ ] 实际教程的接缝、最后一句和点名范围：复核疑点截图/试听，确认真实缺陷与有意停顿能区分。
- [ ] 音乐渐弱、声音场景余音、双语叠排：无错误的“确定缺陷”结论，样式保持原样。
- [ ] 带音效、配乐、环境声和旁白的真工程（AI 剪的预告片那种）：`audio_cutoff` 只剩真有词被切到的地方；
  音效、音乐的起点一条都不报，没转写过又切在有声处的片段只出现在 `speech_unchecked` 里。
- [ ] 后台工程检查期间切换前台工程、取消或关原工程：证据仍属于原来的快照，原工程无修改。
- [ ] 后台 MCP 默认 `image=true` 检查无疑点的范围：分析取样正常、`screenshot_times=[]`，
  没有“无法绘图”提示；真实疑点的证据截图照常返回，不以“无需图片”掩盖取证失败。

## Pre-delivery report and intentional decisions (2026-11-17)

Inspection now covers the whole timeline by default. `from/to` still selects a narrower range.
`AIDeliveryChecks.registry` is the small extension point: each named check consumes a frozen context
and returns findings asynchronously. Preparation supplies frame results, existing transcript sentences and the
shared `MixMeasurement`; a later check adds a registry entry without changing job or review logic.
There are no export gates, feature switches or automatic repairs.

The first tier adds these review heuristics, alongside the existing source/frame/subtitle checks:

| Kind | Measurement and provisional threshold |
| --- | --- |
| `audio_overload` | Timeline bus true peak exceeds `ExportPeakLimiter.defaultCeiling`, before limiting |
| `audio_limiter` | Export limiter's per-frame minimum gain is below 0.999; report maximum reduction and output dBTP |
| `audio_true_peak` | Actual decoded export true peak exceeds the same ceiling; never confuse it with the timeline bus |
| `audio_silence` | Per-frame mix power below `silence_db` for `min_silence` |
| `audio_thin` | Mix below −30 dBFS, above the silence threshold, with at most one audible layer for 0.75 s |
| `source_cut_crossing` | A longer retained join inside a source, separate from the short-fragment `source_cut` suspect |
| `audio_hole` | At least a 12 dB drop from the preceding 0.5 s, lasting at least 0.5 s, after a mix above −30 dBFS |
| `sentence_cut` | Source boundary or picture cut strictly inside a cached transcript sentence or provenance-bearing narration line; one project frame of slack at either end |
| `stale_export` | The existing freshness comparison, also retained as the leading `attention` note |

Thin/hole thresholds are conservative first-tier review heuristics, motivated by the production-feedback
examples of sparse sound and missing beds; they have not been validated across genres. They describe
power and layer count, not sound meaning or speech intelligibility. A layer is an audible track, with
tracks beyond the existing twelve-layer measurement limit combined as `rest`. Mixed-output power is decoded after limiting; a large drop on an already limited bus alone is not a mix hole. Sound findings identify
the subject items/layers and show the three loudest measured timeline layers at the finding's midpoint; no active
sound produces an empty list. File levels come from the bounded native reader with the shared true-peak
meter. File layer attribution and limiter history explicitly remain measurements of the timeline snapshot.
Matching lengths never prove matching content. No transcription or paid work starts automatically.

Native screen recordings now retain `isScreenRecording` through import, recovery, splitting, copying
and saving. Like stills, they are exempt from `frozen_picture` when all intersecting pictures are static
by nature; flashes, stray frames and black still run. Imported recordings without known provenance are
not guessed from filenames: mark an expected freeze intentional when provenance is unavailable.

Every finding has a `key`. `inspect_video intentional={job_id,key,reason}` records one decision, with
one nonempty line of at most 240 characters. `clear_intentional=<key>` removes one decision. These
explicit mutations use the project's normal `perform`, undo and autosave, without rebuilding preview;
ordinary inspection stays nonediting. Review requests cannot also include inspection fields. A report
must belong to the same document generation and AI session and still match the current timeline;
invalid/stale requests change nothing. The last 24 completed reports are retained during this run.

`TimelineState.deliveryIntentions` holds anchors and reasons (empty keys are omitted, old projects
read an empty array). Format v35 prevents older writers from discarding reviews. Each anchor records
kind, sorted item UUIDs, a reference clip, source-time bounds (timeline bounds without a clip) and a
stable SHA-256 fingerprint of relevant clip settings and mix settings, including other contributing clips without confusing them with the finding subject. Matching permits two project
frames in source time, including whole-clip moves, without a quantization boundary. Changing source,
identity, gain or a larger source-time interval invalidates a decision. Repeating the same kind on a
different clip cannot inherit it. A mark matches at most one finding in a report; exact duplicate findings are coalesced. Matching findings leave `findings` and appear under `intentional`
with their reason, separately for human review. The stale-export attention note remains visible even
when its finding has been marked. Unreproduced saved marks remain in the separate intentional list with `reproduced:false`; they suppress nothing and persist until explicitly cleared.

`DeliveryChecks` runs synthetic real-tool reports for overload/limiter, silence, thin sound, a mix hole,
source/picture sentence cuts, no edits, marking/suppression/separate listing, undo/redo, project-file
round trips, invalid reasons, stale reports, source-time tolerance and invalidation after a mix edit.
It also verifies the screen-recording exception against the real frame scanner.

Manual regression before release:

- [ ] Review a real quiet passage and a cutaway during narration; mark expected findings, save/reopen,
      inspect again, and confirm the separate intentional list and one-step undo.
- [ ] Inspect a native screen recording with a static screen and a camera clip that freezes; only the
      camera freeze is reported. Check an external recording with unknown provenance manually.
- [ ] Inspect a matching export and an older export; the sound measurement labels, timeline-layer
      attribution and stale-export attention are clear to the AI and human reviewer.

Reverse controls (2026-11-17): disconnecting mix/sentence checks makes nine production assertions fail;
disconnecting picture/freshness checks makes three file-report assertions fail. Disabling anchor matching
makes four review/timing assertions fail. Removing the screen exemption fails the real scan assertion;
using bus power instead of decoded output fails the limited-but-steady mix counterexample. Removing
native provenance assignment fails the import/recovery wiring guard. Each control is restored afterward.

Sentence continuity uses the audible render configuration, including track hiding and faders; an
inaudible continuation must not conceal a truncated sentence. The configured voice gain must exceed
0.1 at the cut, matching the existing word-cut fade gate. Active-layer counts use per-layer RMS above
−60 dBFS; quieter contributors can still be shown in the evidence.

Reverting audible-continuation filtering also fails the hidden-continuation regression (one failure in 34 rule assertions); the original source is restored afterward.

## Second-tier sound checks (2026-11-18)

Production feedback MCP-37 (a hard sound jump at a cut with nothing covering it), MCP-38 (a sound dragging past its picture),
MCP-39's voice check (#456, with its grey hint) and its "music swells under speech" reminder joined the report as four registry
entries: `cut_jumps`, `lingers`, `voice`, `music_swell`. They report only, like the first tier, and intentional marks apply to
them the same way. All four need to know what each sound is — the second tier of MCP-40's table.

### What each sound is

`AIDeliverySoundRoles` gives every clip with sound one role: voice, music, effects, ambience, object, camera (a picture's own
recording, also when detached to an audio track) or other (an imported file SkyCut can't name). First match wins:

1. `sounds` on the inspect_video call: a clip id, then a track (`"A2"`) or tracks joined with + → voice, music, effects,
   ambience or object. It is per call, not saved: the AI built the timeline or can listen, SkyCut can't tell an imported music
   file from an imported wind bed (the trait words describe, they don't classify: [listening engine](listening-engine.md)
   section 3). A review request (`intentional`, `clear_intentional`) refuses it like the other inspection fields.
2. Otherwise where the clip came from: the same `AIListenVoicePlan.Provenance` listen voice uses (our voice-overs and effects by
   folder, library music and effects by manifest id, generated audio as music, a video clip's sound as camera). Generated audio
   that is an effect needs `sounds`.

The report's `sound_roles` lists the roles per track (`"A2":"music+other"`), so the AI sees what was assumed. The voice check's
masker kinds follow the same roles (`Provenance.known`). Measuring groups: the place (camera, ambience, object, other) is what
jumps at a cut; voice, music and effects can cover a jump.

### Measuring

`AIDeliverySound.prepare` does all media reads, on `MediaReadQueue.export` with the export's audio configuration, offline, never
the preview's engine; it never edits the project:

- `AIDeliverySoundLevels`: one render split by role group (`DeliveryStemSplit`: each track split by group keeps its fader and
  segments, so the parts add up to the export's mix), before the limiter, per project frame (`DeliveryStemPower`: each group's
  power, without `MixMeasurement`'s 3 s preroll and bus meter — loudness, true peak and the limiter come from the first tier's
  own measurement, and running them twice made every inspection a render longer; the four bands only for the music, whose voice
  band a line is read against). In the same pass: the place group above 200 Hz in each cut window, every frequency under 200 Hz removed over
  the 0.3 s window as a whole (`DeliveryWindowCollector`, the human film's and the preview board's reading; the band meter's
  300 Hz edge, with its two-frame window, read 3 of the first draft's cuts differently), and the music accents: the rendered
  music group at 24 kHz, each music clip's stretch read with `DeliveryMusicAccents` (the research's accent reading: the
  magnitude under 200 Hz plus 0.3 × 200 Hz–4 kHz per 1024-sample frame, the rise of its log as a z-score over the stretch,
  above 3 and the largest within ±4 frames), kept where the music is above −45 dBFS. `AudioBeatTracker`'s onset strength,
  built to find a beat, found no accent at all in the human film's orchestral music where its cuts sit on accents.
- The voice check: `AIListenVoicePlan` / `AIListenVoiceMeasure` / `AIListenVoiceReport`, the same code as listen voice, over
  every audio track whose clips are all voice (at most 11), inside the checked range.
- Each sound that may drag past its picture rendered on its own over its frames after the cut (`DeliveryStemPower`; at most 40;
  more is a limitation).

### Rules

| Kind | Rule | Where the lines come from |
| --- | --- | --- |
| `audio_cut_jump` | At a picture cut (the top full-frame picture changes, V1 or an upper clip; black counts; a split of one take is not a cut) the place sound in `CutSoundWindows`' 0.3 s each side jumps 6 dB or more in the full band or above 200 Hz (the larger is reported), the louder side above −45 dBFS, and nothing covers it: a voice / music / effects bed sounding 0.3 s on both sides no more than 6 dB under the louder side at the cut and above −50 dBFS (`CutSoundLevelPlan.bedMargin`, the rule set_transition sound=bed meets); a music accent within ±3 frames; music entering or stopping (end or fade-out start) within ±2 frames, heard on that side (above −45 dBFS over the 0.1 s cell one cell away from the cut, the research's cells: music ending with its file fades in the last frames before the cut); an effect starting within ±3 frames no more than 3 dB under the louder side (a hit); an effect ending within ±2 frames no more than 6 dB under it over that cell (a riser's top); a line in a picture's own sound (transcript or provenance subtitles) starting or ending within 0.35 s. A narration line starting −2 to +4 frames from the cut is noted (`voice_head_frames`), never a cover. | The human film: 23 of 24 cuts with a 6 dB jump were covered, uncovered ones differ by 3.4 dB at most; the two cuts the user named (MCP-37) |
| `audio_linger` | An object (named in `sounds`) belongs to the shot it sounds under longest (a sound brought in early belongs to the next shot); after that shot cuts away it sounds over 2 frames above −50 dBFS (counted from the cut while it stays above). A picture's own sound detached to an audio track (its linked picture, or the picture of the same file under its start) stands 6 dB over the far side's bed (everything else except that picture's sounds) for over 2 frames. Not reported when the next picture is the same file. | The user's metal clang (MCP-38) and the board's lines; not validated on other films |
| `audio_voice_masked`, `audio_two_voices` | listen voice's verdicts (`probably_unintelligible`, `may_be_hard`; `two_voices`) with the main maskers | The blind test ([listening engine](listening-engine.md) section 7) |
| `audio_voice_loud` | listen voice's grey hint; listed apart from the suspects in `hints` (no evidence slot, not counted with them) | FL-61, two of the user's remarks |
| `audio_music_swell` | During a line of the voice check, the music group's voice band (300–3000 Hz) as a running 1 s median rises 6 dB or more above its value where the line began, with music above −60 dBFS for at least 30% of the line | Preview board v1.2's `music_swell`; the second draft's last line |

What these can't know: whether the next shot shows the same thing (mark it intentional), an effect's kind (a riser entering at
a cut counts as a hit), a voice inside a camera recording (no clean voice: a limitation), a cut inside one clip's source (the
`source_cut` checks own those). Effects, music, voice and ambience are never checked for lingering: a lag or a tail is a normal
way across a cut.

### Acceptance on the South Pole material (local only, nothing in the repo)

The second draft and the first draft exist as preview boards, not projects; a local harness rebuilt each as a project (pictures
on V1, each shot's own sound detached and linked, every board layer on audio tracks with its gain, fades and curve, `sounds`
from the board's kinds) and ran the real preparation and rules. The human film's project was read from a copy as JSON, roles
from the research's media table. None of it is committed.

- First draft (no music): both cuts the user named are reported — incubator → subway at 7.30 s, +19.0 dB above 200 Hz (the
  research measured +19.7), and bus → overpass at 11.10 s, −8.0 dB above 200 Hz (−8.3). In all 12 cut jumps, 10 at the same
  cuts the research rule reported; the others are at the 6 dB line (−6.0, +6.5) or a riser entering at the cut.
- Second draft: no cut jump (the research rule: none either); the metal clang lingers 7 frames past 0:10.91 (−25 to −42 dBFS;
  the research counted 6); ended 2 frames after the cut it is no longer reported. The last line is `may_be_hard` (ESTOI 0.40)
  with the music rising 11.8 dB in the voice band (the research: "12 dB in the voice band").
- Human film (47 picture cuts in SkyCut's reading, 45 in the research's): exactly one cut jump, 0:10.00 aerial ice field → ship
  in the ice, +11.6 dB (the research: +13.9), the deliberate held breath the research found uncovered too; mark it intentional.
  The run had the media table's spoken lines as provenance subtitles (what a transcript would give): the only cover at 1:01.64
  is the driver's line ending there, so without speech evidence that cut is reported too. Two readings had to follow the research exactly to get there:
  accents (1:18.44 is covered only by one) and "heard on that side" over 0.1 s cells (2:14.02: the music ending with its file).
  No linger; voice clarity was not measured, the human film's voices share tracks with other sounds (listed in limitations).
- The first draft's two narration lines that overlap by 60 ms on two tracks were both `two_voices` (ESTOI 0.85, 0.78): fixed
  ([case](../bugfixes/2026-11-18-two-voices-from-a-neighbouring-line.md)).

### Checks

`checks/VideoInspection/SoundTierRuleChecks.swift` tests the rules on controlled numbers: every cover and its edge, the 200 Hz
reading against a 100 Hz + 1 kHz window, the accent reading on a thump every 0.5 s, where the picture changes, object and
camera counting, the lead belonging to the next shot, the swell's running median, listen's verdicts as report entries,
`sounds` parsing and role precedence, the stem split keeping every segment, and a cut jump and a grey hint moving to
`intentional` once marked (`AIInspectionReview.partition`, the path the real tool's marks take; DeliveryChecks marks through the
tool). `SoundTierChecks.swift` runs two real jobs on synthetic sound. The first, over the whole 6 s (noise beds cut at 3.0 s, a
decaying clang, a 1.2 s speech-like line under loud noise, music rising under it): a cut jump, a 12-frame linger, a masked line
and a swell; wrong `sounds` refused before a job, `sounds` refused next to `intentional`. The second, 2.5–6.5 s of a timeline
with two covered cuts: a music bed across 3.0 s, quiet music with a low thump 2 frames after 6.0 s, and the clang ended a frame
after its cut — nothing reported. Only two jobs: the binary links the debug build, and its 480 s deadline was overrun on CI when
the first version ran five (2026-11-18). `SRTFLOW_INSPECTION_CASE=sound scripts/check-video-inspection.sh` runs only these.

Reverse controls (2026-11-18), each restored afterwards: with the four second-tier entries skipped in the registry run, five
production assertions fail (the jump, the linger, the masked line, the swell, the jump's key); with the bed cover removed, the
rule's bed case and the covered-cuts job fail; without the accent cover, the rule's accent case and the covered-cuts job fail
(the 6.0 s jump comes back); with an object belonging to the shot under its start, the lead case fails; with the 200 Hz reading
replaced by the band meter's 300 Hz, the window reading fails; without the two voices' 0.5 s overlap, the mix-layers hand-over
case fails (`["clear", "two_voices", "two_voices"]`).

Manual regression before release:

- [ ] Inspect a cut where the place's sound clearly jumps and listen: the jump is reported; cover it with set_transition sound
      (bed or crossfade), inspect again, the jump is gone.
- [ ] Name an object with `sounds` that rings into the next shot; listen; shorten it to end within 2 frames of the cut, inspect again.
- [ ] A narration track under loud music: the voice check's lines appear as findings and the grey hint under `hints`; mark one
      intentional and see it move to the intentional list.
