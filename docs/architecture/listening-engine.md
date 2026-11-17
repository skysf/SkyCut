# 听声音的引擎：分层、谁调谁、只报不拦

> 管什么：SkyCut 里替 AI「听」声音的那一层薄引擎 —— 分几层、每层在哪、谁调谁；第 2 步（ESTOI、拿掉谁涨多少、150 Hz 以下另报）和
> 第 3 步（没来路的原声的特征和描述）这两块纯计算的口径、和研究时 numpy 版怎么对账；哪几条线是盲听定的、定到什么程度。
> 不管什么：第 1 步「按层离线渲 + 每帧分频段电平」（在音频引擎里，见[成片的声音](export-audio-mixdown.md)「按层量」一节和[音频引擎](audio-engine.md)）；
> 检查的门槛、给 AI 的报告、接到 `listen` / `inspect_video` 上 —— 这些是接线的任务，做的时候补进这份文档。
>
> 由来（2026-11-16）：用户问「是否还有更好的方式，或者我们自己写一个能解决听声音的引擎？」。调研的结论：没有现成的东西能替 AI 听
> （能听的大模型认环境声约六成、问「什么时候、几次」基本不可用；苹果的识别器没有「轰鸣」这一类），所以在 SkyCut 里自己做一层薄的：
> 量 + 成熟指标 + 苹果自带的识别，不加第三方依赖、不训模型。用户同意用 ESTOI 量「人声被盖住」、只报不拦。
> 2026-11-16 合入的是第 2、3 步里不依赖第 1 步的纯计算（`Sources/SrtFlow/Listening/`），**还没接到任何地方**。
> **2026-11-17: steps 2 and 3 are wired**: `listen voice=…` (section 2 item 3a; the lines are in code: `VoiceClarity`) and
> `listen describe=true` (section 2 item 4a: SkyCut's traits + SoundAnalysis's per-label scores + words heard).

## 一、分层

| 层 | 回答什么 | 在哪 | 截至 2026-11-16 |
| --- | --- | --- | --- |
| 0 来路 | 这层声音是什么、为什么在这 | 读工程：生成时的提示词、音乐库 / 音效库的标签、旁白的文字、合成音效的预设 | 工程里本来就有，**不用听** |
| 1 量 | 每层、每帧、每个频段多响；整条的响度、峰值 | 音频引擎按层离线渲（`AudioStemRender`、`MixMeasurement`，[成片的声音](export-audio-mixdown.md)「按层量」） | Merged 2026-11-16 (`listen mix=true`); since 2026-11-17 every peak is a true peak (`TruePeak`, dBTP, the limiter's measure) and a clip's or file's `loudest_at` is a frame |
| 2 成熟指标 | 每句人声清不清楚；主要是谁盖住了它、压哪层最管用；ESTOI 看不见的低频有多响 | `Listening/ESTOIAnalysis`、`ESTOI`（含 `ESTOIReference`）、`MaskerAttribution` | Wired 2026-11-17: `listen voice=…` (`AIListenVoiceCheck`) |
| 3 描述没来路的原声 | 素材自带的声音大概是什么：低沉长音 / 宽频噪声 / 有音高 / 有拍子 / 像说话 | `Listening/SourceSoundFeatures`、`SourceSoundSpectrogram`、`SourceSoundTrait`（含 `SourceSoundDescription`） | Wired 2026-11-17: `listen describe=true` (`AIListenSourceSound`), with SoundAnalysis's per-label scores (`SoundLabelScores`) and the on-device speech recogniser's words |
| 4 声音报告 | 把 1–3 拼成一张按时间的表，AI 一次读完；「要人听」的几处 | — | 没做 |
| 5 以后 | 拆开（素材原声里的人声和别的）、认（更细的名字）、第二只耳朵（云端窄问题）、人的耳朵（一键打点） | — | 都没做；要下载模型或花钱的，先问用户 |

地基（只给这几层用）：`ListeningDFT`（任意长度的 DFT：vDSP 认的长度直接做，别的走 Bluestein）、`ListeningResample`（整段 FFT 截断的重采样、
可重用的 `Plan`；`ListeningLevel` 是 RMS → dBFS 的口径）、`ListeningMath`（照 numpy 写的汉宁窗、频点的频率、中位数、标准差）。
全是纯值、纯函数：不依赖 App 里的别的类型，`scripts/check-listening.sh` 只编这几个文件。

## 二、谁调谁（接线以后应该是这样；step 2 wired 2026-11-17, item 3a）

1. **来路已知的声音不用听。** 旁白轨、音乐库的曲子、音效、生成的音乐是什么、为什么在这，工程里都有（第 0 层），直接用来路。
   要「听」的只有两样：**素材自带的原声**（来路不明）和**混在一起的结果**（谁盖住了谁）。
2. 第 1 步给采样：`MixMeasurement.measure(_:observe:)` 每渲一块，把整条混音和各层的原样采样（48 kHz、交错立体声、**限幅之前**）交出来。
3. **每句人声**（起止来自转写或旁白轨的位置）：取人声起止前后各多 0.2 秒的窗；人声那几层加起来当「干净人声」，其余每层一条；都先取 (L+R)/2。
   交给 `MaskerAttribution.rank(clean:others:sampleRate:)`，回：整句 ESTOI（和每段的中间值，`worstWindow()` 是最差 1 秒）、每层「拿掉 / 压低 6 dB，
   ESTOI 涨多少」和这一层多响、别的声音在 20–150 Hz 多响、人声整句多响。只要一个数时用 `ESTOI.score(clean:mix:sampleRate:)`。
   混音必须是各层之和（限幅之前）：拿掉一层 = 不加它；传限幅以后的成片，减出来的就不是「没有这一层」。
3a. **How `listen voice=…` does it (2026-11-17, MCP-39).** The AI names the voice: an audio track (`voice=A1`, several joined by +)
   or `auto` (the audio tracks holding only SkyCut's voice-overs, recognised by the folder SkyCut writes them to in any interface
   language). A video track's sound is refused with the reason: a voice there was recorded with everything around it and can't be
   taken out (on-camera speech, research E37 / E38). `AIListenVoicePlan`: the voice tracks first, then every other audible track
   as its own layer (beyond 12 in all the rest are joined as `rest`), each with what its clips are from where they came
   (`Provenance`: our voice-overs and sound effects by folder, library music / effects by manifest id, generated audio as music,
   a video clip's sound as `clip_sound`, anything else `other`) — rule 1 above: the masker is named by its source, not guessed.
   `AIListenVoiceMeasure` renders the layers with `AudioStemRender` (the export's configuration, before the limiter, so they add
   up to the mix), starting `MixMeasurement.preroll` before the first voice clip; each voice clip's stretch ± 0.2 s is kept from
   every layer as (L + R) / 2, and once the render has passed it its own voice layer is cut into lines at its pauses
   (`VoiceLines`: 20 ms frames, quiet = 40 dB under the clip's loudest frame and never above −60 dBFS, a line ends at 0.6 s of
   quiet — longer than a breath or a comma), each line padded 0.2 s and handed to `MaskerAttribution.rank` with every other
   layer, other voices included; then the stretch's samples are dropped (memory stays a few seconds). `AIListenVoiceReport`
   writes each line (clip, where it is spoken, ESTOI, the verdict, the two strongest maskers with their kind and gains,
   `low_150_db` next to `voice_db`) and counts the verdicts. It is a listen job like mix=true (`AIListenMix.queued`: AIJobs,
   the mix lane, `MediaReadQueue.export`, 20 s inline); read-only; never the preview's engine.
   Voice-over clips are one line each already; a long narration file is split by its pauses, not by a transcript (listen is
   read-only and starts no transcription).
4a. **How `listen describe=true` does it (2026-11-17, MCP-42 SkyCut half + MCP-44).** With `clip_id` (or `file`): a clip whose
   provenance is known (our voice-over, library music or effect, synthesized effect, generated audio) is not described — the reply
   names its source (rule 1). Otherwise `AIListenSourceSound` reads the clip's window once (`AIListenAudioWindow` keeping one
   channel, (L + R) / 2; at most 60 s, longer is refused with a `to` / `source_out` that fits) and, per 3 s window from the window's
   start, reports: SkyCut's traits and the numbers behind them (`SourceSoundDescription`, section 5); macOS's sound classifier
   (`SoundLabelScores`: SoundAnalysis `SNClassifySoundRequest(.version1)`, 3 s analysis windows without overlap, every label's own
   score — the report keeps the strongest five at 0.05 or more); and how many words the on-device speech recogniser finds there
   (`AIListenSourceWords`: a 16 kHz window via `QueuedAudioWindow`, `SpeechTranscriptionService` with `screeningLocale()` = a model
   already installed, never a download; macOS 26; the summary quotes up to 120 characters of what it heard). A listen job (AIJobs,
   the mix lane); the classifier's first use in a process compiles its model (measured ~90 s once on a busy M1, then 0.13 s for
   9 s of sound), so the first call may answer with a job id.
   Words, never "music / not music": on synthetic sound the classifier scored a 55 Hz drone "music 0.88, synthesizer 0.87",
   white noise "music 0.14, waterfall 0.14, water 0.11", a major chord "music 0.66, bell 0.56" — the runner-ups and how close they
   are carry the information.
4. **没来路的原声**（每个留着原声的镜头）：那一层的采样交给 `SourceSoundDescription.describe(_:sampleRate:)`，回每 3 秒一窗的九个数和描述词。
5. 第 4 步把这些拼成表交给 AI；**只报不拦**（第三节）。
6. 都是纯 CPU 的计算，不读文件、不碰声卡：接线时放在后台（AI 起的走 `AIJobs`，[AI 接口](ai-control-mcp.md)第四节第 59 条），别放主线程。
   粗测（release 编译、机器同时在编别的、负载 20 上下）：一句 4 秒 48 kHz、五层的「拿掉谁涨多少」约 0.12 秒，单算 ESTOI 约 0.04 秒，
   30 秒原声的描述约 0.25 秒；大头是重采样。窗越长内存越大（Bluestein 要 ≥ 2n 点的卷积，十几秒的窗是几十 MB），**一句一窗、原声一窗 3 秒地做**，别拿整条片子一次做。

## 三、只报不拦、来路已知的不用听

- 这里出的每个数都是**描述**，不是判决：不拦导出、不自动改混音、不替用户「修」。原因：线只来自一个人的耳朵和几十题（第七节），
  有的声音是故意盖住人声的（真人正片里船长广播的第一句，用户盲听答「不清楚」，那是片子要的效果）。
- 「来路已知的不用听」：知道是哪一层盖住了人声，就用那一层的来路说它是什么（「音乐 2」「风声垫底」），不用特征去猜；
  特征和描述只给来路不明的素材原声用。
- 不判「是不是音乐」：研究里一个纯的低音效果按这几样特征比音乐还像音乐 —— 够描述、不够分类。

## 四、ESTOI 的口径（`ESTOIAnalysis` / `ESTOI`）

- 参数照 STOI / ESTOI 的论文（Taal 等 2011、Jensen & Taal 2016）和研究时自己写、验过的 numpy 版：10 kHz；256 点汉宁窗（numpy 的 `hanning(258)[1:-1]`）、
  跳 128 点、补零做 512 点 FFT；15 个三分之一倍频程带，中心 150 Hz 起（第 7–218 个频点，136.7–4258 Hz）；30 帧一段（384 ms），相邻段差一帧。
- 去静音：干净人声每帧的能量比最响的一帧低 40 dB 以上的，两边都去掉；剩下的帧加窗后按 128 点叠回一条连续的信号再分析（pystoi 的做法，帧会被加两次窗）。
- 每段：先每个带在 30 帧上去均值、归一，再每帧在 15 个带上去均值、归一（分母加 `Double.ulpOfOne`，不加 pystoi 的随机数），两边逐元素乘、加起来除以 30；整句 = 所有段的平均。
  一般在 0–1，和人声毫不相干的声音会略低于 0，不夹。去静音以后不到 30 帧（约 0.4 秒）、两边长度不一样回 nil。
- **不管响不响**：两边各自归一，所以干净人声、混音整体变响变轻都不改结果（自检钉着）；「整句太轻」要另外量。
- **看不见约 134 Hz 以下**（最低一带的下沿）：所以每句另报别的声音在 20–150 Hz 多响（`othersLowBandDBFS`）和人声整句多响（`voiceDBFS`），
  放在一起比。一层只在 100 Hz 以下、靠「往上盖」盖住人声的重低音，ESTOI 会漏（自检：40 / 50 Hz 的重低音比人声响 6 dB，ESTOI 还有 0.967；
  同样响的人声形状噪声压到 0.369）。电平一律是同一个窗的 RMS，20·log10(RMS + 1e-12)，满刻度的正弦是 −3.01 dBFS。
- 最差 1 秒：连着 78 段（≈ 1 秒）平均最低的那一截。注意是**去静音以后**的帧，句中停顿已经拿掉。长句子用整句还是分段，研究里还没定（第七节）。
- 重采样：整段做一次 FFT，频点截到新长度的一半、反变换、乘 m/n（研究 numpy 版的做法；新长度一半取偶，和 Python 的 `round` 一样）。
  就是在新的奈奎斯特频率上一刀切的理想低通。**不换成多相滤波**：线是拿这种重采样量出来的，换了，同一段声音的数就差在第三位小数上。
- 拿掉谁涨多少（`MaskerAttribution`）：混音 = 干净人声 + 各层之和；每层算「拿掉」「压低 6 dB」两次；这一窗里 RMS 低于 −60 dBFS 的层不算；
  按「拿掉涨多少」从大到小排（一样大再看压低 6 dB 的，再一样按 id 倒序，和 Python 版的元组倒序一致）。层的电平在 10 kHz 上量（5 kHz 以上不算）。
  干净人声那一边（去静音的帧、归一好的段）只算一次（`ESTOIReference`），一层两次打分只算混音那一边。

## 五、原声的特征和描述（`SourceSoundFeatures` / `SourceSoundSpectrogram` / `SourceSoundTrait`）

每 3 秒一窗（不满一窗的尾巴不要；RMS 低于 1e-3 的窗不说），各自先换到 16 kHz；1488 点汉宁窗（93 ms）、跳 744 点：

| 特征 | 怎么算 |
| --- | --- |
| 频谱重心 | 50–8000 Hz 的功率（每点加 1e-12）加权的平均频率，响的帧（总能量高过最响一帧的万分之一）取中位 |
| 平坦度 | 同样那几点的几何平均 ÷ 算术平均，响的帧取中位（白噪声约 0.56，能量挤在少数频率上近 0） |
| 300 Hz 以下占比 | 20–300 Hz 的能量 ÷ 20–8000 Hz 的，全部帧 |
| 音级集中度 | 55–2000 Hz 的点归到最近的半音（一半取偶），12 个音级每帧归一后最强 3 个之和，响的帧取平均（完全平均 = 0.25） |
| 音级稳不稳 | 每 10 帧（约 0.5 秒）一块不归一地加起来，相邻两块的余弦相似度取中位（不够两块是 nil） |
| 音高强度 | 每 40 ms 起一段 80 ms、去均值，太轻（RMS < 1e-4）的不要；自相关除以零延迟，1–16.6 ms（1000–60 Hz）里最高的，取中位 |
| 拍子清不清楚 | 六个频带（50–200–500–1000–2000–4000–8000 Hz）的正向频谱通量各除以自己的平均再相加，去均值后的自相关在 0.3–1.5 秒里最高的 |
| 电平起伏 | 每 0.1 秒的电平（dB），比最响的一格低不到 40 dB 的那些的标准差 |
| 2–8 Hz 起伏 | 每 10 ms 的 RMS 包络去均值、加汉宁窗做 DFT，2–8 Hz 占 0.5–32 Hz 的比例（说话的音节节奏在 4 Hz 上下） |

描述词（可以几个一起、也可以一个都不占）。线是照研究里量过的那一批声音挑的：一部片子的 104 个 3 秒窗（南极 `Shot4` 的轰鸣、风声垫底、雨和篝火、船和地铁、
两条长音效果、四条生成的音乐、人声 = 旁白 20 窗 + 船长广播 1 窗）。**没有留出来的样本验过**：

| 词 | 线 | 在那 104 窗上（研究存的数取过整，只是大概） |
| --- | --- | --- |
| 低沉长音 `low_drone` | 300 Hz 以下 ≥ 0.6，电平起伏 ≤ 6 dB，没有拍子 | `Shot4` 轰鸣 2 / 2；地铁和船 3 / 4；63 Hz 的长音效果 5 / 6；音乐 9 / 60（低的铺底）；人声 0 / 21 |
| 宽频噪声 `broadband_noise` | 平坦度 ≥ 0.05（音乐最高 0.045、人声 ≤ 0.003、雨打伞面 0.32） | 雨和篝火 3 / 5；别的 0 |
| 有音高 `pitched` | 音高强度 ≥ 0.6，或音级集中度 ≥ 0.75 | 音乐 51 / 60；63 Hz 长音效果 6 / 6；人声 2 / 21；轰鸣 0 / 2 |
| 有拍子 `rhythmic` | 拍子清不清楚 ≥ 0.5，**且**电平起伏 ≥ 1 dB | 音乐 12 / 60；人声 1 / 21 |
| 像说话 `speech_like` | 2–8 Hz 起伏 ≥ 0.3、电平起伏 ≥ 5.5 dB、音级稳不稳 < 0.9、音高强度 < 0.65 | 人声 18 / 21；音乐 1 / 60 |

- 「有拍子」多一条电平起伏 ≥ 1 dB：一动不动的声音（合成的纯音）频谱通量全是数值噪声，每带除以自己的平均以后照样能有很高的自相关
  （实测 220 Hz 的纯正弦 0.78）；研究里拍子 ≥ 0.5 的音乐窗，电平起伏最小也有 1.3 dB。
- 「像说话」多一条音高强度 < 0.65：唱的、乐器的长音比说话的周期性强（说话有清音、有抖动），研究里人声 0.42–0.63；
  前三条都占了的音乐窗（12 个）音高强度 0.64–0.82，11 个在 0.65 以上。
- 说不出来的：「风声垫底」（一条带音高的低吼，本机识别器说是鲸叫、音乐、锣）三窗一个词都不占 —— 音高强度 0.49–0.52、集中度 0.59–0.62，
  都在线下；它和音乐本来就挨着边。这种要等 SoundAnalysis 每个标签的分数一起看（since 2026-11-17 `listen describe=true` reports both
  side by side, section 2 item 4a）。

## 六、和 Python 版对

- **对照的是什么**：研究时我们自己写、拿用户的耳朵验过的 numpy 版 —— `tools/stoi.py`（`per_segment(extended=True)`、`worst_window`）、
  盲听那套题的 `bt_lib.resample`（整段 FFT 截断，任意采样率）、`tools/masker_attribution.py` 的算法、`tools/music_features.py` 的 `features()`（不取整）。
  它们不在仓库里（研究资料只在用户的机器上）；Swift 版照着移植，没有照抄别的开源实现。
- **怎么对**：`scripts/check-listening.sh --dump <目录>` 把对账用的合成输入原样写成小端 float32（加一份 `manifest.json`）；在那份文件上跑 numpy 版，
  数存进 `checks/Listening/PythonReference.swift`（生成的，不手改）；自检拿同一份 Float 算，逐数比。输入改了（`ParityCases.swift`、`TraitChecks.swift` 的信号）就要重算。
  对的数：8 句 ESTOI（10 kHz 的五种背景、一句 9 秒的、两句 48 kHz 走重采样）的整句、最差 1 秒、段数、帧数、首中末三段；一句 48 kHz 五层的基准和每层两个涨幅、电平；
  六种原声的九个特征。
- **容差** |Swift − Python| ≤ 1e-9 × max(1, |Python|)。**实测**：ESTOI 和「拿掉谁涨多少」差在 1e-15 上下，原声特征最大 2.6e-11（轰鸣那一窗的「拍子清不清楚」：
  它 500 Hz 以上没有能量，那几个频带的通量是数值噪声）。为什么这么定：两边同一份输入、同一套算法，差只来自 FFT 的实现和加法的先后；
  ESTOI 的线的分辨率是盲听的档距（0.03–0.04），差七个数量级，**不会让任何一句换档**（除非它离线不到 1e-9）；留的余量给不同版本系统的数学库。
- 「照 numpy 写」真要紧的地方（不照着写就对不上，自检会红）：频点的频率按 numpy 的 `k × (1 / (n·d))` 算 —— 1488 点的第 93、186、372 个频点是 999.9999999999999、
  1999.9999999999998、3999.9999999999995，归到下面那一带；按 `k × 16000 / 1488` 算正好是 1000、2000、4000，就进了上面那一带，「拍子清不清楚」全变了。
  重采样的新长度一半取偶（48 kHz → 10 kHz 时 n = 12、36、60…… 正好落在 .5 上）。汉宁窗换个写法只差最后一位，不影响结果。
- 和研究里那几步的已知差别：研究的 `render.py` 是整条轨道一次重采样再切句子，这里一句一窗地重采样 —— 两种做法实测差不到 1e-9
  （合成的 12 秒人声 + 音乐、三个种子、各切两句，最大 4.1e-10：窗两头那点振铃在 5 kHz 上下，ESTOI 的带只到 4.3 kHz）；
  `music_features.py` 解码时用的是 ffmpeg 的重采样，这里用上面那种 FFT 截断（没比过差多少）。

## 七、哪几条线是盲听定的（只来自一个人、几十题，定了不等于证实）

**Since 2026-11-17 these lines are in code** (`VoiceClarity`, used by `listen voice=…`; item 3 below as written: another voice
speaking → `two_voices` on its own; otherwise < 0.31 `probably_unintelligible`, 0.31–0.41 `may_be_hard`; with music the main masker
only < 0.20, as `may_be_hard`; the 20–150 Hz level is numbers only). Whether to add the grey "clear, but [layer] may be loud" hint
(FL-61) is waiting for the user. 来历：

1. 第一次小验证（15 句、用户一个人）：ESTOI 把用户听不清的两句（0.332、0.377）和听得清的 13 句（最低 0.445）分开了，线暂画在 0.41。
   听不清的只有同一句话的两稿，同一个东西盖住的（镜头原声的轰鸣）。
2. 盲听（2026-11-16，25 题：做的 18、锚点 2、真人正片 5；用户一个人、约 6 分钟）：一条线管不了。全部题上最好的线在 0.301（不含）到 0.335，错 5 / 25；
   0.41 错 8；按背景分：别人同时说话 0.48 以下都不清楚、0.65 才清楚；低沉轰鸣和吵的地方线在 0.30–0.38；音乐 0.22 也答清楚；
   风只出了 0.41 以上的题（都清楚）。船长广播第一句（0.225）答不清楚，和指标一致。ESTOI、STOI、旧的 dB 量法在这批题上差不多（错 4–5 题）。
3. 用户 2026-11-16 定（按建议）：检查先认出**盖住人声的是哪一层、是什么**（来路已知的直接用来路），按种类用不同的线；
   **两条人声叠着单独报一项**；其余分两档、只报不拦：ESTOI **0.31 以下「多半听不清」**，**0.31–0.41「可能费劲，听一下」**；**音乐盖人声只在很低时报**。

靠不住的地方：只有一个人听；用户知道台词（陌生观众可能更难听清）；题很短、单独放、没有画面；做的题人声全是同一个人；每档只有 1–3 题，
线的分辨率大约就是档距（0.03–0.04）；ESTOI 看不见 134 Hz 以下，风的题没有 0.41 以下的；长句子整句还是分段没定。
以后用户在预览上打的点攒多了再校。第五节描述词的线**没有经过盲听**，是照研究那一批数挑的。

## 八、守卫

`scripts/check-listening.sh`（在 `scripts/check-all.sh` 里；只编 `Sources/SrtFlow/Listening/` 和 `checks/Listening/`，不要 ffmpeg、不要 App）：

- 地基：任意长度的 DFT（vDSP 直接认的长度和 Bluestein 两条路）对定义式；rfft / irfft 来回；irfft 不看直流和最高频点的虚部；整数个周期的正弦重采样精确、
  5 kHz 以上降到 10 kHz 不折回来、升了再降回原样；新长度一半取偶；电平和 20–150 Hz 那一截的口径。
- ESTOI 的性质（照论文该有的样子，不靠 Python 版）：干净对干净 = 1；只是变轻 = 1；干净人声 × 8、混音 × 1/128 结果不变（乘 2 的幂，Float 里也精确）；
  白噪声、人声形状的噪声从 −15 dB 到 +20 dB 一档比一档高（实测白噪声 0.125 → 0.981，人声形状 0.089 → 0.985）；48 kHz 交进来和 10 kHz 一样；
  134 Hz 以下看不见；太短、长度不一样回 nil；干净人声全是 0 时是 0 不是 NaN；最差 1 秒的前缀和对逐段平均；15 个带的频点。
- 拿掉谁涨多少：最该动的排第一、134 Hz 以下那层几乎不涨但 20–150 Hz 报得出、−80 dBFS 的层不算、每个数都能从头复算、长度不一样回 nil。
- 原声：六种合成的声音（轰鸣、白噪声、和弦、敲击、类语音、类音乐）各自的描述词；3 秒一窗、太轻不说、尾巴不要、48 kHz 先换到 16 kHz。
- 和 Python 版逐数对账（第六节）。
- 信号全是合成的（仓库是公开的，不提交真录音）：类语音是按音节开合的浊音（基频滑动 + 抖动、三个共振峰、一点气声）加清音。

**反向验证（2026-11-16）**：临时把实现改坏、跑一遍、再改回来 —— 每个带在 30 帧上去均值那一步拿掉（49 条红）、去静音的线 40 → 30 dB（41 条）、
窗换成没去头的汉宁窗（50 条）、新长度改成四舍五入（2 条）、压低 6 dB 算成乘 10^(−6/20)（7 条）、频点的频率不照 numpy 写
（改成 `k / (n·d)` 或 `k / d / n`，第 93、186、372 个频点落到正好 1000、2000、4000：6 条，全是「拍子清不清楚」）、音级向下取整（14 条）、
音高的最短周期改了（3 条），全红；改回来全绿。汉宁窗换成教科书写法、拍子的频带改成右闭这两样改了也是绿的：前者只差最后一位，
后者这几个边界上正好没有频点（第六节），两样都不影响结果。

**没验到的**：真录音、真的按层渲出来的采样（接线的任务）；SoundAnalysis、SpeechTranscriber；描述词的线在别的片子上灵不灵。

**`listen voice=…` (2026-11-17)**: `scripts/check-listening.sh` checks the verdict table (`VoiceClarity`, every edge) and the line
split (`VoiceLines`: two stretches a second apart are two lines, a 0.4 s pause inside one is not, silence has none, a quieter voice
is still one line). `scripts/check-mix-layers.sh` group 3 runs the real path on synthetic signals: a speech-like voice on A1 in two
lines, loud noise under the second, quiet "library music" all along → two lines at the right timeline seconds, the first clear,
the second `probably_unintelligible` with A2 (`other`) its main masker and removing it worth most; V tracks refused with the
reason; `auto` finds the voice-over track by its folder; two voice tracks speaking at once → `two_voices`. Not verified: real
narration under real music (the blind-test items are not in the repo); the lines themselves (one listener).

**`listen describe=true` (2026-11-17)**: on 9 s of synthetic sound (a 55 Hz drone, white noise, a major chord),
`scripts/check-sound-labels.sh` runs the real classifier — one window per 3 s, every label's own score in 0…1, strongest first,
more than one label scoring in a window — and `scripts/check-mix-layers.sh` group 4 checks the report: SkyCut's traits on the right
windows (low_drone, broadband_noise, pitched), the strongest five labels at 0.05 or more, words counted per window and quoted,
source seconds mapped to the clip's timeline (start, source start, speed), and why words were not checked. The classifier has its
own small script with a fixed binary path because CoreML compiles the model for the Neural Engine the first time each new binary
uses it (25–90 s measured on an M1, minutes under load; an unchanged rerun at the same path skips it). Not verified: real camera sound and generated video sound (the South Pole
shots are not in the repo), the classifier's labels on them, the speech recogniser inside the app (it needs an installed model).
