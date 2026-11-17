# 成片的声音：预览那个音频引擎离线渲出来

> 2026-09-24 落地「成片 = 预览那份混音」；2026-10-01（PR3a）起渲它的是预览同一个音频引擎。改剪辑导出的声音、
> `ExportAudioMixdown`（`VideoEditExportMixdown.swift`）、`AudioEngineConfig.make`、导出图里接音轨的那几行之前必读。
> 方案与探针见 [声音场景方案](../plans/2026-09-24-sound-scenes.md)、[音频引擎方案](../plans/2026-10-01-audio-engine.md)；
> 引擎本身的合同见 [音频引擎](audio-engine.md)。
> **2026-11-16 起第五节**：按层量混在一起之后的声音（`listen mix=true`；`AudioStemRender`、`MixMeasurement`、`MixBusMeter`、
> `MixBandMeter`）用的是这一份配置、这一个引擎、这一套限幅和响度量法，改它们之前读第五节。
> **Since 2026-11-17 every peak is a true peak** (`TruePeak`, ITU-R BS.1770-4 Annex 2, dBTP): the limiter holds −1 dBTP, and
> get_job reports the exported file's own peak (`ExportDeliveredPeak`) apart from the limiter's work — section 2 item 3.

## 一、一条管线

**成片的声音就是预览那份混音，由同一个引擎渲出来。** 导出时 `AudioEngineConfig.make(from:)` 从用户那一份状态算出
和预览**同一份**配置（段落、增益、渐变、曲线、推子、场景、变速），`TimelineAudioEngine` 的离线模式（`renderOffline`，
和实时播放是同一张图、同一段渲染代码）把整条时间线渲成 raw f32 立体声 48kHz 文件（工作目录里的 `audio-mixdown.f32`），
ffmpeg 只负责把它编成 AAC、和画面合在一起。导出图里**不许再出现任何声音滤镜**（`checks/export-audio-single-pipeline.sh` 钉着）。

2026-09-24 到 2026-10-01 之间这一步是 AVFoundation 那条路：`VideoEditCompositionBuilder.build` + `makeAudioMix` 建合成、
`AVAssetReaderAudioMixOutput` 读出来。预览换成引擎之后成片也跟着换，不然预览和成片又是两份实现。

以前导出在滤镜图里另搭一整套声音链（每段 atrim → atempo → volume / aeval → afade → adelay，
主轨 concat / acrossfade，最后 amix），和预览的 AVFoundation 混音各算一份，靠一堆「先后顺序」
规矩对齐。用户嫌每个声音功能都要做两遍（「两遍效率很低」），于是只留一条：音量、渐变、曲线、
推子、转场的交叉淡变、首尾定格的静音，以及之后的声音场景，都只在预览这一份里实现。

## 二、七条约束

1. **读的是用户那一份状态。** `render(state:)` 传展开之前的状态，`AudioEngineConfig.make` 自己
   排序、展开转场、滤掉藏起来和静音的，**展开只许一次**。导出图 `plan()` 入口会展开自己那一份（画面要用），
   传给混音的是展开之前留下来的 `requested`。
2. **正好 `duration` 秒。** 引擎按时间线的帧渲到正好 `frames`（最后一截只有画面时渲出来的就是静音）；
   `FrameSink` 照旧补短截长，和画面一样长 —— 以前的滤镜链靠 `anullsrc` 补齐，这条账不能丢。
   配置里一条轨都没有（时间线上没有一个出声的段）时 `.silent`，导出图垫一路 `anullsrc`，成片照样有一条音轨。
3. **中间文件是 f32，写之前过真峰值限幅器（上限 −1 dBTP；2026-11-17 之前名叫真峰值、量的其实是采样峰值，上限 −1 dBFS），限幅前的峰值、压了多久多深、整段响度都要报出去。**
   各轨直接相加、不压不限（同以前的 `amix normalize=0`），和可以过 0 dBFS；引擎渲出来的 float 也不削。可是交给 AAC 编码器的
   信号过了 0 就不可预期（2026-09-30 探针：两轨各 +6 dB 叠加，成片 RMS 比混音掉 4.5 dB、峰值冒到 +12 dBFS、主推子降 3 dB 成片只降 2 dB，
   [案例](../bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md)）。第一版（#102）是逐采样硬削；同一天用户拍板换成限幅器
   （[方案](../plans/2026-09-30-export-limiter-and-easing.md)）：
   - **`ExportPeakLimiter`（流式、纯值）**：上限 `defaultCeiling` = 0.891（−1 dBFS，留 1 dB 给编码器的过冲，同配音文件 `AIVoiceLevel.peakCeiling`），
     前瞻 5 ms（240 帧）、释放约 80 ms。每帧算「要压到多少」r = min(1, 上限 / 最响的声道)；前瞻窗内取最小 r（单调队列）；再做同样长的
     滑动平均把台阶变成斜坡 —— 数学上每帧的增益仍 ≤ 它自己的 r，所以**一个采样都不超过上限**；往上只按释放时间一阶慢慢回。
     信号延迟 5 ms：写盘前先攒够前瞻、`flush` 把末尾冲干净，**总长度不变**（第 2 条那本账照旧）。没过顶的地方逐采样原样；
     稳态的过顶正弦出来是等幅的干净正弦，不是方波。
   - **`ExportLoudnessMeter`（流式、纯值）**：BS.1770-4 的整段响度 —— K 加权（`AudioKWeighting`，48 kHz 系数只写这一处，合成音效也用它）
     → 400 ms 块、100 ms 步 → 绝对门限 −70 LUFS → 相对门限 −10 LU → 平均。喂的是限幅之后、真写进文件的采样。只报、不归一
     （用户不要响度目标）。
   - **True peak (2026-11-17)**: a peak between samples can be higher than any sample (a 12 kHz tone read 45° off its crest shows
     samples 3 dB under it), and decoders and the AAC encoder reproduce it. `TruePeak` measures it the BS.1770-4 Annex 2 way: 4×
     oversampling with the Recommendation's 48-tap interpolator (four phases of 12), absolute values; a sample's span is its own
     magnitude and the four points after it (the sample is included, so true peak ≥ sample peak; the filter's ripple is −0.3 … +0.22 dB
     on steady sines up to 20 kHz). Spans arrive `TruePeak.lag` = 6 samples late and depend only on 12 samples, so any chunking gives
     bit-identical numbers. **The limiter measures a frame on this scale** (its samples and the interpolated points on both sides):
     its requirement enters the queue 6 frames later and the signal waits 6 frames longer (`latency` = lookahead − 1 + 6); window,
     smoothing and release are unchanged. Every sample stays under the ceiling as before; the points between samples stay under it up
     to how much the gain moves across 12 samples (white noise at +17 dBTP comes out 0.002 dB over; checks allow 0.01 dB).
     **Every peak SkyCut reports is this measure**: the limiter's input peak, the f32's peak (`FrameSink` runs its own meter on what it
     writes), each frame and layer of `listen mix=true` (section 5), and listen's clips and files ([AI interface](ai-control-mcp.md)
     section 4 item 13).
   - **`Levels`**：`peak`（限幅前的真峰值）、`outputPeak`（写进 f32 的真峰值）、`limitedFrames`（真峰值过线的帧）、`maxReductionDB`、`loudnessLUFS`、
     `deliveredPeak`（see below）；压得超过 `attentionThresholdDB`（3 dB）才 `needsAttention`，建议降的量 = 压得最深的那一下。
     经 `Plan.audioLevels` → `VideoEditExporter.finishedAudioLevels` 到导出面板和 AI 的 `get_job` 结果。
   - **The delivered peak (2026-11-17)**: right after ffmpeg, before the file moves into place, `VideoEditExporter` measures the
     exported file's own sound (`ExportDeliveredPeak`: AVAssetReader with `AudioDecodeSettings`, the decode `listen file=` uses, on
     `MediaReadQueue.export`) into `Levels.deliveredPeak` — AAC swings past what it was given, so the delivered number is measured,
     never assumed. get_job (`ExportAudioReport`) reports `audio_loudness_lufs`
     and **`audio_peak_dbtp` = the delivered peak** (left out when the file could not be measured); the limiter's work only when it
     worked, under its own names: `audio_peak_before_limiter_dbtp`, `audio_limited_seconds`, `audio_max_reduction_db`, and a `note`
     past 3 dB. Until 2026-11-17 the only peak was `audio_peak_dbfs` = the peak *before* the limiter (+5.6 on a mix whose file peaked
     at −0.5: it read like a clipped file; [case](../bugfixes/2026-11-17-export-peak-before-limiter-and-binned-loudest.md)). The panel
     shows one line「响度 · 真峰值」(the delivered peak; the f32's if it was not measured) and, when limited, the orange line about
     −1 dBTP.
   - **预览不限幅**（已知差异）：预览是同一个引擎的实时模式直接出声卡，不经这条路；过顶的地方预览里是线性和（也不削），
     成片是压过的。电平表的红灯照旧管预览。
   30 分钟立体声约 675MB，放在导出的工作目录里，导出结束随目录删。
4. **整段渲染在 `MediaReadQueue.export`**（宽度 1）上同步做：引擎的喂样在这条线程上读文件（`AVAudioFile`），
   不进 Swift 并发的线程池（[阻塞的媒体读取](blocking-media-reads.md)）。每渲一拍看一眼取消标记
   （`renderOffline` 的 consumer 回 false 引擎就停）。
5. **变速的保音调算法预览和成片是同一份**：引擎的 `AudioTimeStretchReader`（AVAudioUnitTimePitch）。
   （2026-10-01 PR3b 之前 AVPlayer 那条路的预览用的是 AVFoundation 的 `.spectral`，是另一种算法。）
6. **按时间线的帧落位。** 引擎从 0 起连续渲，段落的位置在配置里（`Segment.start`），没有「读出来的块带时间戳」
   这回事；段与段之间渲的是静音，不会把后面的声音往前挪（挪了就是声画不同步）。
7. **导出不挂电平表**（`meters` 为 nil）。声音场景的效果链在引擎的渲染块里跑（`SceneBox`），离线和实时是
   同一段代码 —— 这正是「只做一遍」成立的前提（[音频引擎](audio-engine.md) 合同第 7 条、[声音场景](sound-scenes.md)）。

## 三、和以前比变了什么（2026-09-24 探针实测，都是「成片向预览看齐」）

2026-10-01 起渲成片的是引擎。PR3a 时它和 AVFoundation 那份混音逐 10 ms 窗口差 ≤ 0.03 dB（44.1k 单声道重采样 0.29 dB；
变速是两种算法、≤ 0.95 dB）；PR3b 删掉那条路之后 `scripts/check-audio-engine.sh` 改对着纯 Swift 的 oracle 混音器量（差 ≤ 0.027 dB）。
下表是 2026-09-24 从 ffmpeg 滤镜链换到预览混音时量的，「成片向预览看齐」的结论不变 —— 只是现在两边连渲染代码都是同一份。

| | 以前的成片 | 现在的成片（= 预览） |
| --- | --- | --- |
| 音量、渐变、曲线、推子、上层轨 / 音频轨的声音 | — | 相差 ≤ 0.01 dB（AAC 编码本身 ≤ 0.05 dB） |
| 借余料的叠化 | acrossfade | 预览的两条斜坡，差 0.21 dB |
| 变速段 | ffmpeg `atempo` | AVFoundation `.spectral`：稳态正弦差 0.02 dB；语音这种信号逐 50ms 窗口差 1 dB 上下（最大 2.8 dB，在段首）——两种变速算法的差，现在和预览听到的一致 |
| **单声道素材** | ffmpeg 转立体声时每个声道 −3 dB | AVFoundation 把单声道原样放进两个声道：**成片比以前响 3 dB**，和预览一致 |
| 段落在时间线上的位置 | `adelay` 按整毫秒 | 合成的时间刻度 1/600 秒（与预览相同，最多差 0.83ms） |

速度：10 分钟、30 段、4 条合成音轨的时间线读 1.7 秒（357 倍实时，峰值内存 31MB）；30 分钟、
60 段、35 条合成音轨、混着 48k / 44.1k 单声道 / mp3 读 25 秒（75 倍实时，79MB）。

变速段的输出**不能逐位重复**（`.spectral` 两次读能差 0.39 dB），所以自检里凡是有变速的对账都要
留容差；不变速的段两次读逐位相同。

## 四、回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-audio-fade.sh` | 真跑导出（`plan()` + ffmpeg）量包络，和预览逐窗对：渐变、变速、曲线、推子、接缝；第 6 组断言导出图里没有声音滤镜、混音文件以 f32le 输入接进去；第 6b 组断言正在播的预览换上的 mix（用户状态 + plan）在两种要展开的缝上和成片一致，且符合绝对期望；第 10a 组（`checks/AudioFade/Limiter.swift`，纯值）：限幅器没过顶逐采样原样、过顶一个采样不超上限、+6 dB 稳态正弦出来是干净的等幅正弦、50 Hz 不被抽扁、尖峰时刻不变 / 前 5 ms 是斜坡 / 1 s 后回到原样、分块喂 = 整段喂且总长不变；响度表按 EBU Tech 3341（−23 → −23、门限、单声道低 3.01）；第 10b 组（`Ceiling.swift`，真跑导出）：过 0 dBFS 的混音限幅前的峰值 / 压了多久多深照实记、f32 里没有一个采样超过 −1 dBFS 且峰值 / 均方根 = √2（不是削平）、整段响度和 ffmpeg `ebur128` 差 < 0.5 LU、成片峰值不冒出 0、成片响度和混音一致、主推子压下来不压且峰值 / 响度都线性；since 2026-11-17 also: the f32's true peak ≤ −1 dBTP + 0.01 dB and = the reported `outputPeak`, the delivered peak (`ExportDeliveredPeak`) = ffmpeg's decode of the same file within 0.1 dB and far under the pre-limiter peak; group 10c (`TruePeakChecks.swift`, pure values): the meter on sines 100 Hz–20 kHz at 24 phases (−0.4 … +0.25 dB, 997 Hz within 0.02), never under the sample peak, the 12 kHz 45° tone reads its crest, chunking gives identical spans; the limiter holds hard signals (12 kHz 45°, 19 kHz, white noise ×8, a spike) at −1 dBTP within 0.01 dB and pulls down a crest that only exists between samples |
| `checks/export-audio-single-pipeline.sh` | 导出图的真代码里没有声音滤镜；导出图调了混音、接了它的文件；混音是 `AudioEngineConfig.make` 那份配置交给 `TimelineAudioEngine(mode: .offline)` 的 `renderOffline` 渲出来的 |
| `scripts/check-audio-engine.sh` | 引擎离线渲染 = 纯 Swift 的 oracle 混音器（12 组，含电平表、场景、变速，[音频引擎](audio-engine.md) 第五节）—— 成片和预览用的就是这一份渲染代码 |
| `scripts/check-mix-layers.sh` | 按层量（第五节）：整条时间线量出来的峰值、过线、压得最深、整体响度和这里导出报的逐位一样，单声道人声的电平和真导出的成片一样 |
| `checks/transition-handles-wiring.sh` | `makeAudioMix` 自己展开转场（三个预览入口传的是用户状态） |
| `scripts/check-export-frame-rate.sh`、`check-video-fade.sh` 等 | 真导出照常跑通（含没有声音的时间线走 `anullsrc`） |

**反向验证（2026-09-24）**：混音读取不挂 audioMix → `check-audio-fade` 导出那几组的渐变全红、
单一管线守卫点名那一行；在导出图里塞一行 `afade` → 守卫红；撤掉 `makeAudioMix` 里的展开 →
第 6b 组红（见 [案例](../bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md)）。
**（2026-09-30）**：限幅器不乘增益 → 10a 大片红、10b「f32 没有一个采样超过 −1 dBFS」红；换回硬削 → 10a「均方根 = 上限 / √2」
「逐采样差 < 2%」红、10b「峰值 / 均方根 = √2」红。
**(2026-11-17, true peak)**: the limiter's requirement back on the samples alone (`span.sample`) → 10c's hard signals red (the 12 kHz
45° tone out at +2.1 dBTP, white noise ×8 at +3.7) and the crest between samples not pulled down, 10b's real f32 at −0.99 dBTP,
`check-mix-layers` 2b, the scan guard; get_job back on the pre-limiter peak → `check-mix-layers` 2a's report lines and the scan guard;
listen's `loudest_at` back on the curve step's middle → `check-mcp`'s JSON line. Details in the
[case](../bugfixes/2026-11-17-export-peak-before-limiter-and-binned-loudest.md).

**（2026-10-01 PR3a，成片换成引擎渲）**：混音不走 `.offline` 的引擎 → 守卫点名那一行；不用 `AudioEngineConfig.make` →
守卫两行红。换了渲染器之后 `check-audio-fade.sh` 真跑导出的那几组照常全绿 —— 成片的包络仍和预览逐窗一致；只有
「大厅 · 成片 vs 预览」改成对着引擎自己渲的那份比（`enginePCM`，并单声道按 (L + R) / √2，和 ffmpeg `-ac 1` 一个口径）：
tap 那条路在这条 5 秒的时间线上余音载体要被拉长，余音比引擎散得慢（3.3 秒处差 4.2 dB），而用户现在听的预览就是引擎。

**人工回归**（发版前实机）：

- [ ] 一段有渐入渐出、画了音量曲线的口播，导出后和预览逐段听一遍，听不出差别。
- [ ] 有变速段（1.5x / 0.75x）的工程：成片的变速听感和预览一样。
- [ ] 最后几秒只有画面的工程：成片总长不变，结尾那几秒是静音，不是提前结束。
- [ ] 导出进行到「读声音」那一段（进度条还在 0）点 Stop：马上停下，不留临时文件。
- [ ] 几个音效叠在音乐上、故意推过 0 dBFS 的工程：导出面板那一行「响度 · 真峰值」出来，橙字说压了多久多深；成片听音效的那几下
      不「啪」也不闷，音乐部分和预览一样响。
- [ ] The same project exported by the AI: get_job's `audio_peak_dbtp` (the file's own true peak) is close to −1 and equals
      `listen file=<the export>`'s `peak_db`; the pre-limiter peak only appears as `audio_peak_before_limiter_dbtp`.

## 五、按层量：混在一起之后，每一层、每一帧有多响（listen mix=true，2026-11-16）

南极预告片撞出来的（待办总清单 MCP-3、MCP-10，两组 AI 都撞上）：`listen` 只回每一段各自的电平、0.5 秒一格，量不了混在一起之后的，
也到不了帧；在 SkyCut 外面从素材文件按增益估，单声道的旁白比它在成片里实际响了约 3 dB（铺成立体声时每声道 −3 dB、量的时候没算）。
这一节是「听声音的引擎」的第 1 步（量）：以后的人声清不清楚（ESTOI）、声音报告都从这里拿采样和数。
The engine as a whole, and steps 2–3 that consume these samples (ESTOI, masker attribution, source-sound features), are in
[the listening engine](listening-engine.md).

1. **从引擎量，不从文件估。** `AudioStemRender` 用和成片同一份配置（`AudioEngineConfig.make(from:)`，带场景的响度补偿）离线渲：
   整条混音一个 `TimelineAudioEngine(.offline)`（就是第二节那一份），每一层一个（同一份配置只留那几条轨，总推子、总长照旧）；几个引擎
   一块一块同步往下走（`beginOffline` / `renderOfflineQuantum` / `endOffline`：导出的整段渲也是这三步，渲染代码同一段）。单声道素材引擎
   原样铺到两边，电平按两个声道平均算，所以量出来就是它在成片里的电平（自检对着真导出的成片量，差 < 0.1 dB）。
2. **层**：每条在混音里出声的轨一层 —— V1 是主轨自己的声音，上层轨、音频轨照 AI 的叫法（V2…、A1…）；藏起来、静音、上面没有带声音的段的轨
   不在混音里。也能按组：几条轨用 + 连起来，`rest` = 没点名的其余几条；最多 12 层（每层多渲一遍）。**每层是它进总线时的样子**：片段音量、
   曲线、渐变、场景、轨道推子、总推子都算上，**限幅之前**。限幅器只作用在整条混音上，所以各层加起来就是总线上的混音（自检逐采样对）。
3. **到帧**：帧率只从工程来（`MixFrameGrid(fps: state.frameRate.fps)`，[工程帧率](project-frame-rate.md)；48 kHz 下 24 / 30 / 60 fps 一帧
   2000 / 1600 / 800 个采样）。每层每帧（`MixBandMeter`）：整体电平（这一帧的均方，两个声道平均）、采样峰值、四个频段（<300、300–800、
   800–3000、>3000 Hz）。频段用以这一帧为中心、**两帧长的汉宁窗**做 FFT（vDSP）：一帧长的窗会把帧边上的一下敲击压没，两帧长、相邻两帧
   各算一半；一段的均方 = 落在这一段的能量 ÷ 窗的能量（Parseval，四段加起来 = 窗加权的整体电平），窗伸出时间线的那部分不算能量。
4. **整条混音**（`MixBusMeter`）：限幅之前每帧的均方、峰值、有几个采样过了线（限幅器的上限 −1 dBFS）；再过一遍**和成片同样参数**的
   `ExportPeakLimiter`（`recordsGains` 记下每帧乘了多少；成片不记，照旧）；限幅之后的 K 加权瞬时（400 ms）、短时（3 s）响度量在每帧的末尾
   （`AudioKWeighting`，窗按采样算、不按帧凑），整体响度喂 `ExportLoudnessMeter`。**量整条时间线时，喂进去的就是导出写进 f32 的那一串采样**：
   限幅前的峰值、写出去的峰值、过线的帧数、压得最深、整体响度和导出报的（`audio_peak_before_limiter_dbtp`、`audio_loudness_lufs`……）逐位一样（自检钉着，
   挂了场景的那条也一样）。Since 2026-11-17 these peaks and the over counts are true peaks (dBTP, section 2 item 3), the
   limiter's own measure; a span arrives 6 samples late, so the bus keeps its own input and output true-peak meters and drops each
   span into its frame when it comes, and MixMeasurement renders past the range by the limiter's latency plus the output lag.
   Each layer's frame peak (`MixBandMeter`) is the true peak over the frame with the real samples around it (`TruePeak.peak`). 过线**只报不拦**。
5. **只量一段**：前面多渲 3 秒（短时响度的窗、限幅器和 K 加权要接上），有段挂了声音场景再多 6 秒（前面那段的余音拖进来，最长
   `SceneRecipe.maximumTail`）；起点按 `offlineQuantum`（4096 帧）往前取整，块的边界和从 0 渲的那一份对齐（增益按块插值，逐采样一样）。
   后面多渲限幅器的前瞻和半帧；渲到时间线的尽头就照成片那样冲干净限幅器。只量一段 = 整段量里同样那几帧（自检：电平、峰值、过线逐位，
   限幅的增益差 < 1e-5，瞬时 / 短时响度差 < 0.01 LU）。挂了场景的段、变速段的拉伸器是从窗口前面接上的，细节可能和整段渲略有不同（没量过差多少）。
6. **在哪跑、谁来跑**：阻塞的离线渲在 `MediaReadQueue.export` 上 —— 和导出的混音同一条宽度 1 的队列，两个离线渲不同时跑。AI 起的是
   `AIJobs` 的任务（种类 `listen`，[AI 接口](ai-control-mcp.md)第四节第 59 条：跑着时 App Nap 不降速），排在 `AIWorkQueue` 的 `mix` 道上（一次一个）；
   当场最多等 20 秒，量完当场回，没量完回任务号、`get_job` 拿同一份结果。只读：不改工程、不进撤销，量的是调用那一刻的时间线。
   **离线引擎不碰声卡**：预览那个实时引擎停着就一直停着、起停只经 `AudioEngineIdleKeeper`（[音频引擎](audio-engine.md)第二节第 11 条）；
   2026-11-16 实测量的进程跑了 12 秒，`pmset -g assertions` 采了 456 次，一次都没有替它挂的断言。渲在普通线程上，比不过实时的音频线程，
   正在播的预览照常出声（真声卡上没量过，人工回归里有一条）。
7. **接口留给以后**：`MixMeasurement.measure(_:observe:)` 每渲一块，把混音和各层的原样采样（交错立体声 f32）交给 `observe` —— 以后的 ESTOI
   （干净人声那一层对整条混音）、声音报告直接拿；只要数的用结果（每帧的数，加上和导出同口径的 `levels`）。

量出来要多久（M1，机器同时在编译、负载 5–10；只算渲 + 量，不算等队列）：

| 工程 | 层 | 整条按层渲 + 量 | 只渲混音（导出那一步） |
| --- | --- | --- | --- |
| 南极预告片 A（62.25 秒、8 条出声的轨，真素材，工程拷了一份、素材原地只读） | 8 | 1.0–1.2 秒 | 0.2 秒 |
| 同一份素材铺三遍（186.8 秒） | 8 | 2.7–3.3 秒 | 0.6–0.9 秒 |
| 合成的 60 / 180 秒（4 条轨） | 4 | 0.65 / 2.0 秒 | 0.14 / 0.4 秒 |
| 南极 29–44 秒（15 秒） | 8 | 0.3 秒 | — |

回归：`scripts/check-mix-layers.sh`（现造的 WAV：四个频段各一个正弦、24 / 30 / 60 fps 的脉冲、0.56 秒的音效、EBU Tech 3341 的 −23 / −33 dBFS 正弦；
和 `ExportAudioMixdown.render` 逐位对账；每层相加 = 混音；只量一段 = 整段；单声道人声 vs 真导出（ffmpeg）的成片；listen 的计划和结果）、
`checks/MCP/listen-wiring.sh` 的 mix 那一节（扫描：任务、排队、`MediaReadQueue.export`、只建离线引擎、不碰预览引擎的起停、量法只用成片那几样）。
反向验证（2026-11-16，各弄坏一处、看它红、再恢复）：

| 弄坏什么 | 哪几条红 |
| --- | --- |
| 两个声道相加、不平均（+3 dB） | 四个频段的整体电平 6 条、Parseval 6 条、单声道人声对素材 / 对成片 2 条 |
| 限幅器的上限和成片不同（0.95） | 和导出对账 8 条（两条时间线各 4 条）、「过线的帧写出去不超过 −1 dBFS」、29–44 秒过线的时刻 |
| 前面不多渲 | 只量一段 = 整段的瞬时 / 短时响度 2 条（差 9.7 / 12.5 LU） |
| 每层不乘总推子 | 每层相加 = 混音、单声道人声对素材 / 对成片 |
| 帧的边界错半帧 | 音效最响的帧和 loudest_at、过线的时刻、整条和导出对账的响度 2 条 |
| 逐帧的数不限量 | frames=true 要 10 秒没有拒绝 |
| 离线渲换到 `MediaReadQueue.analysis` | `listen-wiring.sh` 的 mix 那一节 |

人工回归（发版前实机）：

- [ ] 播放中让 AI 对整条时间线 `listen mix=true`：预览的声音和画面不卡、不掉；量完播放照常。
- [ ] SkyCut 停着 2 分钟以上（预览的图已经停了）时让 AI `listen mix=true`：`pmset -g assertions` 里一直没有 SkyCut，卡顿日志里没有「预览的音频引擎：起图」。
- [ ] 一条故意推过 0 dBFS 的工程：`listen mix=true` 报的 `over` 时刻听起来就是被压的那几下；导出之后 `get_job` 报的响度、峰值和它报的一样。
