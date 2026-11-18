# 声音场景：喇叭 / 室内 / 室外

> 2026-09-24 落地；2026-10-01 PR3b 起效果链跑在音频引擎的渲染块里（tap 那条路删了）。改 `VideoEditSoundScene*.swift`、
> 引擎里的 `SceneBox` / `mixScene`（`AudioEngine/AudioTrackFeeder.swift`、`AudioTrackRenderer.swift`）、检查器的声音那一块
> （`VideoEditInspector+Sound.swift`）之前必读。
> **Since 2026-11-18, section 5**: a clip's voice-band cut (`voice_band_db`, `VoiceBandFilter`) runs in the same render
> block, between the segment gain and the scene; read it before touching the render block's order.
> 拍过的板与探针见 [声音场景方案](../plans/2026-09-24-sound-scenes.md)；同一条声音链上的另外几环见
> [声音：音量与渐入渐出](audio-fades.md)、[推子与电平表](audio-mixer.md)、[成片的声音](export-audio-mixdown.md)。

## 一、模型

- `EditClip.soundScene: SoundScene?`：`kind`（九种，分三组）+ `amount`（强度，0 = 原声）+ `first` /
  `second`（场景自己的两个旋钮，都是 0…1）。喇叭类的旋钮是「失真」「音质」，空间类是「空间大小」「距离」
  （`SoundSceneKind.controls`）。
- 九种：**喇叭**（电话、扩音器、收音机）、**室内**（房间、浴室、大厅）、**室外**（空旷室外、森林、山谷回声）。
  海边不做（没有海浪声就和室外一样；环境声是音效库的事）。
- 换种类：强度留着，两个旋钮回到新场景的默认值（`SoundScene.switching`）。「重置」：种类不变、三个数回默认。
- 读盘和写入都走 `sanitized`（NaN 回默认、越界夹进 0…1）。**认不出的种类整个不认**（更新的版本加的），
  当作没有场景，别的设置照常读回来。
- 编辑入口只有三个（`TimelineState.setSoundSceneKind` / `setSoundSceneValue` / `resetSoundScene`），
  单选、框选批量都走它们；没有声音的段跳过。
- 分割：两半各带同一个场景（`split` 里显式抄；右半是按 init 重建的，**新字段不抄就丢**）。
  分离音频：场景跟着声音走（`detachedAudio`）。
- 工程格式 **v20**，按需写键（见 [工程文件](video-edit-project-file.md)）。

## 二、声音怎么算（预览和成片是同一份）

**效果跑在音频引擎的渲染块里**（`SceneBox`：一段一条链，`AudioTrackFeeder` 在喂样线程上建、`AudioTrackRenderer.mixScene`
每拍跑），用 `AudioUnitRender` 驱动 macOS 自带的效果单元（`SceneChain`，AUNBandEQ / AUDistortion / AUReverb2 / AUDelay，
配方在 VideoEditSoundSceneRecipe.swift）。成片是同一个引擎离线渲的（[成片的声音](export-audio-mixdown.md)）——
「只做一遍」就是这么成立的。2026-09-24 探针（那时跑在 tap 里）：离线和实时逐位相同、分块大小不影响结果、延迟为 0。
2026-09-24 到 2026-10-01 效果跑在合成音轨的 tap 里（`SceneTrackRenderer`），那条路带来的几条规矩（段增益要在 tap 里乘、
余音要垫载体、空转回调不碰链、换下来的链多挂一拍）随它退役。

八条不许改的：

1. **效果排在段增益之后、轨道推子之前**：段增益（音量 / 曲线 × 渐变）→ 效果 → 轨道推子 → 总推子。人声淡出时
   余音照常散完；拉推子连余音一起变小（Logic 的 region → insert → fader）。自检第 9 组「淡出之后余音照常散」钉着。
2. **每段一条效果链**，余音各自散：段结束之后流还活着、喂零、链继续吐余音，直到 `tailFrames`（配方按旋钮算出来的
   余音长度）过去才关流；紧跟着的下一段进它自己的链，两边相加。所以**分割不改声音**（混响是线性的，自检钉着）。
   余音不用「载体」，也不把时间线拉长（成片按总长截）。
3. **加 / 去掉场景要重开那一段的流**（`TimelineAudioEngine.sameStructure` 看每段有没有场景），**种类和旋钮只换链的
   参数**（`updateGains` → `applyScene`：同一种场景只改参数，换种类重建链），拖滑杆不闪画面。`differsOnlyInAudioMix`
   沿用「有没有场景算结构」的口径：加 / 去掉场景仍走整条预览重建（引擎本身只需重开流，改成快路径是后续一刀）。
4. **位置跳了就复位效果链**（seek、开播）：渲染块看这一拍接不接得上上一拍（`renderedUpTo`），接不上就 `reset`，
   旧的余音不许拖进新位置。
5. **旋钮一律自己换算成参数，不载入单元的出厂预设**：AUReverb2 载入预设后 Dry/Wet 读回来是 0.5（满量程 100）。
6. **喇叭类先削波、最后限带**：反过来的话削波会在限好的频带外重新长出高次谐波（自检量到过：6kHz 以上几乎
   没削掉）。
7. **响度补偿用同一串处理量出来**（`SceneLoudness`：48kHz 立体声、−20 dBFS RMS 的语音样噪声、量后一半），
   按种类和两个旋钮（取到 1%）缓存。**串了两个单元的链会把输入那一块写成输出**：量输入能量、加原声那一份
   都必须在渲染**之前**（第一版补偿全是 0 dB 就是这么错的）。喇叭类的削波跟着电平走（素材越响失真越重，
   真喇叭也这样），补偿按常见人声电平量，响的素材会偏一点。
8. **链在喂样线程上建、渲染块里跑**：`SceneBox` 经 `AudioPublished` 交给渲染块（原子指针交换，发布方留最近 8 份不放），
   渲染线程不分配、不加锁。

**「强度」是在场景输出之外、和原声交叉混的**：输出 = (1 − 强度) × 原声 + 强度 × 补偿 × 场景（`mixScene`）。各单元自己的
干湿比是「场景里听到的那一份」（喇叭类全湿，空间类按「距离」混一部分直达声）。链没渲出来就全给原声，不许凭空少一截。

**电平表看的是效果链处理完的声音**：渲染块把混完的那一拍（已乘段增益、场景、轨道推子）交给这条轨的槽，总表再含总推子。

**波形照旧画「原声 × 增益」**，不画效果（画效果就得逐段重算，丢掉「一个文件读一次」的前提）；块上的小图标
（喇叭 / 房子 / 树，按组）表示挂了场景。

## 三、界面

- 检查器「音量」下面一块（`SoundSceneControls`）：标题单独一行，下面是铺满的下拉（按三组分节；**不许锁宽度**，
  见 [检查器的排版](inspector-layout.md)），选了场景才出现「强度」和两个旋钮
  （都显示百分比）以及「重置」。下拉是离散控件，直接 perform 一步；滑杆 liveApply + 松手 endLiveEdit，
  拖动中 `previewAudioLive` 把新配置交给引擎（只换链的参数），当场听得见。
- 框选多段时同一块批量套用（有声音的段），各段种类不一样时下拉显示「多个值」、不给滑杆。
- 提示文案说清楚「只能加空间感，去不掉素材里本来的回声」。

## 四、回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-project-file.sh`（第 29 组） | 默认值、换种类留强度、夹紧、只动有声音的段、重置 / 去掉；拖旋钮和换种类只换 audioMix、去掉场景要重建；分割两半都带、分离音频带走；按需写键、v20、往返保真；认不出的种类当作没有、越界夹回 |
| `scripts/check-audio-fade.sh`（第 9 组） | 真实 PCM（预览 = 引擎离线渲、成片 = 真跑导出）：电话削掉 6kHz 以上（宽频素材、四阶量）；大厅的余音越过段尾且慢慢散；淡出之后余音照常散（效果在段增益之后）；强度 0 = 原声；九个场景默认值下和原声差不过 3 dB；成片 = 预览；挂着电平表渲和不挂一样、电平表看得见余音；分割前后一样 |
| `scripts/check-audio-engine.sh`（第 11 组） | 强度 0 = 原声（对着 oracle 逐窗口比）；浴室的余音越过段尾且越散越小；挂了场景的声音和原声不一样。反向验证（2026-10-01）：渲染块不过效果链 → 八条红 |

**反向验证（2026-09-24，tap 那条路）**：去掉载体 → 余音三条红（段尾后静音）；成片不挂场景 tap → 电话那条红；
`split` 不抄场景 → 第 29 组「分割后两半是同一个场景」红（开发时就是这条先红的）。

**人工回归**（发版前实机）：

- [ ] 九个场景逐个套在一段口播上听：电话窄而扁、扩音器有喇叭口的炸、收音机比电话宽；房间短、浴室亮而密、
      大厅长；空旷室外几乎干、森林有一条暗暗的尾巴、山谷一声声变暗的回声。
- [ ] 播放中拖三个滑杆：当场听得见、不卡、画面不闪；松手 ⌘Z 一步撤回。
- [ ] 选 / 换 / 去掉场景：换种类画面不闪；加上、去掉场景会重建一次（和改速度一样）。
- [ ] 段尾贴着最后一个字：大厅 / 山谷的余音越过段尾散完；段尾设 1 秒淡出，余音照样散。
- [ ] 播放中 seek 到别处：不会带着上一处的余音。
- [ ] 导出后听成片，和预览一样；框选几段批量套用。
- [ ] 电平表在余音那一截还在跳。
- [ ] 英文界面下选中挂了场景的段：下拉上显示场景名，「Mute」和每个滑杆后面的百分比都完整可见（[检查器的排版](inspector-layout.md)；2026-09-24 首测时整条右边被裁掉过）。

## 五、Voice band: lowering only 300 Hz–3 kHz of a clip's own sound (2026-11-18, MCP-30 first slice)

Production feedback MCP-30 / FL-55: the last line of the South Pole draft was masked by the shot's own low rumble (50–800 Hz,
as loud as the voice inside the voice band). Lowering that clip's whole sound by 10 dB cleared the line but took the lift-off
hit at 50 Hz down by 10 dB as well. `edit_clip voice_band_db=-10` lowers only the voice band of that clip's sound and keeps its
lows and highs. Code: `VoiceBand` (VideoEditVoiceBand.swift: range, cleaning, the band's gain), `VoiceBandFilter` /
`VoiceBandRendering` (AudioEngine/VoiceBandFilter.swift: the DSP and how a stream runs it), `AudioTrackRenderer` (where),
`EditClip.voiceBandDB` (the setting), `AIClipDetails` (the AI's parameter).

Rules (only this way):

1. **One filter, in the engine's render block**, so preview, export (the same engine offline), `listen mix=true` / `voice=` and
   the meters all hear the same thing. Order: segment gain → voice band → scene → fader.
2. **The split** (`VoiceBandFilter`): Linkwitz–Riley crossovers of the 4th order at 300 Hz and 3 kHz (each two Butterworth
   biquads in a row; the low band also goes through the 3 kHz crossover's all-pass), out = low + g · mid + high. The three bands
   add up to an all-pass, so at g = 1 the level is flat at every frequency; below 1 only the middle band goes down. Measured at
   −10 dB: 50 Hz 0.00, 100 Hz −0.07, 300 Hz −3.6, 500 Hz −8.1, 1 kHz −9.6, 2 kHz −7.4, 3 kHz −3.6, 8 kHz −0.08 dB (at −20:
   1 kHz −18.6, 100 Hz −0.1). Double precision (the 300 Hz sections sit near the unit circle at 48 kHz); 48 kHz only (the
   engine's rate).
3. **Real time** (`VoiceBandRendering`): no allocation, one filter per stream, only the renderer touches it. It starts from
   zero when the position jumps (seek, start: like the scene chain) and the first time the stream needs it; once running it
   keeps running even back at g = 1 (an all-pass then: switching it off would jump the phase); a changed depth moves g
   linearly across one block (no zipper).
4. **A parameter, not structure**: the depth reaches a live stream through `SegmentUpdate.voiceBand` (an atomic per stream),
   so changing it is an audio-only change (`differsOnlyInAudioMix` neutralizes it): `updateGains`, no stream reopened, no
   picture rebuild. `Segment.Structure` does not include it.
5. **Model**: `EditClip.voiceBandDB`, −30…0 dB (`VoiceBand.range`; 0 = off), not in `init`. Split halves both carry it,
   separated sound carries it (the picture is muted), the clipboard / duplicate carry it through Codable; a voice-changed
   piece does not (it is a voice: cutting its own voice band would thin it). Saved only when ≠ 0, project format **v38** (an
   older writer would drop it and the film would change); the reader cleans it (non-finite → 0, clamped to the range).
6. **The waveform and `listen clip_id` do not show it** (same as scenes: the waveform is "source × gain", and clip listen
   reads the file with gain and fader but no effects); `listen mix=true` / `voice=` render through the engine and do.

AI: `edit_clip` / `edit_clips` `voice_band_db` (requested / applied in the result; out of range is refused with the allowed
range and a suggestion; a clip with no sound refuses it); get_timeline lists `voice_band_db` on clips that have one.

Known limits (first slice): one constant depth per clip (split the clip to change it over time; a voice-band dip that follows
the lines like `set_track duck_others_db` is a later slice); no control in the inspector yet (the AI sets it, get_timeline shows
it); edges fixed at 300 Hz and 3 kHz.

Checks: `scripts/check-audio-engine.sh` group 16 (`checks/AudioEngine/VoiceBand.swift`: the filter on steady sines — 50 /
100 Hz and 8 kHz within 0.25 dB, 1 kHz down by the depth within 0.6 dB, g = 1 flat within 0.01 dB, 64-frame blocks = one run;
the engine's offline render of a three-tone clip with −10: 1 kHz down, 50 Hz and 8 kHz kept; a cut given through
`updateGains` sounds like an engine built with it, and is not structure); `scripts/check-project-file.sh` group 51
(`checks/ProjectFile/VoiceBand.swift`: cleaning, v38 gate and key only when set, round trip, a tampered depth clamped, split,
separated sound, audio-only change); `scripts/check-mcp.sh` (`VoiceBandToolChecks`: read, out of range refused with a
suggestion, applied, summary, 0 takes it off, no-sound clip refused, schema range = the model's).

`scripts/check-parameter-limits.sh` (`checks/ParameterLimits/VoiceBandAppChecks.swift`) runs it through the real App objects:
edit_clip's own plan / apply sets it and reports it, the export mixdown has 1 kHz about 10 dB down and 50 Hz / 8 kHz kept, one
undo takes it back, out of range changes nothing.

Reverse verification (2026-11-18, each broken on purpose, the checks run, then restored byte for byte): the renderer not
calling the filter → engine group 16 red (the 1 kHz tone through the engine unchanged); split not copying the cut, the
fast-path neutralizer keeping it, the v38 gate always false → project-file group 51 red (3).

Manual regression:

- [ ] A shot whose own sound has a low boom and mid-range noise under a narration line: `edit_clip voice_band_db=-10`. The
      boom keeps its weight, the line gets clearer; preview and export sound the same; ⌘Z takes it back.
- [ ] Change it while the clip plays (−10 → −4): no click, the change is heard at once.
