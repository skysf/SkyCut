# 音量曲线：画在段上的音量自动化

> 2026-09-23 落地。改 `VideoEditVolumeCurve.swift`、`addCurveRamps`、时间线上的曲线手势之前必读。
> 2026-09-24 起成片的声音就是预览这份混音离线读出来的（[成片的声音](export-audio-mixdown.md)），
> 导出那一侧的 `aeval` 实现随之退役，第二节里它的那几条留作历史说明。
> 方案与产品决策见 [声音编辑方案](../plans/2026-09-23-audio-mixing.md)；
> 同一条音量链上的另外两环见 [声音：音量与渐入渐出](audio-fades.md)、[推子与电平表](audio-mixer.md)。
> **Since 2026-11-18, section 5**: ducking under speech (`set_track duck_others_db`, `SpeechDuck*`) draws its dips into these
> curves; read it before changing ducking or anything that reads a duck out of a curve.

## 一、模型

- **曲线属于段**：`EditClip.volumeCurve`（复用关键帧的 `KeyframeTrack`），值是 **dB**，
  点锚在**源时间**上。挪动、分割、裁头尾、变速都自动正确（同 [关键帧](keyframe-animation.md)
  那一条）：分割时两半各带一份完整的点，切口两边的线连续。
- **有点时曲线取代 `volume`**；没点时整段就是 `volume`。三条规矩保证「编辑动作本身不改声音」：
  - 加点取**此刻线上的值**（第一个点也一样：一个点的曲线就是一条水平线）；
  - 删掉最后一个点，把它的值固化进 `volume`（线原地不动）；
  - 「去掉曲线」回到画曲线之前的那条水平线（有曲线期间 `volume` 不动）。
- **插值是 dB 线性**：屏幕上画的直线 = 听到的那条线（纵轴是 dB 刻度，与检查器滑杆、推子同一个）。
- 同一个点的容差是**半毫秒**（`VolumeCurveEditing`），**不用关键帧的半帧容差** ——
  放大到一帧 200pt 之后，半帧就是 100pt，两个隔得老远的点会被当成同一个。
- 读盘先消毒（`VolumeCurve.sanitized`）：丢掉非有限的点、dB 夹进 [−60, +6.02]。
- 分离音频（`EditClip.detachedAudio`）把曲线、音量、渐入渐出一起带走 —— 视频那段被静音，
  留在它身上的曲线就再也听不见了。
- 工程格式 **v19**，按需写键（见 [工程文件](video-edit-project-file.md)）。

## 二、折线表（成片就是预览这一份）

曲线在数学上是 dB 直线，增益表（`GainTable`）只有「幅度线性」的斜坡，所以要切成弦。
**`VolumeCurveSampling.breakpoints(for:)` 是唯一的切法**：

- 每根弦最多跨 1.5 dB，误差 ≈ (0.1151·Δ)²/8 ≈ 0.03 dB（自检钉着 < 0.05 dB）。
- 预览和成片之间**没有**这 0.03 dB —— 成片就是预览那份混音读出来的。
- 表里的时刻是**离段起点的时间线秒**；增益含静音，不含渐变和推子（那两样调用方乘）。

### 预览和成片（`AudioGainRamps.addCurveRamps`，AudioEngine/AudioGainTable.swift）

- 没画曲线的段一行不变地走老路（`addVolumeRamps`）；只有画了曲线的段走折线。
- 渐变窗口里线性渐变 × 线性折线是二次曲线，按 16 等分补点。
- 钉点同 `addVolumeRamps`（[audio-fades](audio-fades.md) 第 7 条）：钉的值是这一段起点真正的增益。
- 相邻两点落在同一个 1/600 秒格子里就并掉（零长斜坡没有意义）。
- 只改曲线属于「只换增益」（`differsOnlyInAudioMix` 已经把它抹平），引擎 `updateGains`，画面不闪。
- 2026-10-01 PR3b 之前这张表还要原样铺进 AVFoundation 的 audioMix（预览）；现在只有引擎这一份读者。

### 导出（已退役，2026-09-24）

成片改读预览混音之前，导出在 ffmpeg 滤镜链上另算一份（`ExportAudioGain.gainSteps`）：画了曲线的段在链上多一个 `aeval=exprs='val(ch)*(树)':c=same`，树是折线表的**平衡 if 树**，
叶子是每段的一次式。2026-09-23 用随包的 ffmpeg 8.1 实测定下的几条：

1. **放在 `atempo` 之后、`adelay`（含主轨首尾定格的 `holdSteps`）之前。** `t` 在
   `asetpts=PTS-STARTPTS,atempo…` 之后从 0 起、按输出时间走；`adelay` 垫的静音没有时间戳，
   在那里读到的 `t` 是 NaN 或垃圾值。主轨段因此要把时间轴**减掉 `renderHoldHead`**
   （减漏了整条曲线错后一截，check-audio-fade 第 7c 组钉着，反向验证量到 −5 dB 而非 −10 dB）。
2. **树的最右叶子必须是常数。** NaN 下 `lt()` 恒为假，每层都走右边；最右是常数，NaN 的
   `t` 才算不出 nan。挪到 `adelay` 后面没出 nan 就是靠这个兜住的 —— 那是形状碰巧，
   不许当成设计依赖。
3. **平衡树，不许写成「各段相加」**：`if` 是惰性求值，平衡树随 log N 涨（N=4000 时 48 秒
   立体声多花 0.85s）；相加是线性的，N=1000 要多花几分钟。嵌套超过约 100 层 ffmpeg
   直接拒绝（只报 "Failed to configure output pad"），平衡树的深度是 log2(N)+几层。
4. **数字全精度**（`exactNumber`）。`fmt` 只留三位小数，量到 0.02–0.04 的增益误差。
5. 表达式整个包在单引号里，逗号不用转义；里面不许有 `:` 和 `|`。零长度的段跳过。
6. 滤镜图超过 256KB 改走 `-/filter_complex <文件>`（`filterComplexArguments`）：
   macOS 的 ARG_MAX 是 1MB 且整条命令行加环境变量共用，每段一棵树攒起来能顶到。

没画曲线的段是 `volume=`。这整套（以及第 6 条之外的五条规矩）只为让 ffmpeg 模仿 AVFoundation 而存在，
成片改读预览混音之后一并删掉；第 6 条的「滤镜图太大改走文件」对画面的滤镜图仍然有用，
留在 `ExportFilterScript`（`VideoEditExportFilterScript.swift`）。

## 三、界面：常显，贴着线操作（Final Cut 式）

- 音频块和视频块底部的波形带上**一直画着**那条线（琥珀色，`VolumeCurveOverlay`），波形区矮于
  10pt 不画。点是白心小圆。纵轴几何是纯值（`VolumeCurveLayout`，dB 线性 [−60, +6.02]）。
- **命中区只是贴着线的一条窄带（±5pt）加每个点的小圆（7pt）**（`VolumeLineHitShape`）——
  整块吃事件的话，音频块上的拖动 / 裁切 / 框选 / 点选全部失灵。刀片模式下整条让路。
- **窄带和小圆必须真正取并集**（`VolumeCurveLayout.hitPath`，`CGPath.union`），不许把圆
  append 进描边路径：`contentShape` 按非零环绕数判里外，重叠处正负抵消成 0，而圆心本来
  就压在线上 —— 每个点的正中间都会点不中，按下去落到块上（[案例](../bugfixes/2026-09-23-volume-curve-points-unclickable.md)）。
- 一个 `DragGesture(minimumDistance: 0)` 管三件事，按下那一刻就接管（靠「子手势失败了再
  落到父级」分流的话，点击和拖动的归属说不清）：
  | 操作 | 结果 |
  | --- | --- |
  | 拖线 | 这一段上下：两点之间动两端，第一个点之前 / 最后一个点之后只动端点，没有点改 `volume` |
  | 拖点 | 改时间和值，时间夹在邻点之间（不许悄悄换顺序）；按住 ⇧ 只改值。**从点自己的位置出发、跟着指针挪同样的量**（`VolumeCurveLayout.dragging`），不是搬到指针底下 —— 偏着抓不跳 |
  | ⌥ 点线 / ⌥ 点点 | 加一个点（取线上此刻的值）/ 删掉它 |
  | 普通点击 | 选中这一段（同块本体，⌘ / ⇧ 加选） |
  挪够 2pt 才算拖；拖动中指针旁边显示 dB 值。
- **拖动中不写 `TimelineState`**（[拖动手势](timeline-drag-gestures.md) §0）：线画在哪只由视图的
  `session` 决定；声音靠 `VideoEditProject.previewAudioLive` 拿临时状态算 audioMix 换上
  （节流 ~20 次/秒），**当场听得见**；松手 `commitVolumeEdit` 落一次（一步撤销、快路径不闪）。
  手势被打断（`onEnded` 不来）时由 `@GestureState` 收尾、`refreshAudioMix` 换回真状态的 mix。
- 拖动期间扫帧 peek 让位（`isDraggingVolume`），调音量时画面不跟着指针乱跳。
- 检查器的音量滑杆：有曲线时显示播放头处（不在段里取段起点）线上的值，**拖它 = 整条曲线
  一起平移**、形状不变，下面一行小字说明；「回到 0 dB」按钮连曲线一起去掉。右键菜单有
  「去掉音量曲线」（回到画曲线之前那条水平线）。

## 四、回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-project-file.sh`（第 28 组） | 插值 / 夹紧、加点不改声音、删点固化、挪点不越过邻点、拖一段线动哪几个点、平移不叠加、折线误差 < 0.05 dB、变速、分割连续、分离音频带着走、存盘按需写键与 v19、改坏的 JSON 夹回来 |
| `scripts/check-audio-fade.sh`（第 7 组） | **真实包络**（预览与成片）：音频轨曲线 × 推子、去掉曲线的反例对照、2 倍速、主轨接缝后首帧定格的时间轴、曲线段的钉点、快路径与重建等价 |
| `scripts/check-project-file.sh`（第 28 组，几何） | y ↔ dB 往返、上下留边、拖出去夹住、折点只画段内的点、抓点半径 |
| `scripts/check-project-file.sh`（第 28 组，命中区与拖点） | 每个圆心 / 圆内 / 折点都按得中、离线 20pt 按不中（并集，不是 append）；拖点是相对位移：没挪不动、竖着拖时间一丝不动、⇧ 钉住时间、越不过邻点 |
| `checks/timeline-drag-wiring.sh`（音量线一节） | 命中区是窄带且走 `hitPath`、拖点走 `dragging` 不直接 `moveVolumePoint`、拖动中只走 `previewAudioLive` 不写 state、松手走 `commitVolumeEdit`、刀片模式让路、音频块和视频块两处都挂 |

2026-09-23 反向验证（各自确认守卫会红；前两条针对的导出实现已于 2026-09-24 退役）：导出去掉 `renderHoldHead` 那一减 → 7c 红 2 项；
预览不乘推子 → 7a 预览红 5 项；导出不乘推子 → 7a 导出红 5 项；命中区换回 append →
第 28 组红 15 项；视图换回「append + 按指针绝对位置搬点」→ 接线守卫红 3 项（[案例](../bugfixes/2026-09-23-volume-curve-points-unclickable.md)）。

**人工回归**（自动化够不着，发版前实机验证）：

- [ ] 音频块上看得见琥珀色的线；指针靠近线变 ↕，离开线（块的别处）拖动仍是挪块、边缘仍是裁切。
- [ ] ⌥ 点线加点，线和声音都不变；拖点改时间和值，拖不过邻点；⇧ 拖只改值；⌥ 点点删掉。
- [ ] **按在点的正中间**拖得动、⌥ 点删得掉；偏着抓一个点（圆内、不在圆心）拖，点不跳。
- [ ] 两点之间拖线：那一段整体上下；播放中拖，**当场听得见**音量变化；松手 ⌘Z 一步撤回。
- [ ] 拖线时画面不跟着指针扫帧；刀片模式下点在线上落刀。
- [ ] 视频块把行拉高，底部波形带上同样能画曲线；分离音频后曲线跟着声音到了音频轨。
- [ ] 检查器：有曲线时滑杆显示播放头处的值，拖滑杆整条线一起动；「回到 0 dB」连曲线一起去掉。
- [ ] 分割一段带曲线的声音：切口两边的线接得上。导出后听，与预览一致。

## 五、Ducking under speech: set_track duck_others_db (2026-11-18, MCP-29)

Production feedback MCP-29: with dialogue or narration the AI drew every dip under a line by hand with `volume_curve` (dozens
for a talky film), and in the South Pole draft the shot's own sound masked the last line, not the music. The shared recipe rule
(Voice and music 1) says: under speech, dip the music about 10 dB only while words are spoken, down 0.3–0.5 s before a line,
back 0.5 s after, not between words. `set_track track=<the voice's track> duck_others_db=-10` does it for every line in one
call. Code: `SpeechDuck` (the numbers, windows), `SpeechDuckCurve` (one clip's curve), `SpeechDuckPlanner` (which clips),
`SpeechDuckLines` (where the lines come from), `SpeechDuckReport` (the result), `AISpeechDuckTool` (plan / apply). Guide:
`skycut_guide topic=set_track section=ducking`.

Rules (only this way):

1. **A duck is volume automation, drawn into each clip's curve.** Nothing new in the model, the engine or the export: the dip
   is the amber line the user sees and can drag, preview and export render it through the one gain table (section 2), and the
   edit takes the audio-only fast path (no picture rebuild). One call = one `perform` = one undo step: `AISpeechDuckTool.apply`
   opens the `AIUndoGrouping.step` itself and only when a curve changes — a manual group left empty stays on the undo stack and
   ⌘Z would do nothing (measured 2026-11-18), so a call that finds every dip in place commits nothing. The lines are read
   before (await); a timeline changed meanwhile refuses.
2. **Windows** (`SpeechDuck`): a line `[s, e]` dips over `[s − 0.4, e + 0.5]`, fully down from `s` to `e`, linear ramps.
   Lines whose windows would leave the layer fully up for less than 1 s share one window (lines closer than 1.9 s): no pumping
   between sentences, and never anything between words, because a line is a sentence or a stretch between 0.6 s pauses.
   Depth −30…0 dB (`SpeechDuck.depthRange`, the schema's minimum / maximum); the shared rule asks for about −10.
3. **Lines** (`SpeechDuckLines`): every clip on the voice track (its own sound, or its linked sound when the sound was
   separated: `AISpeechCutTool.speechClip`) gives its lines from a cached transcript (sentences, transcribe's cache), else —
   for a sound file of its own (narration, voice-over; no camera metadata) — from its pauses (the waveform's windows by
   `VoiceLines`' rule: one rule, `VoiceLines.stretches`). A camera's sound without a transcript gives none (whatever else the
   camera heard would read as one long line): it is listed and the call says to transcribe first. The speech itself never dips.
4. **Which clips dip** (`SpeechDuckPlanner.targets`): every audible clip (sound, not muted, not hidden, track not hidden, not
   silent) on every other track, or only `duck_tracks` (A2+V1). The shot's own sound on V1 counts: it is what masked the line
   in the South Pole draft (MCP-39).
5. **How deep, measured, never stacked** (`SpeechDuckCurve`): under a window a clip sits `depth` dB under its own level next to
   the line — the edge line between its line at the window's two ends (an end beyond the clip takes the other end's level).
   The dip already there is measured as the deepest the line goes under the edge line through the hold (an earlier duck, or a
   duck drawn by hand), and the window moves the line by the difference times the window's shape. So calling again with the
   same depth changes nothing, another depth replaces the dip, 0 takes it out, and a hand-drawn duck under a line becomes the
   asked depth. Everything above the dip's floor keeps its shape and goes down with it: a crossfade's equal-power bump or a
   bed swell from `set_transition sound` ([cut-sound](cut-sound.md) rule 6 and rule 9 compose with it in either order).
   A clip only a ramp reaches (it ends in the attack or starts in the release) has the dip read on the deeper half of the ramp
   it covers, each point divided by how far down the ramp is there — however shallow the ramp is at the clip's edge. Never
   only "from half way down": on a clip ending a quarter of the way down that read nothing, so every call stacked another dip
   and 0 never took it out ([case](../bugfixes/2026-11-19-speech-duck-stacks-on-shallow-ramp.md)). A window reaching less
   than 1 ms into a clip leaves it alone (`SpeechDuckCurve.minimumReach`): the dip's two corner keys would merge into one.
6. **A clip wholly inside one window is left alone** (a sound effect on a word: its own level next to the line is unknown,
   and the fix is to move or lower it on purpose). The result lists it as `inside_lines`.
7. **Exact and bounded**: existing keys move by the offset at their time and keys go at the window's corners, so between keys
   the line stays dB-linear (the curve's own interpolation); values stay within `AudioGain`'s limits, and where the −60 dB floor
   stops a dip short the result says how deep it got (`adjustments`, `applied_db`).

Result: `track`, `duck_db`, `lines`, `windows` (first 40, `more_windows`), `ducked` (id, track, windows), `already_at_depth`,
`inside_lines`, `adjustments`, `lines_from` (transcript / pauses), `no_transcript`, `unreadable`, `next_step`.

Known limits: dips stay where they were drawn — after speech moves, calling again sets the dips under the new lines, but a dip
left under no line stays until removed with `edit_clip volume_curve`; when the new lines only partly overlap the old ones the
measured dip near the overlap can be off by the old ramp. The duck is full band: to keep a shot's low hits while clearing the
voice band, leave its track out with `duck_tracks` (a voice-band-only dip is MCP-30). A camera's speech needs a transcript
(macOS 26).

Checks: `scripts/check-mcp.sh` (`checks/MCP/SpeechDuckChecks.swift`: windows and merging, the curve on a flat / sloped /
bumped line, 2× speed, the volume floor, calling again (same, shallower, deeper, 0, a bump drawn after the duck), windows
across the clip's start and end, a kept key next to the start, a clip inside a line, a clip only the shallow part of a ramp
reaches — ending a quarter or 2 ms into the attack, starting 0.4 of the way down the release: same depth changes nothing, −20
sets, 0 takes it out — and one reaching 0.3 ms in left alone, which clips dip, lines from pauses, the result and the schema's
range); `scripts/check-parameter-limits.sh` (`checks/ParameterLimits/SpeechDuckAppChecks.swift`: real
App objects — a narration file's lines from its waveform, the music's curve and a sting ending in the first line's attack, the
exported mix 10 dB down under a line and back between, calling again changes nothing and leaves no empty undo step, 0 takes
every dip out in one step, undo takes each changing call back in one step, refusals change nothing);
`checks/MCP/router-wiring.sh` (apply's only `perform` sits inside `AIUndoGrouping.step`, opened only on a change, and the router
does not wrap it again).

Reverse verification (2026-11-18, each broken on purpose, the checks run, then restored byte for byte): the measured dip set to 0
(every call stacks) → 24 red in `SpeechDuckChecks` (same depth twice, −6 / −14 / 0 over an existing duck, a bump drawn after
the duck, the planner's second call, a window across the clip's start); windows never merged → 2 red; the speech's own sound
among the clips to dip → 2 red; apply's `perform` outside `AIUndoGrouping.step` → `router-wiring.sh` red. The App check caught
the empty undo step on its first run: a call that changed nothing still opened a group, and ⌘Z then undid nothing (5 red,
fixed by opening the step only on a change).

Manual regression (ears and a real window):

- [ ] Narration on A1, music on A2, a talking shot's sound on V1: `set_track track=A1 duck_others_db=-10`. The amber lines of
      the music and the shot dip under each line, the music comes up in pauses longer than about 2 s and stays down in short
      ones; playback sounds the same as the export. ⌘Z takes it all back in one step.
- [ ] Call again with −14: the dips get deeper, not doubled; with 0 they are gone.
