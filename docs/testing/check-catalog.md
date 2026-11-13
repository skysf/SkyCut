# 检查细目：每项检查具体验什么

> 2026-11-13 从 AGENTS.md 的「构建与检查入口」搬来。AGENTS.md 那一节现在每个脚本只留一行（哪个脚本、管什么、在不在
> `check-all.sh` 里、要不要图形会话）；这里是细目：每项检查验哪些情形、用例放在哪个文件、哪些要图形会话或真设备、偶发怎么认。
>
> **新加或改了一项检查**：在 AGENTS.md 那一节补 / 改一行，细节写在这里（或写进对应架构文档的「守卫 / 回归」一节，再从这里链过去）。
> 分组只以 `scripts/check-all.sh` 为准，下面提到的组号是写下那一条时的位置。条目的顺序是当时往 AGENTS.md 里加的顺序，没有重排；
> 找某个脚本直接搜它的名字。

- 官网样式表的先后（构建按共用关系分块，覆盖规则不许排在基础规则前面）：`website/tests/css-cascade.test.mjs`（源码级）和 `npm run check:seo`（按每个构建出来的页面实际加载的样式块核对），都在 CI 的网站那一步里。

- 官网的小字（手机上不小于 12 px、演示区对比度、标题层级、首屏不随字体挪动、演示打字时对话窗不变高）：`website/tests/legibility.test.mjs` 在 CI 的网站那一步里；浏览器里量的那一半 `npx -y -p playwright@1.65.0 node scripts/check-legibility-browsers.mjs` 是手动的（无头、只在 Mac 上，**不在 `check-all.sh` 里**），见 [SkyCut 官网](../architecture/skycut-website.md)「小字读得清」。

- 官网首屏的静图与浏览器检查（在 `website/`）：改了场景外观后 `npm run build:hero-still` 重烤（无头 Chromium + Pillow），`tests/hero-scene.test.mjs` 的指纹钉着「改了没重烤」；浏览器级的手动检查 `npx -y -p playwright@1.65.0 node scripts/check-hero-browsers.mjs`（三个内核 36 格（含首屏几栏的版面哨兵）+ 版面框 + 18 项回退行为，全程无头、只在 Mac 上、Playwright 不是依赖，**不在 `check-all.sh` 里**），见 [SkyCut 官网](../architecture/skycut-website.md)「首屏的质感与渐进增强」。

- 导出阶段计时与快速审阅：`scripts/check-export-profile.sh`（真实任务/排队/取消、PNG 仅解码一次，以及真实短进程退出/双管道/错误/取消的回归），合同见 [导出设置](../architecture/export-settings.md)与[子进程退出](../architecture/blocking-media-reads.md)，实测见 [2026-11-02 导出耗时与快速审阅](../reports/2026-11-02-export-profile-review.md)。

- 公开制作状态：`scripts/check-film-production.sh` / `checks/film-production-wiring.sh`（真实模型的图 / CAS、绑定与审查失效、实际转场 / 画布 / 混音、原生帧角色、目录换 Key；完整工具 / undo / 后台媒体另经 MCP 验收），合同见[官方原创短片](../architecture/official-film.md)。

- 引擎启动探测：`scripts/check-engine-probe.sh`（合成短命令的超时、双输出上限、退出码、文件描述符、退出回收窗口、候选去重和单次定位；不读取媒体或调用云端），合同见[阻塞的媒体读取](../architecture/blocking-media-reads.md)「引擎启动探测」。

- 成片 MCP 疑点检查：`scripts/check-video-inspection.sh`（独立合成工程、真实混音/画面/字幕与试听，不编辑工程）；合同见 [成片疑点检查](../architecture/finished-video-inspection.md)，实测见 [2026-11-02 成片检查](../reports/2026-11-02-video-inspection.md)。

- 构建与打包的 Rosetta / arm64 要求、常用命令、打包和验收（含 DMG Retina 背景 / Finder 布局）、公开下载发布（含 0.18.59–0.18.66 的签名包与下载回读记录）：
  [docs/build/build-and-packaging.md](../build/build-and-packaging.md)。
- 音频库素材的制备与上传（音乐：选曲 → 规格化 → manifest → R2；音效：手写目录 → 峰值归一 + 落点 → manifest → R2）：
  [docs/build/audio-library-pipeline.md](../build/audio-library-pipeline.md)。
  脚本在 `scripts/audio-library/`，**不在 `check-all.sh` 里**（它制备素材，不是检查）。
- 本机配音模型（Kokoro）的整理与上传（钉版本的来源 → 整理 + 清单 → R2，密钥放仓库外）：
  [docs/build/voice-model-pipeline.md](../build/voice-model-pipeline.md)。脚本在 `scripts/voice-models/`，R2 签名只有 `scripts/r2.py` 一份，
  **不在 `check-all.sh` 里**。
- 全部自动检查：`scripts/check-all.sh`。CI 在每个 PR 上运行同一入口：
  `.github/workflows/checks.yml`，按 `--shard N --of 5` 分到 5 台免费的 macOS runner 上并行跑，
  由一个叫 `check-all` 的汇总 job 给结论（分组、组数校验、汇总 job 为什么不能被跳过，见
  [构建与打包「CI」一节](../build/build-and-packaging.md)）。新加检查要放进某个 `shard`：要链接完整 App 目标文件的
  放第 1 组（只有那台编了完整 App），别的放第 2–5 组里最空的那组；文档里提到检查时别写组号（分组只以 check-all.sh 为准）。
- 核心库：`swift run --arch arm64 SrtFlowCoreChecks`（含字幕折行的文字规矩 `SubtitleRowBreakChecks`：中日文的词在哪、能在哪儿断、断在哪好；含逐词高亮：词对到去完标点的字上、此刻亮哪个、跟着编辑走、按词切段、ASS 标签，`SubtitleWordChecks`）。
- 生成的字幕长什么样（去标点、断句、一行多长、显示时间、几段素材同时有字只留一条，用例是用户工程里真实转写出来的句子）：
  `SrtFlowCoreChecks` 的 `SubtitlePunctuationChecks` / `SubtitleSegmentationChecks` / `SubtitleSourceOverlapChecks`；
  藏起来的段不转写、「只用选中的片段」在 `scripts/check-project-file.sh`（`HiddenItems.swift`、`SubtitleSources.swift`）+ 接线扫描 `checks/project-file-wiring.sh`；
  几行（默认单行、两行的折行点）在 `SubtitleSegmentationChecks` 的 `checkTwoLineBreaks`，行数跟着工程走在 `scripts/check-project-file.sh` 第 46 组
  （`SubtitleMaxLines.swift`）、AI 的 `max_lines` 在 `scripts/check-mcp.sh` 的 `SubtitleLinesChecks`、接线同样在 `checks/project-file-wiring.sh`。
- 工程存盘与素材重链接、选择模型（点选互斥 / 框选混选）、轨道块标记：
  `scripts/check-project-file.sh`；这批合同**有没有被生产代码调用**的接线扫描（隐藏清单、调色 / 盖一块 / 形状 / 文字读 `rendered*`、
  字幕生成的可听快照等）单独成 `checks/project-file-wiring.sh`：秒级、不编译、进 check-all，**搬代码 / 改名之后先在本地跑它**
  （原来接在上一个脚本末尾的编译后面，本地跑不到，[PR #84 首跑 CI](../bugfixes/2026-09-29-pr84-first-ci-run-wiring-guard-in-moved-code.md) 才红）。
- 播放头与悬停 peek 状态机，以及播放头的慢读法 `PacedPlayhead`（只跟「放置」、播放中不跟、停下追上一次、
  不认悬停），还有「回到开头」（Return / Home）只由 `goToStart` 请时间线滚回最左、普通 seek 不许，
  以及卸片之后晚到的时间回调不许把播放头写回旧位置（真播放器、ffmpeg 现做的带声音素材），还有播到头由声音主时钟自己收尾（播放头正好钉在总长上、不再往后走）、在尽头不 seek 直接再按播放不开播、旧的「播到头」通知晚到时已经回退重播的新一轮照样播（真播放器 + 2 秒的短素材）：
  `scripts/check-player-clock.sh`。
- 不许同步问播放器要时间（`currentTime()`，会被播放器的锁堵住主线程）、AVKit 的 Now Playing 必须关着、电平条读时钟外推的
  `estimatedTime`：`checks/player-time-no-sync-read.sh`；外推的算术在 `scripts/check-player-clock.sh` 第 12 组。
- 音频引擎的等价自检（同一条时间线：引擎离线渲染 vs 纯 Swift 的 oracle 混音器（`checks/AudioEngine/Oracle.swift`：ffmpeg 解码 + 逐采样乘增益表），逐 10 ms 窗口比 RMS ≤ 0.15 dB、帧数正好、零欠载；电平表的槽、场景、变速；**换配置之后按新的几何出声**（第 13 组 `Replace.swift`：按 A 建引擎、`replace(B)`、渲 = 直接按 B 建，B 是挪一段 / 裁头 / 裁尾 / 变速 / 换文件；只改音量仍是同一个结构、走快路径）；**引擎不是一直开着的**（`Idle.swift` / `IdleEngine.swift`：规矩、照规矩停 / 起（假引擎 + 自己拨的钟 + 真计时器）、停过再起播放头一帧不跳、播着停图位置不跳、没有声音不起图、后台起图没起来不空转（注一个起不来的图），手动渲染、无需声卡；`IdleHandoff.swift`：后台正好从 starting 交接到 running 的那一下图照样算开着、管空闲的不撤计时器（`didReadState` 把那一下原样造出来，外加真并发的旁证）；`Presence.swift`：用户在不在从启动就看、只往后走、指针移出不算））：
  `scripts/check-audio-engine.sh`（第 4 组，要 ffmpeg 造素材）；开发机另有三个真声卡的模式（全程静音，CI 的虚拟机没有声卡）：`--realtime-recovery`（被系统停掉再恢复、不跳出去）、`--realtime-idle`（空闲停图、冷着开播第一拍就是起点的声音、先动一下再按不用等、没有声音的时间线播着图不开；加 `--silent-only` 只跑送数字静音的那几段）、`--measure-idle [停多少秒] [几轮]`（量停过之后第一次播放多等多久，只打印）。接线：`checks/audio-engine-idle-wiring.sh`（扫描守卫：引擎交给管空闲的、换工程 / 时间线空了收引擎、2 分钟、用户回来在后台起（四样信号齐全、启动就看、移出不算、只往后走）、要出声时当场起不让播放头空走、在播的锚点待钉和「报过时间没有」的内存序、主时钟自己收尾且不听「播到头」通知、日志不在主线程上写、起不来不空转、一个判断只读一次图的状态）。
- 优化媒体：判据是纯函数（长 GOP 且按这台机器的解码速度才转）、关键帧间隔扫采样表量得出、解码速度量得出、真转一块
  （0.5 秒内必有关键帧、没有 B 帧、帧数 / 尺寸 / 时长 / 旋转对、首尾帧和源一样、不带声音、最后一块到源结尾、能取消）、变帧率的源
  （静止期一帧撑住、整块都在静止期里也盖住整块、块头先出一帧、块尾到源结尾、29.97 的格子）、缓存按身份认、超上限丢最久没用的、过期删、
  上限从设置读（默认 10 GB 十进制、低于下限按下限、几档）、过期的天数、清空之后什么都不剩且还能再落块：`scripts/check-optimized-media.sh`
  （第 2 组；素材 AVAssetWriter 现写，不依赖 ffmpeg）。**按块换源**（段跨几块插几段、时间账不动、画面同原片、块没齐 / 没了退回原片、
  变速 / 上层轨 / 4K 减半、先转播放头附近的）在 `scripts/check-preview-composition.sh` 第 0d 组；接线（换源只在预览重建、成片 / 预渲染 /
  AI 看永远原片、停着才换、切工程作废、菜单不读工程、性能台架量原片；清空之后紧跟 reset + 重建、缓存目录和上限的键只经 Store、
  改上限立刻 enforce、启动时在 proxy 队列上过期、转不了的只在菜单里标不写提示条）：`checks/optimized-media-wiring.sh`（扫描守卫）。
- 主线程心跳看门狗（主线程没卡不误报、卡过阈值记时长 / context / 栈、日志文件、stop 之后不记），以及挂起主线程抓栈期间
  抓栈线程一次都不分配 / 释放内存（第 6 组：`malloc_logger` 钩子逐次数，确定性）、主线程不停分配时连续抓栈不卡死（第 7 组）：
  `scripts/check-main-thread-watchdog.sh`；日志在哪、怎么读见 [主线程卡顿日志](../testing/main-thread-stalls.md)。
- 预览合成真取帧，以及素材缓存命中时合成逐帧一样、同一路径换了文件或原地改写过必须重开，
  还有往合成轨上接素材只从末尾接、合成完正好和时间线一样长（多一格视频合成就无效 → 黑屏），
  以及切片表按格子铺、首尾相接（接缝差 0.2 毫秒、画面比配乐早收 0.3 毫秒都不许空出一格），主轨接缝的零头那一格不黑，
  还有压黑 / 闪白逐帧对 xfade 的公式、闪白露出白底、带关键帧的段推移真滑动（`TransitionLook.swift`）：
  `scripts/check-preview-composition.sh`。
- 录屏产物画面轨盖到 T1（尾部不黑）：`scripts/check-screen-recording-writer.sh`。
- 上层视频轨动画段 fill + matte：`scripts/check-export-alpha-compositing.sh`。
- 入场/出场动画的两条管线对账（预览取帧 vs 真导出抽帧）：`scripts/check-clip-animation.sh`。
- 上层视频轨铺满 + 画面渐变的真产物（真跑导出再抽帧），以及上层轨藏起来的段不进成片、透明 PNG 的透明处露出下面那一层
  （预览、静态的成片、带关键帧的成片）、上层轨带缓动的关键帧 matte 和画面按同一条曲线走：`scripts/check-video-fade.sh`。
- 检查器的 live 绑定只准接滑块和 scrub（离散控件没有结束信号，快照会挂着把
  下一次改动抹掉）：`checks/inspector-live-binding-wiring.sh`。
- 画面文字：渲染图与成片**逐点重合**（同一个渲染函数是这套东西的全部前提），
  以及动画的「模型给多少、成片就是多少」、预览上的可点范围、老虎机首帧 / 末帧就是起止值，
  还有主字体里没有的字（✨、汉字）用回退字体画（和直接用那款字体画的墨迹重合），以及带动画的字切成的几段在接缝上每一帧正好贴一层（几段拼接的主轨 +
  起点不在帧格子上，`SeamFrames.swift`）：
  `scripts/check-text-render.sh`。
- 形状：预览那个画法（`ShapePreviewDrawing`，离屏渲一张）和导出那张（`ShapePNGRenderer`）逐像素重合（白色形状铺黑底：最亮的一点、墨迹外框、
  重合度、平均差；五种形状 × 描边 / 实心 × 不动 / 画到一半 / 擦除 / 缩放 / 半透明，「画了 0」两边都空），以及入场 / 出场动画真跑导出抽帧
  （入场画到一半、中间一整圈、出场淡到一半、段外没有、只逐帧渲动画那两截）：`scripts/check-shape-render.sh`（第 5 组）；
  纯值的一半（求值、笔顺、存盘、v31）在 `scripts/check-project-file.sh` 第 44 组。
- 预览上的字幕和烧出来的一样大（预览那个视图离屏渲一张、照导出那条路真烧一帧比字的外框：几种字体、字体里没有的字按回退的那一款（Helvetica 里的中文本机走苹方、CI 没下载苹方就两边换冬青黑体；韩文）、默认样式的粗体、逐词高亮放大），以及回退到系统私有字体时换内置字体的规矩，还有**在哪儿折行**（`WrapChecks`：25 种放不进一行的句子 —— 两行 / 三行 / 五行、中英混排、很长的单词、布局覆盖、9:16、左 / 右对齐、逐词高亮放大、两个空格、带换行、没有空格的中文、带标点的中文、中英文连着写、带空格的韩文 —— 预览离屏渲 vs 真烧按墨迹切成几行比每一行的左右沿，预览每行的宽还要等于 `SubtitleLineWrap` 算的；外加折行的规矩本身：100 号五行的每一行是哪几个字、中文在词和词之间折两行摊匀、L16 测试工程那几句在 56 / 72 / 96 号 × 0.4–1 个画面宽下词和「5分钟」都不拆（名字 72 号以内不拆）、句中的空格是首选的断点、逗号 / 开括号 / 长音不落在行首 / 行尾、日文在假名和汉字之间折（只纯算：假名的回退字体在没下载苹方的机器上预览比成片宽 2.5%，另案）、韩文只在空格处、超长单词照旧溢出、行首行尾的空格不算、亮着的词放大那一行变宽，以及烧录的 ASS 是 WrapStyle 2、折行点写成 `\N`、亮着的词换算到新的字里），还有字幕在预览和成片里摆的**位置**（底部 / 居中 / 顶部 × 一两行 × 英文 / 混排 × 五种字体，上下沿差 ≤ 3 px：libass 的行框用 win 量度、预览用 hhea；**行距** 1.4 / 1.25 的两行样本，烧录垫的空行和预览多出的间距量出来要一样）、字幕**阴影**真画出来的像素（中灰底上白字，预览和成片各量右下多出来的暗处：偏多少、最黑的一点有多黑，透明度写反、哪一边没画都会红），以及字幕字体清单的 cmap 体检（手造的坏 format 12 子表判不安全、装了圆体的机器上它不进清单）：`scripts/check-subtitle-burn-size.sh`；ASS 里点名字体和逐词高亮一起写在 `SrtFlowCoreChecks` 的 `SubtitleWordChecks`。
- `.contentShape` 不许写在 `.offset` / `.rotationEffect` / `.scaleEffect` 之后（几何效果只挪画面、
  不挪布局框，可点范围会留在原位）：`checks/hit-shape-before-offset.sh`。
- `PreferenceKey.reduce` 不许写成 `value = nextValue()`（兄弟节点的默认值会把量出来的尺寸盖成零）：
  `checks/preference-reduce-keeps-value.sh`。
- 放进 `List` 的视图里 body 带 `Section` 的，构造处不许套 `.equatable()`（EquatableView 在 List 里只算一行，整节只剩标题）：
  `checks/list-section-not-equatable.sh`。
- 滤镜调色：LUT 数学（强度那条等式）、层号规则，以及**预览与成片逐像素比对**
  （配方 ↔ CoreImage ↔ 真跑 ffmpeg），以及纯黑不抬（十款的纯黑那一格、CoreImage 渲纯黑、真导出里黑底素材和空档盖了褪色胶片还是纯黑）：`scripts/check-filters.sh`。
- 滤镜挂到播放器上这段接线（拍窗口数像素）：`scripts/check-filter-preview-attach.sh`。
  **要图形会话，故意不在 `check-all.sh` 里**，改 `VideoEditFilterPreview.swift`
  时按 [GUI 冒烟流程](../testing/gui-smoke-testing.md) 跑。
- 盖一块（模糊 / 马赛克）在成片里真的盖了（真跑生产导出再抽帧：只改那一块、块外和基线一致、外接框就是那块、高斯剖面贴着理想的阶跃响应、马赛克格子边长对且从左上角起算、只在那一段时间里盖、形状压在它上面不被糊、调色在它前面、藏起来的不导出、不算总长）：`scripts/check-cover-export.sh`（`check-all.sh` 第 5 组）。
- 导出水印真的叠上了、只在该在的地方（纯值：logo 的路径、PNG 白字带阴影 70%、跳的表不连续同一处、四角 / 正中多大放哪、分段表达式逐时刻求值一致且平衡；真导出开着 / 不开各导一遍抽帧比：每一段落在表上那一处、4 秒边界上正好换、盖满画面的形状上面照样有、不加时参数里没有水印、缩到 480p 之后还在那一角）：`scripts/check-export-watermark.sh`（`check-all.sh` 第 5 组）；加不加只问 `WatermarkPolicy`（纯值里验：授权要加 / 测试开关才加、要加却读不出 logo 抛错）、导出器拿授权问且读不出 logo 不导、每一处问它都传授权、只有导出器调 `plan()`、叠在烧字幕之后缩小之前：`checks/export-watermark-wiring.sh`（第 1 组）。
- 预览上的盖一块真的盖上了（生产的 `CoverHostView` 放进真窗口、拍屏数像素：块里糊成混色块外还是硬的、改动的行正好是块的上下沿、调色带上了、马赛克格线从块的左上角起算、两块同时盖、撤掉之后回到参照）：`scripts/check-cover-preview-attach.sh`。**要图形会话，故意不在 `check-all.sh` 里**，改 `VideoEditCoverPreview.swift` / `VideoEditCoverFilters.swift` 时按 [GUI 冒烟流程](../testing/gui-smoke-testing.md) 跑。
- 声音渐入渐出、音量曲线与推子的真实包络（预览 = 引擎离线渲、导出 = 真跑 ffmpeg 两条管线），电平表（挂着表离线渲，
  对账轨道表 / 总表 / 红灯），以及过 0 dBFS 的混音过真峰值限幅器（没过顶逐采样原样、过顶一个采样不超上限、稳态正弦不削成方波、
  尖峰时刻不变、总长不变）、整段响度按 BS.1770 且和 ffmpeg 的 `ebur128` 一致、成片响度和混音一致（第 10 组）：`scripts/check-audio-fade.sh`（带看门狗：渲混音卡住
  4 分钟就判红，并说出卡在哪一组；CI 上第 7b 组「2 倍速曲线 · 导出」差 1–2 dB 偶发，认法见
  [推子与电平表](../architecture/audio-mixer.md)「已知的偶发」）。
- 波形数据（多级峰值、原始采样块）逐采样对账，以及**很多文件同时读**必须全部读完、
  不许把线程池堵死（看门狗判红）：`scripts/check-waveform.sh`。
- 成片的声音只有一条管线（导出图里不许出现声音滤镜，混音是预览那个音频引擎按同一份 `AudioEngineConfig`
  离线渲出来的）：`checks/export-audio-single-pipeline.sh`。
- 读采样的阻塞循环（`copyNextSampleBuffer`）不许写在 async 函数里（会占住 Swift 并发
  线程池的线程，文件一多整档 QoS 死锁）：`checks/blocking-media-reads.sh`；同一条还钉着白名单上那个例外（`AudioWindowReader.extract`）
  只许字幕生成调，别处走 `QueuedAudioWindow`（读取在 `MediaReadQueue` 上）。
- 生产导出帧率与分辨率（真跑导出：数帧、读成片尺寸 —— 只降不升、按短边、像素是方的）：
  `scripts/check-export-frame-rate.sh`；禁止写死帧率扫描：
  `checks/no-hardcoded-fps.sh`。
- 关键帧的缓动（每种曲线的值、linear 逐位一致、set / clipped / stretched / remapped 保曲线、存盘按需写键 + 老文件 + v27 / v32、冲过头时宽高留下限和最低不透明度放宽、切片按帧 / 线性一片不多 / 400 片上限）：
  `scripts/check-project-file.sh` 第 39 组；AI 的 `set_keyframes easing`（默认 easeInOut、词表对账、读回来带曲线）在 `scripts/check-mcp.sh`；缓动的缩放真合成
  （片数 = 帧数、四分之一处的面积按曲线）在 `scripts/check-preview-composition.sh`。
- 定格时间线变换（含在最后一帧里定格时不到一帧的右半不留）：`scripts/check-freeze-frame.sh`。
- 按钮提示与快捷键单一来源、提示的根在 `.appLanguage()` 外面裁成气泡的形状（气泡的形状只写一处）：`checks/instant-tooltip-wiring.sh`。
- 检查器里的菜单 Picker 不许锁死宽度（锁了会把整列撑宽、右边被裁）：`checks/inspector-fits-width.sh`。
- 字幕编辑期间全局快捷键让路（⌫ 不删正在编辑的 cue）：
  `checks/subtitle-editing-wiring.sh`。
- 界面文案在 en 原文表和每一张译文表都配齐（表按 `Resources/*.lproj/` 现场找，`InfoPlist.strings` 一并对账）、无重复键、占位符一致：
  `scripts/check-localization-coverage.sh`。
- 提示面板的真实落点（摆好之后不许自己变）、浅 / 深（系统深色 + 森林色时仍是浅色面板）和气泡外面四个角透明（森林色不许露出一圈直角方框）：`scripts/check-instant-tooltip-panel.sh`。
  **要图形会话，故意不在 `check-all.sh` 里**（无图形会话会假红），改
  `InstantTooltip.swift` 时按 [GUI 冒烟流程](../testing/gui-smoke-testing.md) 跑。
- 切主题、系统切深浅色之后，开着的主窗口（SwiftUI 场景）、工程窗口、录屏控制条、sheet、popover、提示面板的窗框、SwiftUI 读到的浅 / 深、画出来的底色都和新主题一致（森林色永远浅，经典色跟系统）：`scripts/check-theme-switch.sh`。**要图形会话，故意不在 `check-all.sh` 里**，改主题的浅 / 深、呈现根、自建窗口的外观时按 [GUI 冒烟流程](../testing/gui-smoke-testing.md) 跑；写法（不交 nil、只有一处 `.preferredColorScheme`、不设 `NSApp.appearance`）由 `checks/app-theme-wiring.sh` 在 check-all 里钉着。
- 时间线缩放的锚点（横向钉指针那一刻、工具栏钉播放头 / 视口正中、纵向按行认的那一处），以及播放跟随
  （开关关着到哪都不推、开着只在边上推、推到 15%）和剪辑页记住的开关（五个默认值、没记过 / 记坏了读默认值、脚本驱动时永远默认值）：
  `scripts/check-timeline-zoom.sh`；接线（不许 hitTest 找滚动视图、唯一缩放入口、⌥ / ⌘↓⌘↑ 纵向）在
  `checks/timeline-drag-wiring.sh` 的缩放一节（`checks/timeline-drag-wiring/zoom.sh`），记住的开关 / 播放跟随的接线
  （默认值的字面量、只从 `EditorToggles` 读写、工具栏四个开关在小视图里、播放头竖线里推横向滚动正好两处）在
  `checks/timeline-drag-wiring/toggles.sh`。
- 时间线吸附、框选命中与生产落点，以及点一下播放头落到哪（全局夹紧、点块不出这一块：`TimelineSeek`），还有**联动**（压在主轨块上的东西跟着
  它的画面走：删 / 换位 / 切删 / 裁头 / 变速 / 定格 / 粘贴的同素材新段不算 / 撞上让开 / 拖动计划的名单，第 1f 组 `checks/TimelineSnap/Linkage.swift`；
  同 id 换了素材（upscale 换源、edit_clip 换文件）什么都不挪，第 1i 组 `LinkageSwap.swift`）：
  `scripts/check-timeline-snap.sh`；拖动/框选接线扫描：`checks/timeline-drag-wiring.sh`（拆在 `checks/timeline-drag-wiring/` 下的几节一起
  `source` 进来，含「拖动会话不进时间线的 @State」`drag-box.sh`、联动的接线 `linkage.sh`：`perform` / `liveApply` 收尾调 `TimelineLinkage.follow`、
  只有 ⌫ / delete_items / cut_speech 传 `deletesContent: true`、三个拖动计划带上压着的东西）。
- 冒烟拷工程的脚本不许整夹拷「下载」「桌面」「文稿」、家目录、根目录，太大的文件夹也不拷（真跑脚本、假的家目录）：`checks/copy-project-guard.sh`。
- **进程内 GUI 冒烟**（人在用这台机器时也能跑：不动鼠标、不抢前台，按步骤表点 / 拖 / 滚 / 按键，
  结果里带选择、各段位置和每个视图重算了几次）：`scripts/gui-smoke/in-process/run.sh <步骤.json> [工程拷贝]`。
  **要图形会话，不在 `check-all.sh` 里**；格式与坑见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之六」。
- **真客户端实测**（真 Claude Code / Codex 跑八个任务：每轮 SkyCut 常驻多少 token、整份预先加载多少、找工具花多少、选没选对、规矩守没守）：
  `scripts/gui-smoke/client-measure/`（`compare.py` 和上一次对照、按方案 6.4 判）。用用户自己的额度、**每次开跑前问用户**（2026-11-10 用户同意方案剩下的两次 Claude Code 实测直接跑），隔离的测试身份 + 假 Sky Studio，**不在 `check-all.sh` 里**；见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之十」。
- 实测证据（`docs/reports/*.json`）和实测脚本自带的数据（`scripts/gui-smoke/client-measure/*.json`）里没有本机的绝对路径（临时目录的名字里带着账户名）：`checks/report-evidence-no-local-paths.sh`。
- **扮成 AI 客户端驱动测试版**（MCP 冒烟：起 App 包里的 `skycut-mcp`，照 JSON 调用表发工具调用，`look` 的图存成 jpg）：
  `scripts/gui-smoke/mcp-client/client.py`。要装好的测试版、素材复制到 scratchpad，见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之七」。
- 跨 App 的文件拖放重放（自带拖源，Finder 不吃合成事件）：
  `scripts/gui-smoke/external-file-drag/replay.sh`。**要图形会话，故意不在
  `check-all.sh` 里**，按 [GUI 冒烟流程](../testing/gui-smoke-testing.md) 跑。
- SwiftUI 落点路由探针（每格一种 `.onDrop` 组合，回调全记日志；改时间线的落点结构
  之前先在这儿测）：`scripts/gui-smoke/drop-routing-probe/probe.sh`。同样要图形会话、
  不在 `check-all.sh` 里。
- 从 Finder 拖文件进轨道的落点（撞上就抬一轨、多文件接龙、隐藏轨跳过、落地后
  主轨仍按时间排序）：`scripts/check-media-import.sh`；接线扫描（含「整条时间线
  只许一个 `.onDrop`」）在 `checks/timeline-drag-wiring.sh` 里。
- AI 接口（MCP）：给 AI 的文字按客户端怎么读（总说明 ≤ 1,200 字、每个工具的名片 ≤ 450、参数说明 ≤ 120 且写范围、参数定义 ≤ 4,500 字节（例外 edit_clip、generate_media）、前 512 字自成一体且点到 skycut_guide、只用英文，`CatalogTextChecks`；全清单 ≤ 100,000，`CatalogBudget`）、说明书 `skycut_guide`（清单里第一个、只有它预先加载、名片 ≤ 450、每个工具一个同名主题、地图把每个工具列成一项、五个通用主题（rules / conventions / paid / workflows / errors）、一次 ≤ 6,000 且长的分节、写错的回地图 + 猜的、报错指到说明书、手写的文字只提真有的名字、只用英文、App 照答，`GuideChecks`；fields 写全每个参数的可选值 / 类型并集 / anyOf / 条数 / 长度、例子过参数定义、related 是真主题、不含凭据，`GuideContentChecks`；迁移过的工具名片上写按性质的固定说法、迁移前的原文还在、fields 自动切节不丢行，`GuidePilotChecks`；和 recipes 同一行 Policy 在 `checks/MCP/router-wiring.sh`；不等授权在 `GateChecks` + `checks/sky-studio-wiring.sh`）、小程序说的协议（老一代握手 / 新一代每个请求自带版本，真起小程序、假 App 接调用，几百 KB 的图原样穿过通道）、AI 改时间线的规则、客户端配置的增删、词表和 App 类型对账、打包把小程序装进 Helpers 且先签它，
  新东西默认放哪（点名的文件夹 → 工程的家 → 下载，没有「影片」；AI 改了没存过的工程马上存）、窗口只在一轮开始时摆到前面，
  以及 AI 的手和眼：铺满时窗的四角正好落在画布四角（各种比例 × 焦点）、去黑边、对准主体（真让 Vision 认一张图、框不许上下反）、
  look 的拼图和文字描述、listen 的电平 / 静音段 / 曲线，总说明里「不用外部工具改素材」那一句；现有功能铺满的纯值规则
  （剪辑的其余设置、轨道推子、关键帧、形状、复制一份、音乐库的署名句、压缩 / 烧录的参数与起名），以及压缩 / 烧录的条目
  自带设置、不替用户开跑（扫描）；配音的音量（峰值超过满幅的一句真写成 .m4a 读回来不削波、两种声音只经一处写文件）；什么时候问（会回 `needs_confirmation` 的只有四处：删文件、读别处的文件、Sky Studio 花积分和声音库、改设置；读过的文件夹记住、撞名加编号，扫描）、记住哪里、
  「连接」时写进 Claude Code / Codex 的放行配置、工具清单总长度的上限；第 4 块的镜头切点与翻页、跟拍（窗的两边落在画布两边、
  只跟人、换镜头跳过去）；第 5 块的剪辑风格（配方卡的格式、合并与查找、存一套 / 删一套，**卡里提到的工具名、参数名、选项值都存在**，卡里的字号写明画幅、9:16 的上限用生产的排版真排得下；卡里讲生成素材、花积分的话对着现行合同查，`RecipeContractChecks`（2026-11-13）：generate_media 只写成条件句、清单不按 Key 过滤时条件里不提 Key，共用规矩讲到 `quote_only` / `needs_confirmation` / `confirm_token` / `daily_budget_exceeded`、没有一句把每日预算（含 spending cap / ceiling / quota 这类说法）和确认码写在一起（嵌套的列表项带着父项的话、段落后面的列表带着那一段算句，切法和词表在 `RecipeTextScan.swift`、自带坏话和合规的例子），讲生成素材的句子不写死档位，不提 fal / `cost_usd`；花钱的工具钉在 `recipePaidTools`，说明书 `paid` 主题「Which tools.」那一句和地图「Paid」那一行认出来的都要正好是它，卡里叫 AI 用到的共用规矩里都有一条说它花积分；讲 `add_voiceover` 花积分的那一条讲到建声音那一步（`voice_enroll`、`already_building`、跟着 `next_step`）；`needs_confirmation` 不写成某一个原因、留着「照结果的 question 问」那句总的、「SkyCut 会问」不说满；反向验证见[案例](../bugfixes/2026-11-13-recipe-rules-teach-budget-bypass.md)和它的「后续」「后续二」）、
  set_text 补的零件（字距、动画时长、强调、数字滚动）和实心形状、add_voiceover（挑声音、语速表、标记 → 词、配音的字幕不覆盖已有的）、
  字幕的 style（只改工程自己的样式、给了位置收掉拖框的布局、逐词高亮的开关和倍数、烧录用不了的字体报错、烧录一批自带的样式）、
  扫画面里的字（字幕带、固定的字、满屏的字互不混，字幕带的框不被贴在字幕上面的幻灯片标题拉大、被画面底边切掉的字不算字幕行、字幕稀疏而幻灯片字多时仍选字幕，没人字多按字对准）；**合成音效**（16 个预设的结构自检：峰值 / 响度 / 落点 / 末尾 / 确定性 / 同参数同文件名 / 频谱走向、`sound_effect` 条目怎么读、落点怎么算开头、词表对账；扫描：写文件只经 `AIAudioFileWriter`、渲染在 `MediaReadQueue.analysis` 上）：
  `scripts/check-mcp.sh`；**录屏**（参数怎么读、窗口 / 屏幕 / 麦克风怎么挑、区域的比例换成点、词表和 `RegionAspectRatio` 对账，`ScreenRecordingToolChecks`）也在这里；**几个工程、几个会话**（小程序记一组工程、真起小程序验子代理各带各的 `project`、每个工具碰不碰 / 收不收 `project`，`ProjectBindingChecks`；落在哪 / 归谁 / 什么时候拒、5 分钟放手、到顶列出能关的，`ProjectTargetingChecks`）也在这里；**App 卡住的时候**（什么时候放弃、怎么说、放弃了的不做，真起小程序接卡死 / 忙的假 App，`HangChecks`）也在这里；**画面多大**（导出报成片的宽高帧率、look 报文件本身的尺寸，`VideoSizeChecks`）也在这里；**导出字幕文件**（写哪几条轨、`<名字>.<语言>.srt`、撞名整组加编号从不覆盖，`SubtitleFileChecks`）也在这里；**一次查完 V1 的剪辑点**（listen cuts=true：每一段的头尾都是剪辑点、挨着的合成一个、跨转场带 transition、开着缝的各报各的，在它声音的源时间轴上判、建议换回这一段自己的源时间，`CutCheckChecks`；**判的输入和 cut_speech 同一份**（`AISpeechHearing`：整个文件的电平、门限、词），L16 原片真量的电平上两边判得一样、建议就是 cut_speech 的落点，`SpeechHearingChecks`）也在这里；**参数名按说明核对**（说明上没有的名字整个调用不做、里层也查、每个工具说明上的全部名字都过，`ArgumentCheckChecks`；核对在路由排队之前，`checks/MCP/router-wiring.sh`）也在这里。
- AI 录屏的接线（扫描守卫）：AI 起的录制不开系统选择窗口、设置页 / 残缺框只给手动的会话、不覆盖、不写手动的偏好、入轨包 `AIUndoGrouping.step`、
  录制中不把 SrtFlow 摆到前面、丢弃先问且进废纸篓、授权一次运行只请求一次、浮窗在左下角、录制中换工程 / 改帧率先挡：`checks/screen-recording-ai-wiring.sh`。
- Sky Studio 账号与照授权拦（收费方案第 5 刀）：`scripts/check-sky-studio.sh`（`check-all` 第 2 组，不碰网络、不碰钥匙串）：Key 的整理与钥匙串那一条的名字、机器号钉死一组值（盐改了就红）、`/me` 照合同里的样例读（带毫秒的日期、读得宽、少了必须的不算回答）、假 URLSession 上的请求（地址、四个头）和三种失败、环境变量只能指到本机、此刻的授权（没有 Key / 没问到过 / 过期按免费版、钟差、往回拨）与什么时候再问、照授权拦（`GateChecks`：默认打开、测试开关关不掉它、每个工具 × 每种授权让不让且 `get_status` 永远让、水印听服务器的、被挡住时的话、`skycut_plan`）；接线（地址只在 `SkyStudioAPI`、硬件 UUID 只在 `SkyStudioMachine`、后台不弹钥匙串框、设置和启动接上了、AI 的门在核对参数名之后建调用之前、导出面板挂着「会带水印」那一行、`export_video` 和 `get_status` 说授权、交任务和取消只经 `SkyStudioJobRun`、认证头只在 `SkyStudioAPI.request()` 写一次）：`checks/sky-studio-wiring.sh`（扫描守卫）。同一个脚本还管**第 6 刀的任务**（`JobChecks` / `JobRunChecks`：`/models`、`/quote`、`/jobs` 发什么读什么、取消的两种结果、`/uploads` 之后 PUT 只带服务器给的头不带 Key、下载成品；`SkyStudioJobRun` 满了等着用同一个 idempotency_key 再交、照 `poll_after_seconds` 问、断网几次不算、停的时候排队中退钱 / 开始了取消不了且接着查到底）和 **generate_media 送 Sky Studio 的那一份**（`GenerationChecks`：种类的词表和 `SkyStudioGeneration` 对账、每种的默认值（目录没给取值时的兜底）、用不上的参数说一句不送、请求体、问句和状态行上的记号、离谁最近的画幅、成品的扩展名）；接线第 9 条钉着生成的把关在建任务之前、Key 不弹框、状态行和 get_job 的阶段与 `skystudio_job_id`。
- 云端媒体：`scripts/check-sky-studio.sh` 验证现行接口 / 任务 / 报价 / 积分 / 配音，`VoiceSlotChecks` 验按池领槽（两个池对上服务器的名单、先来先得、对着假服务器数同时开着的单、429 看 `pool`）；`scripts/check-cloud-media.sh` 验证共用每日账与阶段；`checks/no-legacy-generation.sh` 禁止旧 fal 客户端 / Key / 设置 / 模型和网络路径回来。
  `scripts/check-voice-recovery.sh`（第 1 组）链接真实 App 对象：回任务号之前整段报价一次、每批同一个 `params.plan`、额度 / 服务器拒都在花钱之前停、服务器不答退本机（`StartChecks.swift`）；字幕时间（`TimingChecks.swift`，声音 PR 5：普通旁白合批、字幕是稿子的字、转写不了的预设整段 eleven-v4 / 别的按字数估、转写模型在第一批之前装、装不上再报价）；几批同时交、后交的先回仍照原来的顺序落地、中途换备用之后的批带备用的选择、`fallback_needs_one_time` 之后只补没做成的（`ConcurrencyChecks.swift`，声音 PR 4）；第二批云端成功而本地失败后只恢复已有音频、只补第三批（照记录的选择再报价）、字幕 / 片段不重复、原子入轨撤销与未知单不重放；付过钱的声音不卡死（`PaidAudioChecks.swift`，2026-11-10 审查：繁体稿合批而转写写成简体、长句两片 24 kHz / 44.1 kHz、转写不了的 Mac 上 eleven-v4 的 `words` 用不了按字数估句界、`get_job` 运行中和失败后带 `voice.note`），纯值的一半在 `scripts/check-sky-studio.sh` 的 `VoiceSplitChecks`。
  `scripts/check-sky-studio.sh` 的 `VoicePickChecks` 对着目录快照认声音（默认 gemini:Charon、角色只认 voice_roles、英式男声、本机退档按性别）。
  声音库（声音 PR 6）和全部权限下的长期授权（声音 PR 7）：`scripts/check-sky-studio.sh` 的 `VoiceLibraryToolChecks`（列出来的、令牌绑的身份、`SkyStudioJobGate` 的授权 / 一次性费用 / 删除在 `.ask` / `.standing` / `.once` 下、错误的话）、`VoiceStandingNoticeChecks`（打开全部权限时那段说明：价目照目录快照、授权那句和 Sky Studio 的一字不差）、
  `scripts/check-voice-recovery.sh` 的 `LibraryChecks`（真 App 对象：建声音先问授权、删除按模式、设计、用声音库的声音配旁白的一次性费用、声音库用不了不退本机）与 `FallbackFeeChecks`（旁白中途备用要先建 MiniMax 版：get_job 问价、普通 resume 留着这一笔、`skip_one_time` 照原来的模型重试、令牌按报价记账起 `voice_enroll` 再 `generate_missing` 读完）与 `StandingChecks`（全部权限 + 长期授权什么都不问、没有就问一次并补记、Sky Studio 拒了再问、set_settings 记 / 撤、升级补记）、
  `checks/sky-studio-wiring/voice-library.sh`（`checks/sky-studio-wiring.sh` 第 11 节 source 进来：`consent: true` / `standing_grant` 只在放行之后造、长期授权只经 `SkyStudioVoiceStanding`、改模式的地方都告诉它、`/voices` 路径只在一处、没有服务商 id 的样子）。
  `scripts/check-mcp.sh` 的 `ProviderChecks` / `SkyStudioVoiceChecks` 验证清单、旧标记兼容、参数名、本机选声、词时间（克隆参考录音的 WAV 见下一条）；`SkyStudioVoiceChecks` 还查 add_voiceover 的名片必含 / 说明书必含，名片上限、固定说法、参数说明和主题的分节和试点的五个一起在 `GuidePilotChecks`，会问就收 `confirm_token` 在 `ArgumentCheckChecks`；`scripts/check-keychain.sh` 是本机真实钥匙串回归，不在 CI 里。
  免费端到端在 `scripts/gui-smoke/sky-studio/`，见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)四之八；共享客户端在 `scripts/gui-smoke/mcpclient.py`，断线 / 坏协议必须显式失败。
- 声音库的收费单只下一次、账只记一次（2026-11-11 审查之后）：`scripts/check-voice-recovery.sh` 的 `LibraryOrderChecks`（真 App 对象 + 会排队 / 去重 / 改价 / 退款、
  实扣不等于上限的假 Sky Studio：设计连按只下一单、同一份再起回开着的那一单、账按实收、`price_changed` 带新价和下一步、MiniMax 版在建时再调跟着那一单、
  授权那句升版本用新文案再问、临时文件夹只清一天以前的、`QueuedAudioWindow` 出 16 kHz 且能取消）、`FallbackFeeChecks.repricedChecks`（建的那一单没受理：问题还在、
  记下新价）、`LibraryUIChecks.outdatedStatementChecks`、`PaidAudioChecks.neverMatchesChecks`（每次都切不开的批第二次按字数估）、
  `LibraryRestartChecks`（跨一次重启：旧进程的任务停在下一次问之前、新进程只看盘上的；建 MiniMax 版在建时重启再调不问不记、跟着那一单，
  两单设计重启后读到 Key 就接着跟、按实收 / 退回，交的回答丢了再点头时并成一笔，实收落在预留那一天）；
  `checks/sky-studio-wiring.sh` 第 13 节（拆在 `checks/sky-studio-wiring/voice-library-orders.sh`）。规矩见 [声音库](../architecture/voice-library.md)第十节。
  这项检查每次运行用自己的 bundle id（`…voicerecoverycheck.run<pid>`），几个会话同时跑不共用 UserDefaults。
- 声音库的界面（声音 PR 8）：`scripts/check-sky-studio.sh` 的 `VoiceLibraryUIChecks`（纯值：选择器三组的顺序和预设名单、按这一排的语言取性别 / 样音、说明按界面语言挑、「新建」为什么还灰着、服务器的错误是哪一种）、
  `scripts/check-voice-recovery.sh` 的 `LibraryUIChecks`（真 App 对象 + 假 Sky Studio：Store 的几种样子 / 改名 / 删除再发一次 / 临时链接 / 「声音库变了」，新建声音没勾授权什么都不传、勾了和 `manage_voices` 同一个 key、人声不够当场说、语言预选，设计先问价、按下去过每日硬预算、改字报价作废，录音机，界面上的话）、
  `checks/sky-studio-wiring.sh` 第 12 节（拆在 `checks/sky-studio-wiring/voice-library-ui.sh`：`consent: true` 在对话框里只许勾过之后造、建 / 加 / 删只从一个文件发、设计先过额度再起任务、界面不用确认码、视图不读工程）、
  `checks/project-file-wiring.sh`（语言检测的候选和裁决钉在 `SpokenLanguageProbe`）；出图 `scripts/render-voice-library.sh <输出目录>`（三种界面语言各一套 PNG，**要图形会话、不在 `check-all.sh` 里**，见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)第五节）。规矩见 [声音库](../architecture/voice-library.md)第九节。
- 变声（声音 PR 9）：`scripts/check-voice-recovery.sh` 的 `VoiceChangeChecks`（真 App 对象 + 假 Sky Studio `VoiceChangeHTTP`：落地的规则、先报价后上传的单声道 WAV、一次 `voice_convert`、`target_language` 什么时候带、收费之前停下来的几种、一步撤销 / 重做、这一段没了 / 工程换了只留文件、没做成退回、结果不明不重交、面板背后的那一份）、`scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks`（名片、说明书、地图）、`checks/sky-studio-wiring.sh` 第 14 节（拆在 `checks/sky-studio-wiring/voice-change.sh`：两个入口同一条路、先过预算再起任务、不用确认码、落地一次 perform、块只写目标、面板不读工程）、`checks/MCP/router-wiring.sh`（落地那一下包在 `AIUndoGrouping.step` 里）；免费冒烟 `scripts/gui-smoke/sky-studio/voice_change.py`、出图 `scripts/render-voice-library.sh` 的第 9、10 张（**都要图形会话或起测试 App、不在 `check-all.sh` 里**）。规矩见 [声音库](../architecture/voice-library.md)第十一节。
- `manage_voices` 的 `language` 可选（2026-11-11）：`scripts/check-voice-recovery.sh` 的 `LibraryLanguageChecks`（真 App 对象，识别换成假的：不给时识别一次、问句和结果写识别成了什么、照原样带令牌再调建成；识别不出来回 `language_undetected` 和「带上 language 再调」、什么都不传；给了照给的、识别一次都不叫；`add_reference` 同一条路）、
  `scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks`（只有 `action` 必给、参数说明和 `create` 一节照可选写、有一个例子不带 `language`）、
  `checks/sky-studio-wiring/voice-library-ui.sh` 末尾一段（识别只有 `SpokenLanguageProbe` ← `VoiceSampleLanguage` 一份、只许对话框和 `manage_voices` 用；工具里不许再当必填、识别在做参考录音之后问授权之前）。规矩见 [声音库](../architecture/voice-library.md)第八节第 3 条。
- 克隆的参考录音：`scripts/check-mcp.sh` 的 `VoiceReferenceChecks`（挑段的纯值规则、门限 0.0056 的合同、坏采样记 0，和照规矩直写的穷举对账）与 `VoiceReferenceFileChecks`（现写 44.1 kHz / 48 kHz 立体声 / AAC / 32 位浮点素材真走 `VoiceReferenceSample.prepare`，把写出来的 WAV 按字节读回来；含贴着门限的样本、浮点刚过门限而量化后不够的样本、带 NaN / ±Inf 的样本），扫描守卫 `checks/MCP/voice-reference-wiring.sh`（门限单独写死、不借 `AIVoiceLevel`）。真 App 对象上的那几条（克隆只传一次、人声不够在报价之前拒）随 `clone_from` 在声音 PR 3 删了，建声音的真 App 检查跟声音 PR 6 加。规矩见 [声音库](../architecture/voice-library.md)。
- 视频 upscale：`scripts/check-upscale.sh`（`check-all` 第 2 组，要 ffmpeg 造带声音的素材，不碰网络）：范围（三选一、余料、对齐、夹住、一次最长 30 秒放不下先少留余料）、
  Sky Studio 的档位（`/models` 读成 `UpscaleTier`、能升到哪几档、上限、送不送得了）、起名落盘、封回原声的参数、真裁一段、流水线对着假 Sky Studio 走全程（裁 → 探 → `/uploads` + PUT →
  `/jobs` → 等 → 下载 → 封声 → 落盘记实收的积分；整个 mp4 直接上传、排队中停下替它取消、被拒没有文件）；接线在 `checks/sky-studio-wiring.sh` 第 8 条。
- 时间线复制 / 剪切 / 粘贴：拿什么、换新身份（除了 id 每个字段照抄）、粘到哪（撞上往上抬、几组保住上下关系、
  声音各找一条、链接组换新号、文字 / 滤镜 / 字幕句各自的行规矩），外加分割不丢字段、分割后链接组一对还是一对：
  `scripts/check-timeline-clipboard.sh`；接线（编辑菜单三项、右键菜单、落点鼠标优先含 Finder 文件、标尺不算轨道、
  剪贴板只有一套且不写纯文本）：`checks/timeline-clipboard-wiring.sh`。
- 静帧真实编码，图只解一次、缩一次（数 ffmpeg 报的解码次数；多出来那 119 帧的耗时和同一次运行里产物尺寸的小图比、上限 2.5 倍或多 0.25 秒，规则自检钉着 CI 慢 runner 的数、1.2 倍抖动不红、6 倍退化红），以及透明的图（哪张算用到了透明、预乘的 ProRes 4444 + 灰度遮罩的真产物、按图挑缓存名、老缓存不再认）：`scripts/check-still-clip-encode.sh`。
- 翻译配对预检与接线：`scripts/check-translation-preflight.sh`。
- 音频库清单：解析的宽容边界（不认识的字段忍、单条坏数据跳过、**版本号更高整份
  拒绝**）与双语搜索（中英都能命中同一个 tag、多词是「与」），以及音效清单的 `title_zh` / `hit` / `owned` 不署名 / 按中文标题搜：
  `scripts/check-audio-library.sh`。
- 音效目录（`scripts/audio-library/sfx-catalog.tsv`：id 连号永不改、来源唯一、中英标题、tag 都在词表里、来源方）：
  `checks/sfx-catalog.sh`。
- 压缩 / 烧录记住的设置和字幕样式在队列创建时读回来（不挂在页面的 `onAppear` 上），剪辑页和 AI 的字幕样式都经
  `subtitleStyle(appWide:)`（工程自己的样式优先）：`checks/encode-settings-memory.sh`。
- 构建日志不得被吞：`checks/no-swallowed-build-output.sh`。
- CI 的 `.build` 缓存：key 和 restore-keys 带检出目录（`github.workspace`，仓库改名 / 换目录后不捡旧目录编的缓存）、工具链指纹、组号和提交，
  取 / 存分开且同一个 key、只在 main 上绿了才存、编译之前修改时间按内容设（`scripts/ci-stable-mtimes.py`）：`checks/ci-build-cache-key.sh`；
  按内容设的时间比上次编译早时照样重编（不拿旧目标文件测新代码）、新 checkout 放回 `.build` 重编 0 样，在小包上真走一遍：`scripts/check-ci-build-cache.sh`。
- CI 的「只改了文档」快速通道（`scripts/ci-docs-only.sh` 判：只有 `docs/` 和根目录三份说明才算，改名算删旧加新；是就只跑扫描守卫）
  只在真的只改了文档时走、每一步重活都看判断的结论、触发条件里不许有 paths（必需的 check-all 会永远等不到结论）：`checks/ci-docs-only.sh`。
- `checks/` 顶层的每一条扫描守卫都在 `scripts/check-all.sh` 里（CI 只跑 check-all 列着的；check-guards 按通配符跑，漏进 check-all 的本地照样绿），
  以及第 1 组正好是「完整 App」那一摊（App 编得过 + 链接完整 App 目标文件的检查，这种检查也只许在第 1 组）：`checks/check-all-shards.sh`。
- 「连接」AI 客户端时第一次改配置前存的备份，一建出来就和原文件同样的权限（只有 `AIClientConfigWrite` 写 `.skycut-backup`、`AIClientSetup` 经过它）：
  `checks/client-config-backup.sh`；行为（600 的备份还是 600、照原文件不一律 600、链接按目标算、再改不动备份）在 `scripts/check-mcp.sh` 的 `ConfigBackupChecks`。
- DMG 安装引导的接线 / 模板：`checks/dmg-packaging.sh`；真实组装、挂载和 Retina 背景：`scripts/check-dmg.sh`。
- 发布版用固定的签名身份签（打包脚本只经 `scripts/signing/sign-app.sh`、它有身份就用并核对钉着的证书、ad-hoc 只在没有身份那一支、
  `packaging/signing-identity.sha1` 钉着正好一把），录自定义区域请求授权之前先删钉着旧签名的记录、`tccutil` 只在一处、文案不再叫人
  「关掉再打开」：`checks/release-signing.sh`。建签名身份 `scripts/signing/create-identity.sh` 是一次性的、**不在 `check-all.sh` 里**。
- 产品名与代码名（看得见的叫 SkyCut；bundle id、UTType、数据文件夹、钥匙串、AI 通道这些身份沿用 SrtFlow，改了就丢用户的授权、设置和数据）：
  `checks/product-name.sh`。
- 工程不再是单例（全仓没有 `VideoEditProject.shared`、工程只由 `OpenProjects` 建、撤销不退到键窗口、工程代号全 App 一个计数、
  退出问每个工程、录屏落回开录的工程）：`checks/open-projects-wiring.sh`。
- 代码文件的行数上限（超过 600 行就红，老文件只许降不许涨，变短了用 `--update` 改小基线）：
  `checks/source-file-size.sh`。
- shell 脚本里裸 `$VAR` 不许紧跟中文 / 全角标点（bash 会把首字节吃进变量名，
  `set -u` 下当场退出）：`checks/shell-var-boundary.sh`。
- 开着 pipefail 的 shell 脚本里，管道末端不许用 `grep -q`（命中就退出，上游吃 SIGPIPE，
  整条管道判失败 → 时灵时不灵的假红；查变量用 `<<<`，查管道用 `grep -c … >/dev/null`）：
  `checks/shell-pipe-grep-q.sh`。
- `"$(…)"` 里不许再套带 `{…,…}` 的双引号字符串（CI 的 /bin/bash 3.2 会把它花括号展开、拆成几个词；放在 `[ ]` 里就是 too many arguments、
  `if` 走 else，守卫永远不红 —— 先赋给变量再比较）：`checks/shell-brace-in-nested-quotes.sh`。
- 每个 sheet / popover 的内容、每个自建的 `NSHostingView` 都必须套 `.appLanguage()`（SwiftUI
  不把应用内语言带进 sheet / popover）：`checks/presented-views-app-language.sh`。
- 代码里每个 `UTType(exportedAs:)` 都必须在 `packaging/Info.plist` 里声明（没声明的
  类型系统认不出，拖放会被静默拒绝）：`checks/exported-types-declared.sh`。
- 预览性能 ratchet（起真 App 按固定场景数「做了多少件活」，只许降不许涨）：
  `scripts/check-preview-perf.sh`。**CI 独有**：第 1 组里单独一步，要图形会话，**不在
  `check-all.sh` 里**；check-all 只跑它的比对规则自检（`--self-test`）。偶尔会误报退步
  （CI 虚拟机上的已知干扰），认法和处理见架构文档「已知的偶发误报」。每个视图、
  `updateNSView`、Canvas 都接了计数：`checks/preview-perf-wiring.sh`；新写视图漏了计数，
  跑 `checks/preview-perf-wiring.sh --fix` 自动补上。同一个守卫还钉着**时间线上的块不许
  读工程的属性、必须 `Equatable` 且构造处套 `.equatable()`**，以及**订阅播放器时钟的只许是名单里跟着播放头动的
  小视图**（根视图、时间线本体、检查器、素材库、字幕列表都持有不订阅）。
- AI 起的导出 / 转写 / 翻译排队（四个入口都经 `AIWorkQueue`、不再回「已经在做」、取消先从队里拿、`get_job` 报 `queued` / `queue_position`）：
  `checks/ai-work-queue-wiring.sh`（扫描守卫）。
- AI 在干活时不让 App Nap 降速、领和还成对（活动断言只在 `AIKeepAwake` 和录屏开关、路由领了紧跟 `defer` 还、任务 `start` 领 `finish` 还）：`checks/ai-keep-awake.sh`（扫描守卫）；计数、重复还、兜底还、真走一次工具调用和任务都还回来在 `scripts/check-voice-recovery.sh` 的 `KeepAwakeChecks`。
- 全部扫描守卫一条命令：`scripts/check-guards.sh`（跑 `checks/*.sh` 每一条，再加 `scripts/check-mcp.sh --scans-only` —— check-mcp 编译之前那一段扫描、连同它 source 进来的 `checks/MCP/*-wiring.sh`，以前只在 CI 上跑得到；推之前必跑；`check-all.sh` 照样逐条跑它们，`checks/check-all-shards.sh` 钉着两边对得上）。
- 本地推之前那一步：`scripts/check-local.sh <相关的检查>`（扫描守卫 + 点名的几项；完整的一遍交给 CI）。本地跑检查的三个入口
  （check-local / check-guards / check-all）在 Rosetta 下会换成原生 arm64 的 `/bin/bash` 重跑自己（`scripts/native-arch.sh`）、
  起检查用 `/bin/bash` 不用 PATH 上的 bash：`checks/native-local-checks.sh`（装了 Rosetta 就真起一个 x86_64 的探针看它换没换成原生）。
- AGENTS.md 和 Bug 案例索引（`docs/bugfixes/INDEX.md`）必须是全的、每条一行、只有规定的几种写法，AGENTS.md 整份不许再长回去 —— `checks/docs-index-drift.sh`
  （主文件只串起来；名单和数字、逐行认写法、链接对着磁盘、每个代号的那句话、自测和场景分在 `checks/docs-index-drift/` 下，都不单独跑）：
  - **白名单**（2026-11-13 起）：两份索引里只许出现规定的几种写法，别的一律红、并说出是哪一行；每条报错开头带一个「[代号]」。
    整份文件：链接只有 `[字](相对路径.md)`（可带 `#锚点`）一种，方括号只许用在这种链接里，行内代码只许一对反引号、不跨行；
    代码围栏、行内代码以外的 `<` / 反斜杠 / `$` / HTML 实体、控制字符、看不见的字符、开头的 front matter、不接在列表项后面的缩进行都红；
    不设单条上限的小节里，列表项不许以链接开头（索引条目挪进去就不受每条的上限了）。
    许写什么、不许写什么、为什么，见 [文档索引怎么写](../architecture/doc-indexes.md)第六节。
  - `docs/bugfixes/` 下每一份（`INDEX.md` 自己除外）都要在 `docs/bugfixes/INDEX.md` 里**当条目**列着；`docs/` 下其余每一份、连同 `docs/bugfixes/INDEX.md`，
    都要能从 AGENTS.md 的链接找到。只读 AGENTS.md 的代理打不开索引外的文档，所以漏一行等于那份文档不存在。漏索引、死链、算上限用同一份清单：
    `docs/` 下名字只有字母、数字、`.` `_` `-` 的普通 `.md` 文件（叫 `xxx.md` 的文件夹不算文档；符号链接、`.MD`、名字带空格或括号的红）；
    `docs/bugfixes/` 下只放 `YYYY-MM-DD-<slug>.md`、`TEMPLATE.md`、`INDEX.md`。
  - 两份都没有死链（大小写也要一字不差）；`INDEX.md` 里的链接按它所在的文件夹解析（同文件夹写 `xxx.md`，别的文件夹写 `../architecture/xxx.md`）。
    AGENTS.md 的「Bug 修复案例索引」一节只留指路的话（每行 ≤ 400 字节、≤ 5 行，只许普通的一行或 `- ` 开头的一行）；这一节和 AGENTS.md 的索引小节里，
    任何指向 `docs/bugfixes/` 下案例的链接都红（`INDEX.md`、`TEMPLATE.md` 除外），不管前面是什么记号（开工早的会话还会照旧规矩往那里补一行）。
  - 索引小节（AGENTS.md 的规划与实施报告索引、架构与长期约束索引、根目录文档 —— 这三节的标题也在守卫的名单里，以后新加的「## 」小节也算；
    整份 `docs/bugfixes/INDEX.md`）里，一条索引只有一种写法：顶格的 `- [标题](路径.md) — 一句话`，一条正好一个链接；AGENTS.md 的索引小节另许成形的表格
    （表头 + 紧跟的分隔行、列数一样，每行正好一个链接），`INDEX.md` 是纯列表。别的列表记号（`+`、`*`、`1.`）、缩进的行、`>` 引用、分隔线、
    不成表格的竖线行、接在条目或表格后面的行都红；同一份文档在 AGENTS.md 的索引小节里只当一次条目。
    这些小节里每一行（列表行、表格行、开头的说明、小标题）不超过 400 字节（链接 + 一句话），条目以外的行（说明、小标题、表头）每节最多 5 行。
    唯一入口约定、开始任务前、全局规则、文档目录职责、按修改范围选必读文档、构建与检查入口是守卫名单里不设单条上限的小节：必读表和检查入口
    **有意只受整份上限**（一行要带检索线索和几份链接，设每行上限只会逼人删检索词）；改了这些小节的标题要同步改守卫的名单，不然守卫先说找不到它。
    写法和收成一句话时不能丢的东西见 [文档索引怎么写](../architecture/doc-indexes.md)。
  - AGENTS.md 整份不超过 71,000 + 250 × `docs/bugfixes/` 以外的文档数 字节（只数普通文件：叫 `xxx.md` 的文件夹、符号链接不算）。
    2026-11-13 之前每条索引都带一大段摘要，AGENTS.md 有 339 KB，每个会话一开就读约 14.7 万 token；那天收成每条一行（400 份文档、153 KB）。
    同一天又把 Bug 案例的索引搬去 `docs/bugfixes/INDEX.md`（AGENTS.md 100 KB），案例不再往 AGENTS.md 里加一行，所以文档数只数 `docs/bugfixes/` 以外的；
    基数里留了约 5 KB 余量，给新案例在必读表里加的链接（怎么算的写在 `checks/docs-index-drift/config.sh` 的注释里）。
    超了不抬上限，只有两种收法：把摘要挪进它指向的文档（或这份细目）；或者撤掉必读表里的旧案例链接，但**只许撤这一种** ——
    同一行链着的架构文档已经写了那条规矩，并且那份架构文档里链着这份案例，案例本身照旧留在 `docs/bugfixes/INDEX.md`（用户 2026-11-13 定）。
    反向验证（2026-11-13）：往必读表里加 6 KB 的一行 → 红（整份超上限）；
    给一条索引接上一段摘要 → 红（那一行超 400 字节）；恢复后绿。
    搬出 Bug 案例索引那次（2026-11-13，`/bin/bash` 跑）逐道又验了一遍，每道都红、报的是对的那一句：从 `INDEX.md` 删一条；往 `INDEX.md` 加一条死链；
    `INDEX.md` 里照老写法写 `docs/bugfixes/xxx.md`；去掉 AGENTS.md 里指向 `INDEX.md` 的两处链接；`INDEX.md` 一条 401 字节（正好 400 是绿的）；
    AGENTS.md 比上限多 1 字节（正好等于上限是绿的）；新加一份架构文档不进 AGENTS.md（只列进 `INDEX.md` 也不算）；
    AGENTS.md 那一节加回一条案例；`INDEX.md` 整份删掉。恢复后绿，文件和改坏之前逐字节相同。
    复审之后改成按小节逐行认条目那次（2026-11-13，`/bin/bash` 跑，[案例](../bugfixes/2026-11-13-index-entry-limit-bypassed.md)）：36 个探针各跑一遍改之前和改之后的守卫，
    复审里原来是绿的四种绕法（`+ [` 列表、缩进的 `- [`、短索引加缩进续段、表格行加长）在 AGENTS.md 的列表索引小节和 `INDEX.md` 里都红了（每行都不到 400 字节的版本也红），
    表格行加长在规划与报告索引里红、在必读表里照旧绿（只受整份上限）；400 / 401 字节、整份上限的边界照旧；`* [`、`1. [`、不缩进的续行、夹在中间的一段话、
    紧跟列表条目的表格行、说明超过 5 行、Bug 一节的 `+ [` 条目、改了名单里的标题都红。恢复后绿，两份文件和改坏之前逐字节相同。
  - `docs/bugfixes/INDEX.md` 整份按文件名里日期后面那一段的字母序排（不看日期；`LC_ALL=C` 的字节序，从小到大；这一段相同的再按日期；模板那一行留在最上面），
    一份案例只列一次；条目的链接只写同文件夹的文件名、文字以文件名里的日期开头，说明里不许链案例。放错了说出是哪一条、该排在谁上面；
    同一种问题最多列 5 处、再说一共还有几处。为什么这么排、重放的数字见 [文档索引怎么写](../architecture/doc-indexes.md)第五节。
    上一版（同一天上午，PR #413）是按文件名从大到小排，当时的反向验证：新案例加在模板下面、同一天的两条对调、整份恢复成排序之前的老顺序、
    同一份案例列两次 → 改之前绿、改之后红。
    这一版的反向验证（2026-11-13，`/bin/bash` 跑，在 AGENTS.md + `docs/` 的整份副本上）：新案例照老习惯加在模板下面、照上一版的规矩插（文件名从大到小）、
    两条对调、整份换回上一版的顺序 → 红，报出该排在谁上面；按新规矩插好 → 绿；同一份紧挨着又列一次（改过一句话）、在末尾又列一次 → 红，报出先列的是第几行。
    上一版的守卫在新顺序的副本上全红、在换回老顺序的那一份上绿（它查的是老顺序）。`git merge-file` 模拟两个 PR 各加一条同一天的案例：
    都加在模板下面 → 撞；照上一版的规矩（新的一天的头两条）→ 撞；照这一版 → 不撞，合出来的文件顺序还是对的；只有两条的那一段正好紧挨着时还撞。
  - **自测**：`checks/docs-index-drift.sh --self-test` 在一份最小副本上跑 190 个场景（2026-11-13 的数），每个场景改一处、跑一遍守卫，
    该红的要红在对的那个代号上、该绿的要绿；`scripts/check-all.sh` 里跟着守卫跑（约 20 秒，不编译）。场景分三份：链接怎么认
    （`scenarios-links.sh`）、条目和小节的形状（`scenarios-shapes.sh`）、顺序 / 重复 / 磁盘上的文件 / 整份大小（`scenarios-order.sh`）。
    来历：Codex 2026-11-13 实跑出的 4 类（带锚点的死链、引用式链接、`<a href>` 不查；注释和代码围栏里的路径算作有索引；表格里的条目不查顺序和重复、
    `./x.md` 当成另一份；行首一个 `|` 就算表格行；叫 `xxx.md` 的目录被说成没索引），加上写守卫的人当对手试出来的
    （缩进的代码块、反斜杠转义、空的或看不见的链接文字、HTML 实体、`$$` 公式、front matter、列表记号后面空五格、大小写不对的路径、任务框冒充条目…）。
    `--self-test --against <另一份守卫>` 拿老守卫跑同一批场景打表（写「改之前 / 改之后」用）。
    改之前的守卫（上一版）在链接和形状两组的 147 个场景里有 83 个该红的退出 0、2 个该绿的红了（顺序那一组只对新顺序有意义，没拿它跑）；改之后 190 个全对。
    整份副本上 Codex 的 9 个输入（L1–L4、T1–T3、S1–S2）改之前都退出 0、改之后都红；它报的两处误报（唯一的索引带 `#锚点`、`mkdir docs/fake.md`）改之后绿。
