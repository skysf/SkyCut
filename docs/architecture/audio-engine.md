# 音频引擎：时间线的声音自己播、自己渲

> 2026-10-01 起（PR1a：引擎本体 + 离线渲染 + 等价自检；PR1b：接进 App；PR2a–d：电平表、声音场景、变速、无锁槽；
> PR3a：成片也走它；**PR3b：AVPlayer 那条声音路（合成音轨 + audioMix + tap）和迁移期的开关删掉，时间线的声音只有引擎
> 这一份，播放器的合成里只有画面**）。为什么要有它、量过的数字、分几刀见 [方案](../plans/2026-10-01-audio-engine.md)。
> **2026-11-11 起图不是一直开着的**（第二节第 11 条）：没有声音不开、停着 30 秒没人用就停、用户回来动一下先起好。

## 一、是什么

`Sources/SrtFlow/AudioEngine/`，每个文件一件事：

| 文件 | 管什么 |
| --- | --- |
| `AudioEngineConfig.swift` | 从 `TimelineState` 算出来的纯值：哪条轨、哪一段、从素材哪一秒起、在时间线哪一段出声、段的增益（`GainTable.Sampler`）、轨道推子、总推子、总长；自己排序、展开转场 |
| `AudioGainTable.swift` | 增益表 `GainTable`（设定点 + 线性斜坡，`sampler()` 按秒取值）和 `AudioGainRamps`（从一段剪辑的音量 / 曲线 × 渐变铺出一张表） |
| `AudioRing.swift` | 一段声音的环：喂样线程写、渲染块读、无锁；按**时间线的帧**定位；seek 用「新一轮」标记，读者自己跳过去 |
| `AudioSegmentReader.swift` | 按段读原件（`AVAudioFile` + `AVAudioConverter` 转 48 kHz），不缓存；变速段交给下一行 |
| `AudioTimeStretchReader.swift` | 变速段：保音调地拉伸（离线的小 AVAudioEngine：PlayerNode → AVAudioUnitTimePitch(rate)），随机定位时重排并先渲掉单元的延迟 |
| `AudioTrackFeeder.swift` | 一条轨的喂样：一段一条流（环 + 读取器），提前一秒开流、走在播放头前面半秒；seek 各流重读；把活着的流发布给渲染块 |
| `AudioTrackRenderer.swift` | 渲染块：从各流的环里取这一拍、乘段增益（64 帧一块线性插值）和轨道推子、累加 |
| `AudioPublished.swift` | 给渲染块看的「此刻生效的那一份」：原子指针交换，发布方留最近 8 份不放 |
| `TimelineAudioEngine.swift` | 图（每轨一个 `AVAudioSourceNode` → mainMixer = 总推子，另有一个静音的时钟节点）、实时的 play / pause / seek、起 / 收 / 空闲时停（`suspend`）/ 再起（`wake`、`recoverIfNeeded`）、换配置 / 只换增益 / 让路 / 静音、离线整段渲染；把每条轨和总表的槽登记进电平表 |
| `PlaybackAnchor.swift` | 播放头的锚点：引擎的哪一拍对着时间线的哪一帧；写明钉在哪一拍，或者**待钉**（第一个渲染块按自己的时间戳钉，可以带 host 时间） |
| `AudioRenderClock.swift` | 引擎的时钟：渲染块每拍记下采样时间、出声卡的 host 时间、这一拍多少帧（只从渲染块的时间戳来） |
| `AudioGraphRun.swift` | 图此刻的状态（没在跑 / 在跑 / 故意停着 / 后台正在起）和后台起图的那条队列 |
| `AudioEngineIdlePolicy.swift` | 图该不该开着（纯值）：没有声音不开、在播开着、停着 30 秒没人用就停 |
| `AudioEngineIdleKeeper.swift` | 照上面那条规矩停图 / 起图：换配置之后、图开着时每 5 秒、用户回来时各看一眼 |
| `MeterSlot.swift` | 电平表的无锁槽：渲染块按拍「比大就换」写峰值，界面每拍取走并清零 |
| `PlaybackAudioSource.swift` | 时钟驱动引擎的那几个方法（协议，不依赖任何东西，`PlayerClock` 的自检只编它） |

## 二、合同

1. **段落和增益的规则只有一份。** `AudioEngineConfig.make` 走的是 builder 插声音的那套判定（整轨 / 单段隐藏、静音、
   还在转静帧的占位块不出声；主轨接缝不到 `mainGapTolerance` 的零头接在上一段末尾；首尾定格留空）和
   `AudioMixBuilder.addVolumeRamps` 那一张增益表（音量 × 渐变 × 曲线，转场交叉淡变的仲裁在 `FadeWindow.previewMainTrack`）。
   自检拿 AVFoundation 的混音当参照逐窗口比，差 ≤ 0.15 dB（重采样的素材 0.3 dB）。
2. **播放头只是几个数。** 渲染块拿引擎的采样时间，按锚点（`PlaybackAnchor`：采样时间 ↔ 时间线的帧）换成时间线位置；
   seek = 发布新锚点 + 各轨喂样从新位置重读；暂停 = 锚点标成不播（出静音）。不拆任何东西。
   图在跑时开播 / seek 的锚点钉在下一拍上；图刚起、停着时不知道下一拍的采样时间，发**待钉**的锚点，由第一个渲染块钉上
   （`PlaybackAnchor`）。暂停之后图还开一会儿，什么时候停见第 11 条。
3. **渲染块实时安全**：不分配、不加锁、不碰 Dictionary / String；草稿缓冲预分配；流的列表、锚点经 `AudioPublished`
   无锁地取；环是单写者单读者。欠载（环里没有数据）计数在 `underrunFrames`，冒烟和自检看它。
4. **喂样在普通线程上**（阻塞读不进 Swift 并发池，[阻塞的媒体读取](blocking-media-reads.md)）；离线渲染时喂样在
   调用方的线程上同步做（每拍先 `service` 再 `renderOffline`）。
5. **一段一条流**：主轨转场处前后两段相叠、增益各不同，渲染块分别乘再相加；不需要 A/B 槽，也没有
   「一轨一格式」这条规矩（每条流自己转格式）。
6. **音频不缓存**：直接读 mp3 / aac / wav 原件；mp3 的精确定位 `AVAudioFile` 自己做。
7. **离线和实时是同一张图**：成片（PR3a 起，`ExportAudioMixdown` → `renderOffline`，[成片的声音](export-audio-mixdown.md)）
   和自检都走 `renderOffline`，和实时播放的渲染块是同一段代码；`renderOffline` 的 consumer 回 false 就停（导出取消）。
8. **引擎的时钟只从渲染块的时间戳来**（节点的 48 kHz 域）。`outputNode.lastRenderTime` 是声卡自己的采样率
   （这台机器 44.1 kHz），拿它算位置播放头会以 0.92 倍速走：2026-10-01 冒烟欠载 51k 帧、视频对表 60 次。
   一个静音的时钟节点一直挂着，没有一条轨出声的时间线也有人每拍更新时钟（图在跑的时候；图停着时见第 11 条）。
9. **「结构没变」= 同样的轨、同样顺序的段、每段同样的几何、同样有没有场景**（`AudioEngineConfig.Segment.Structure`：
   `clipID / url / start / end / sourceStart / speed / hasScene`；`TimelineAudioEngine.sameStructure` 比它）。这些在开流时就抄进
   `SegmentStream`、流活着时改不了，有一项不同 `replace` 就整条重开流（和加 / 删一段同一条路）；只有增益、场景的参数、
   推子能在流活着时换（`updateGains`）。判「能不能只换参数」要和开流读同一批字段 —— 2026-10-01 到 10-06 只比 clipID 的顺序，
   挪一段 / 裁头尾 / 变速 / 换文件之后画面挪了、声音还在原地（[案例](../bugfixes/2026-10-06-audio-engine-replace-keeps-old-segment-positions.md)）。
   自检第 13 组钉着：按 A 建 → `replace(B)` → 渲 = 直接按 B 建。
10. **播放意图不等于渲染图还在运行。** 输出设备的采样率 / 声道变化会让系统停止 `AVAudioEngine`，但
    `PlaybackAnchor.playing` 不会自动变。`PlayerClock` 开播前、播放中的每拍都调 `recoverIfNeeded`：正常图不动，
    停图才重启。重启先保留时间线位置与播放 / 暂停状态、清掉旧采样 / host 时间，重启之后发的在播锚点是**待钉**的，
    由第一拍渲染钉上。**重启之后的采样时间不能指望**：手动渲染从 0 重来，真声卡上接着停之前的数往下走（2026-11-11
    量到的；之前按「从 0 起」钉，真声卡上播放头会跳出去和图开了多久一样长，只是没被撞上）。恢复失败暂停声音和视频、
    记真实错误，下一次点击播放再试，不能持续拿停住的主时钟把视频拉回去。恢复在调用方线程上做，不在音频系统的配置
    通知回调中拆图。
11. **图只在马上要出声时开着**（2026-11-11，[案例](../bugfixes/2026-11-11-preview-audio-engine-never-idles.md)）。图开着就占着
    声卡：coreaudiod 替它挂着 `PreventUserIdleSystemSleep`（Mac 不会空闲睡眠），App Nap 也不生效。
    - **规矩只有一份**（`AudioEngineIdlePolicy`）：时间线上没有要出声的段 → 不开（在播也不开）；在播 → 开着；停着 →
      最近 **30 秒**里有人要用声音（刚播完，或者用户在 SkyCut 里动过鼠标 / 键盘）才开着。30 是用户定的数。
    - **谁来办**：`AudioEngineIdleKeeper`（`PreviewAudioEngineHost` 持有）。换配置之后看一眼（没有声音了当场停）、图开着时
      每 5 秒看一眼、用户回来时看一眼；图停着的时候不留计时器。停图只许经它（`suspend()` 的调用方只有它）。
    - **停**（`suspend`）：`engine.pause()`，节点、流、播放头、播放状态都留着，喂样线程一直睡到被叫。停着 seek、换配置、
      拖推子、读电平表都照常，都不起图。播着停（配置变成没有声音）：播放头改按 host 时间走，位置不跳。
    - **起，两条路**：
      1. 用户回到 SkyCut 动了一下（`AppUserPresence`：全 App 一个本地事件监视器 + 切回前台；**SkyCut 不在前台时的事件
         不算**）→ `wake()` 在后台那条队列上起。按播放时图已经在跑，和一直开着一样。
      2. 时钟要出声时图还停着（回来的第一下就是播放）→ `recoverIfNeeded()` **当场起、等声卡起来、再从原处开播**。
         后台正在起就等它起完。
    - **不许让播放头先按 host 时间走、声音晚点接上。** 起声卡的那段时间里**整个进程的线程一起被拖住**（哪条线程起都一样，
      裸 HAL 也一样，别的进程不受影响），界面这会儿本来就不动；先走的话只是把这一截画面和声音跳过去。
    - **没有声音的时间线**不起图：播放头按 host 时间走（待钉的锚点带 host 时间），视频本来就钉在 host 时钟上。
    - **整个收掉**：换工程、时间线空了走 `unloadPreview()`（卸片 + `audioEngineHost.stop()`）；下一次重建预览再建新的。
      建的时候真起一次图（这台机器没有能用的输出设备在这儿就知道，不挂时钟），随后照规矩停。
    - **播到片尾要有人停主时钟**：`PlayerClock` 听「条目播到头 / 播不下去」停声音源。不然引擎一直标着在播，永远不算停着。
    - **量出来的数**（M1 MacBookPro17,1、内置扬声器、macOS 26.5.2，机器很忙时量的，从按下播放起，毫秒，中位 / 最坏）：

      | 按法 | 画面晚多少 | 声音出声卡 | 开头少了多少 |
      | --- | --- | --- | --- |
      | 一直开着 / 图在跑 | 0.1 / 0.1 | 20 / 26 | 0 |
      | 先动一下、0.25 秒后按 | 0.6 / 4.5 | 22 / 27 | 0 |
      | 冷着按，停 2 秒 | 151 / 255 | 166 / 272 | 0 |
      | 冷着按，停 35 秒 | IDLE35_WAIT | IDLE35_SOUND | 0 |

      冷着按（30 秒以上没在 SkyCut 里动过、回来的第一下就是空格）画面和声音一起晚 0.06–0.27 秒，开头不少；这一种不到
      「多等 < 0.1 秒」。隔了 30 秒以上回来的第一下动作，界面会顿约 0.1 秒（后台起声卡拖住进程）。裸的
      `AVAudioEngine` 停了再起 0.1–0.15 秒（最坏 0.23），裸 HAL 到第一个 IOProc 约 0.06 秒（最坏 0.1）：是声卡的事，
      换写法省不掉。蓝牙耳机上没量（预计更久）。
    - **睡眠断言和 App Nap**（同一台机器）：带声音的工程停着 31 秒之后断言没了、按播放又有；没有声音的工程播着也没有；
      APPNAP_LINE
    - 停图 / 起图各往卡顿日志记一句（「预览的音频引擎：……」，不在主线程上写）。冷着按播放的那一下卡顿日志里会有一条
      卡了一两百毫秒的记录，栈在 `engine.start()` 里：那就是等声卡。

## 三、接进 App 的样子

- **声音是主时钟。** `PreviewAudioEngineHost`（VideoEditProjectAudioMix.swift）在第一次重建预览时建引擎、起图、
  `PlayerClock.attachAudioSource`，然后把引擎交给管空闲的那一位（第二节第 11 条：用不着就当场停）；从此播放头每 50 ms 从引擎读（`observePlaybackTime` 仍是唯一入口），
  播放器的周期回调只用来对表：视频和引擎差过一帧、连着两拍，就 `setRate(_:time:atHostTime:)` 把视频重新钉到
  引擎的时间表上（`driftCorrections` 计数，冒烟结果里有；修完时钟之后 32 秒 4 次 seek 是 0 次）。
- **开播 / seek 都只是改几个数**：`PlayerClock.play()` 先让引擎从播放头起播，再 `setRate` 让视频从此刻起跟；
  播放中 seek 同样 —— 引擎一个 IO 缓冲就出声，视频自己定位、定位要多久就晚多久赶上来（不改时间表）；
  停着 seek 照旧精确定位 / 链式扫帧。暂停 = 引擎锚点钉住 + 播放器 pause。
- **主时钟跟着预览的生命周期**：`detach()` 同时摘掉声音源和它的 Timer；换源先暂停旧源。
  `PreviewAudioEngineHost.apply` 新建或复用引擎之后都要重新接到时钟上，不能继续读已经停止的旧引擎。
  换工程、时间线空了走 `unloadPreview()`：卸片之外把引擎整个收掉（2026-11-11 之前主窗口换成空工程，上一个工程的图还开着）。
  播放器的条目播到头自己停时，时钟把声音源也停掉（`itemEnded`）。
- **合成里只有画面**（PR3b 起 builder 根本不插音轨；PR1b–PR3a 是建完再拆）：播放器只剩画面，seek 才快。
  画面收得比时间线总长早（配乐比画面长、纯音频时间线）时 builder 从画面结尾到总长垫一截黑底：合成里没有音轨撑长度，
  不垫的话播放器的条目比时间线短 —— 播到画面结尾停在最后一帧上，引擎的播放头还在走、时钟每拍都去对表
  （[案例](../bugfixes/2026-10-01-preview-item-shorter-than-timeline-without-audio-tracks.md)；只垫那一截，画面铺满的工程一层都不多）。
  成片走引擎的离线模式（[成片的声音](export-audio-mixdown.md)），不碰播放器的合成。
- **快路径和即时试听走配置**：`refreshAudioMix` / `previewAudioLive` 算一份 `AudioEngineConfig`
  交给 `updateGains`（结构没变只换增益，流不重开；结构变了退到 `replace`；「结构」按第二节第 9 条，几何也算）。
- **试听让路**：`AudioLibraryAudition` 让引擎的总推子乘让路量（播放器没有声音可压）。
- **冒烟静音**：`SRTFLOW_SMOKE_MUTE` 也让引擎静音（渲染照跑，输出不出声卡）；结果里带 `audioEngine`
  （开没开、欠载几帧、视频对了几次表）。
- **电平表**（PR2a 写环，PR2d 改成无锁槽）：每条轨的渲染块按拍把混完的峰值（已乘段增益、场景、推子）交给自己的
  `MeterSlot`（原子的「比大就换」，不加锁、不逐采样写环）；总表从混音器的出口取（实时是 mainMixer 上的 tap，在引擎自己的
  线程上拿到拷贝；离线是渲出来的那一块），所以总表含总推子、让路和静音。槽按键登记进 `AudioMeterEngine`
  （`registerSlots`，换配置时整批重登记；`Track.meterKey`：主轨 `.track(.main)`，其余 `.track(.lane(id))`），
  `reading` 对登记过的键取走槽里的峰值（30 帧/秒读就是最近 33 ms 的峰值），回落 / 峰值保持 / 红灯照旧
  （PR3b 起 `AudioMeterEngine` 只剩槽 + 显示状态，环和 tap 删了）。自检第 10 组：总表的槽 = 渲出来的峰值、
  主轨的槽 × 总推子 = 总表、静音段的轨是 0、隐藏轨没有槽。
- **声音场景**（PR2b）：效果链跟着流（`SceneBox`：链 + 此刻的强度和响度补偿，在喂样线程上建、渲染块里跑），
  顺序：段增益 → 效果（原声 1 − 强度 直出，湿的 强度 × 补偿 从链里出来）→ 推子；段尾之后流还活着、
  喂零、链继续吐余音（`tailFrames`，跟着旋钮变），余音散完才关流；位置跳了（seek、开播）链复位，旧余音不拖进新位置。
  拧旋钮走 `updateGains`：同一种场景只改链的参数，换种类重建链；加上 / 去掉场景算结构变了（`sameStructure`），重开流。
  自检第 11 组：强度 0 = 原声（对着 oracle 比）、浴室的余音越过段尾且越散越小、挂了场景的声音和原声不一样；
  反向验证：不过链 → 8 条红。合同在 [声音场景](sound-scenes.md)。
- **变速**（PR2c）：`speed ≠ 1` 的段由 `AudioTimeStretchReader` 读 —— 离线的小引擎跑 AVAudioUnitTimePitch，音调不变，
  时间线上的长度还是 `sourceDuration ÷ speed`。预览和成片是同一份（自检第 12 组：包络对得上 oracle 的线性重采样、
  换音的时刻按倍速落位、音高不变）。
- 已知：每次 seek / 开播之后头一拍（约 10 ms）环里还没有数据，当静音（欠载计数里能看到，32 秒 6 次 seek
  共 2505 帧）。

## 三之二、读素材：按块读必须和一口气读逐采样相同（2026-10-01）

喂样线程每次读 4096 帧、位置从自己的写指针算；`AudioSegmentReader` 要把这些块接成一条连续的流：

- 不是 48 kHz 的源（AI 视频的 32 kHz AAC、mp3 的 44.1 kHz）经 `AVAudioConverter` 重采样。**拉式喂**：输出缓冲正好要多少帧，
  转换器要多少输入就从文件里现读多少，读到头才 `endOfStream`。推式（一块塞完说 `noDataNow`）每次调用的最后几十帧是错的。
- **是不是上一次的延续按引擎格式的输出帧号判**（素材时间 × 48 kHz，差一帧以内算接上）；跳读才 `framePosition` + `reset()`。
  按输入帧号判（输入输出不成整数比）每块都会判成跳读 —— 重采样器每 85 ms 重新起步一次，就是 2026-10-01 用户听到的沙沙声
  （[案例](../bugfixes/2026-10-01-resampler-reset-every-chunk.md)）。
- 回归：`scripts/check-audio-engine.sh` 第 0 组，三种源按 4096 帧读 vs 32768 帧一口气读逐采样相同、块头 128 帧误差 < −90 dB。
  **整段 RMS 看不见周期性的毛刺**，别拿第 1–11 组的窗口比对当它的守卫。

## 四、还没做的

- seek 后头一拍约 8 ms 的静音：只是起声晚一拍，耳朵听不出，不值得在主线程上做同步预读；先不做。
- 加 / 去掉场景仍走整条预览重建（`differsOnlyInAudioMix` 把「有没有场景」算结构，那是合成音轨要垫载体的年代定的）；
  引擎本身只需重开那一段的流，改成快路径是后续一刀。
- 没有音频输出设备的机器（托管 CI 的虚拟机可能就是）：实时引擎 `start()` 失败时宿主不挂时钟，播放头照旧由播放器走、
  只是没声音。2026-11-11 起引擎有了不靠声卡的时钟（没有声音的时间线按 host 时间走，第二节第 11 条），但建引擎时仍然
  先真起一次图、起不来就不挂；把「起不来也挂上、按 host 时间走」接通是后续。
- 冷着按播放要等声卡 0.06–0.27 秒（第二节第 11 条的表）。能再压的办法都要用户拍板：SkyCut 在前台时空闲时长放长
  （比如几分钟，代价是前台挂着时系统晚这么久才睡）；蓝牙输出设备上的数还没量。
- 几何变了（挪 / 裁 / 变速一段）是整条 `replace`：所有轨的流都重开，播放中大约一个 IO 缓冲的静音。只重开挪了的那一段的流、
  别的流不动（`AudioTrackFeeder` 要能换 `track`）是后续；除了 2026-10-06 那个 bug 没有第二个用例，先不做。

## 五、回归

`scripts/check-audio-engine.sh`（`scripts/check-all.sh` 第 4 组，要 ffmpeg 造正弦素材）：八条时间线
（音频轨 + 推子 + 总推子、渐入渐出、音量曲线、主轨叠化、主轨接缝零头、静音段 + 隐藏轨 + 主轨推子、上层轨、
44.1 kHz 单声道）引擎和 **oracle** 各渲一遍，逐 10 ms 窗口比 RMS、整段 RMS、帧数正好、零欠载，空时间线没有轨；第 10 组电平表
（总表的槽 = 渲出来的峰值、主轨的槽 × 总推子 = 总表、静音段的轨是 0、隐藏轨没有槽）；第 11 组声音场景（强度 0 = 原声对着
oracle 比；场景本身验结构，见第三节）；第 12 组变速（2 倍速和 0.5 倍速：包络对得上、时长正好、过零数出来的音高仍是 880 Hz）；**第 13 组换配置**（`Replace.swift`：按 A 建引擎、`replace(B)`、离线渲 = 直接按 B 建的，
B 分别是挪一段 / 裁头 / 裁尾 / 变速 / 换文件（数过零），只改音量的 B 仍是同一个结构且快路径压 6 dB；反向验证：`sameStructure` 换回只比
clipID → 11 条红）。

**oracle**（`checks/AudioEngine/Oracle.swift`，2026-10-01 PR3b 起）：PR1a–PR3a 期间参照是 AVFoundation 那份混音
（`AVAssetReaderAudioMixOutput`）；删掉那条路之后，参照换成几十行、一眼看得完的纯 Swift 混音器 —— 源文件让 ffmpeg 解成
48 kHz f32（按源的声道数解、单声道自己铺到两边：ffmpeg 的 `-ac 2` 升声道会各乘 0.707），每个采样 = Σ 段的源采样（按源位置
线性插值）× 段增益（`GainTable.Sampler` 逐采样取，引擎按 64 帧一块插值）× 轨道推子，最后乘总推子；变速只按线性插值
重采样（音高会变，量的是包络；换音的瞬间保音调算法要过渡几十毫秒，那两处两侧各 0.1 秒不比）；场景不做。它验的是引擎的
「水管」（喂样、环、锚点、取样与增益插值、重采样、变速、推子）；「哪些段出声、增益表长什么样」在 `AudioEngineConfig.make`
里两边共用，由 `check-audio-fade.sh` 的绝对期望兜着。实测差：正弦 ≤ 0.027 dB、44.1k 单声道重采样 0.29 dB。
反向验证：渲染块不交峰值 → 两条红；渲染块不过效果链 → 八条红；**oracle 不乘轨道推子 → 五组十条红**（推子 ≠ 1 的那五条时间线）。

`scripts/check-audio-fade.sh` 的「预览」那一路 2026-10-01 PR3b 起也是引擎离线渲（`enginePCM`；快路径 = 老配置开引擎 + `updateGains`
再渲，和按新状态重开引擎比；电平表 = 挂着表渲、每拍先看槽再取走；钉点不变量 = 每一段的增益表第一个设定点不晚于段起点、起点处
就是该起步的音量）。

反向验证（2026-10-01）：渲染块不乘段的增益 → 渐变 / 曲线 / 叠化三组红（792 / 690 / 192 个窗口）；
喂样把素材起点读错 100 ms → 四组红（段尾一边有声一边静音）。恢复后 49 项全绿。

进程内冒烟（南极工程拷贝，`SRTFLOW_AUDIO_ENGINE=1`，播放 32 秒 + 4 次播放中 seek + 暂停 / seek / 播放）：
引擎开着时进程 CPU 约是关着时的一半（16.8 s vs 35.9 s），视频对表 0 次，欠载只有每次 seek 的头一拍。
成片（PR3a）：`checks/export-audio-single-pipeline.sh` 钉着混音只经 `AudioEngineConfig.make` + `TimelineAudioEngine(.offline)` +
`renderOffline`（反向验证：换掉模式 → 点名一行；不用 `make` → 两行红）；`scripts/check-audio-fade.sh` 导出那几组真跑导出、
和预览（引擎离线渲）逐窗对。性能 ratchet：PR3a 开关默认开之后 `meters.tapCreate` 归零，PR3b 把这两个键删了。
合成只有画面（PR3b）：`scripts/check-preview-composition.sh` 第 0b 组钉着合成里没有音轨、配乐比画面长时合成铺到总长且尾巴是黑的、
纯音频时间线也有铺到总长的画面轨、画面铺满时不垫（反向验证：不垫尾巴的黑底 → 三条红）；`checks/transition-handles-wiring.sh`
钉着 `AudioEngineConfig.make` 自己展开转场；`checks/timeline-drag-wiring.sh` 钉着重建把配置连同电平表交给引擎、换增益的两个入口走
`updateGains`。

人工回归（开关开着）：播放中点时间线声音是否立刻接上、暂停 / 播放是否立刻、视频和声音对不对口型、
拖推子 / 音量线时声音是否跟手、试听音乐时时间线是否让路；导出一条有场景 / 变速 / 音量曲线的工程，成片和预览逐段听。

**第 14 组（2026-11-05）**：`checks/AudioEngine/Recovery.swift` 真停原生图，再走生产的 `recoverIfNeeded`，
验证重启、时间连续、采样时间归零后继续推进、保留暂停状态；使用 manual rendering，CI 无声卡也执行。
开发机另跑 `scripts/check-audio-engine.sh --realtime-recovery`，静音验证实际输出设备，启动失败必须红。
`scripts/check-player-clock.sh` 用可控声音源 + 真 AVPlayer / Timer 验开播前和播放中恢复、失败停播与手动重试、
换源、卸片以及复用源重新接线。案例与反向验证见
[声音主时钟停住导致预览无法播放](../bugfixes/2026-11-05-audio-master-clock-stops-playback.md)。

声音源自检的正向异步断言按条件等待：用单调时钟给出 5 秒上限，期间持续泵真实 RunLoop，条件达成立即继续。
图恢复完成和恢复后的播放头推进分开等待，不能要求两者挤进同一个 200 ms 窗口；超时后仍由原断言报失败，不能重跑来掩盖。
假声音源固定注入 250 ms 的恢复延迟，保证这条边界每次都被覆盖；失败后不重试、卸片后不回写仍保留观察窗口。
案例与反向验证见 [声音恢复自检的固定等待窗口](../bugfixes/2026-11-05-player-clock-recovery-check-timing.md)。

人工回归补充（设备事件不能由合成停止完全替代）：

- [ ] 播放途中插拔音频设备 / 切换不同采样率的输出设备，播放头与画面能恢复前进，声音与画面对齐。
- [ ] 暂停后睡眠 / 唤醒，再点击播放，播放头继续前进；没有输出设备时恢复失败须停播，不能显示一直在播放。
- [ ] 工程窗口转后台再显示、主窗口换工程后播放，不能继续读取已停止的旧声音源。
