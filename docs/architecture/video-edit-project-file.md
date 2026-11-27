# 剪辑工程文件（.skycut，改名之前是 .srtflowproj）与素材重链接

> 2026-08-03 定稿。**改工程存盘、素材路径、自动保存相关的代码前必读。**
>
> 相关：[still-image-pipeline](../bugfixes/)、`docs/testing/gui-smoke-testing.md`

## 一、为什么不做 App 内的文件夹管理

最初的想法是「Edit Video 默认进一个 Finder 式的项目界面，文件夹里建工程」。
否掉了，理由是：

1. **等于自建第二套 Finder。** 重命名、拖拽移动、多选、删除到废纸篓、搜索、
   排序、右键菜单、撤销都得自己实现，几千行，且永远不如 Finder。
2. **两套心智模型会打架。** App 内的层级如果只是数据库里的记录，用户在 Finder
   里移动或删掉工程文件后库就烂了（DaVinci 项目管理器的经典痛点）；如果它对应
   真实目录，那就是个残废版 Finder。

**定下来的形态**：工程就是一个普通文件，分文件夹/改名/搜索/备份**全部交给
Finder**。App 只负责「快速回到最近那几条」。

- 「最近工程」直接读系统那份列表（`NSDocumentController.recentDocumentURLs`），
  跟 Dock 图标右键看到的是同一份，**不要**自己再存一套。
- 起始页（`VideoEditStartScreen`）只有：拖放提示 + Add Media + Open Project +
  最近工程网格。**不要**往这里加文件夹、标签、重命名之类的库管理功能。

## 二、其余几条产品决策（用户拍板，推翻要先问）

| 决策 | 结论 |
| --- | --- |
| 工程范围 | 只属于 Edit Video。Burn In 是独立的一栏，日后是否并入再说 |
| 窗口形态 | **单窗口栏内切工程**，同时只开一个。刻意不用 `NSDocument`/`DocumentGroup` —— 那套要求一个工程一个窗口，跟「一个主窗口 + 侧边栏切工具」的结构对不上 |
| 保存方式 | **自动保存**：改动后 2 秒防抖写盘，⌘S 只是「立刻 flush」，关窗/切栏目不弹「要保存吗」 |
| 素材归属 | **只存引用，不拷贝**。工程文件几十 KB |
| 未命名工程 | 拖素材进来就能开工，不强制先建工程；`documentURL == nil` 时**不自动落盘**，等第一次 ⌘S / Save As（面板从起点开始：点名的文件夹 → 工程的家 → 「下载」）。**例外**：AI 改了它就马上存进 `<起点>/SkyCut/工程`（[AI 接口](ai-control-mcp.md) 第四节第 10 条） |

## 三、文件格式

工程文件是一份 pretty-printed JSON（UTI `com.srtflow.project`，在
`packaging/Info.plist` 里声明了 `UTExportedTypeDeclarations` +
`CFBundleDocumentTypes`，双击能回到 SkyCut）。**后缀**：新存的用 `.skycut`（2026-10-18 改名 SkyCut），
改名之前的 `.srtflowproj` 照样认、原地存回去不改后缀；Info.plist 里先写 `skycut`（新文件用第一个）再写 `srtflowproj`。
认不认得一个文件是工程只问 `VideoEditProjectFile.isProjectFile`（打开、双击、最近打开、AI 的 open_project 和列文件夹都走它）。
换后缀不换内容、不开新的格式版本（[产品名与代码名](product-name.md)）。

```
{ formatVersion, savedAt, timeline: TimelineState, media: [MediaRecord],
  rowHeights?: TimelineRowHeights }
```

### 宽容解码是硬约束

`TimelineState` / `EditClip` / `EditLane` / `ShapeAnnotation` / `MediaInfo` 的
`Codable` **全部手写**，每个字段走 `decodeIfPresent` + 默认值；四个字符串枚举走
`LenientCodableEnum`，读到不认识的值退回兜底项。

> **加字段时照这个写法加**（给默认值，不要依赖合成的 `Codable`）。Swift 合成的
> 解码器碰到缺失的键会让**整份工程打不开** —— 这是文档格式最典型的坑。
>
> **同时必须把 `latestFormatVersion` +1**（只要旧版会把这个字段静默丢掉）。
> 宽容解码只保证「新版能读旧文件」；「旧版拿到新文件不毁数据」只有版本闸门
> 能拦 —— 旧版拒开，胜过打开后在下一次自动保存时把新字段悄悄删光。
> 见 [2026-08-04-transform-review](../bugfixes/2026-08-04-transform-review.md)。

### 版本史与登记清单

判据本体在 `VideoEditFormatVersion.swift`（`requiresFormatVersionN`），
**加了新的持久字段就在那里补一行**。writer 自 v5 起一律写 latest
（帧率是无条件数据，每个工程都有），按需定版的机制仍在，只是被它覆盖了。

| 版本 | 新增的「旧版会静默丢掉」的字段 | 旧版丢了会怎样 |
| --- | --- | --- |
| v1 | 首版 | — |
| v2 | `placement` + Transform 四件套（rotation/opacity/flip/crop） | 摆放与变换全没 |
| v3 | `animation` 关键帧 | 动画全没 |
| v4 | `subtitleCompanion`（译文轨 / cueMeta / 语言与生成参数） | 译文轨全没 |
| v5 | `frameRate` | 旧版按硬编码 30fps 渲染 —— 同一文件出不同成片 |
| v6 | `subtitleLayout`、`subtitleHidden` | 字幕位置/换行宽度/字号回默认（**导出画面跟着变**）；设了「不烧字幕」的工程会把字幕烧进成片 |
| v7 | `translationHidden` | 烧录跟着眼睛走之后，它决定成片里有没有译文；旧版丢掉它，「只烧中文」会变回默认 |
| v8 | `EditClip.markers`（**按需写入**） | 纯手工输入的标记连同备注文字被抹掉，只能重标一遍 |
| v9 | `EditClip.fadeInDuration` / `fadeOutDuration`（**按需写入**） | 调好的声音渐入渐出被删光，**成片的声音跟着变**（开头结尾从渐变变回硬切）。合同见 [audio-fades](audio-fades.md) |
| v10 | 上层视频轨的**默认摆放语义**（不是某个键）、`EditClip.videoFade*`、`EditLane.colorIndex`（**无条件**） | 这是一次语义换代：`placement == nil` 从「画中画角落小框」改成「等比铺满居中」，而 `overlayFraction`/`overlayAnchor` 已删。旧版打开会把每一段上层轨画回 40% 宽的小窗，**成片当场就不一样**；随手编辑触发自动保存，画面渐变和轨道颜色再一起被抹掉。合同见 [video-tracks](video-tracks.md)、[video-fades](video-fades.md) |
| v11 | `TimelineState.textOverlays`（**按需写入**） | 画面上的文字连同整套样式被静默丢掉 ——旧版不认识这个键，打开就看不见字，随手编辑触发自动保存即永久丢失。空数组不落盘，所以没用过文字的工程不会被抬版本。合同见 [画面文字](text-overlays.md) |
| v12 | `TextOverlay.animation`（**按需写入**） | 调好的入场/出场/强调动画被静默丢掉，文字变成**硬切出现** —— 入场那一下正是标题最显眼的地方，成片当场不一样；随手编辑触发自动保存即永久丢失。没设动画的文字不落这个键。合同见 [画面文字](text-overlays.md) |
| v13 | `TextOverlay.number`（**按需写入**） | 数字元件退回显示 `text` —— 而它的 `text` 是空的，于是画面上**整段消失**；随手编辑触发自动保存即永久丢失。合同见 [画面文字](text-overlays.md) |
| v14 | `TextAnimationKind.focus`、`TextAnimation.focusStartOpacity`（**按需写入**） | **新增的枚举值也算持久数据**：`TextAnimationKind` 宽容解码，旧版遇到 `focus` 会退回 `.none` —— 那一段的入场/出场静默消失，标题最显眼的那一下当场没了；随手编辑触发自动保存即永久丢失。合同见 [画面文字](text-overlays.md) |
| v15 | `EditClip.presetAnimation`（**按需**，只认非 fade 的效果） | 段的入场/出场动画退回硬切或纯淡入，成片当场不一样。合同见 [画面段的入场 / 出场动画](clip-animation.md) |
| v16 | `EditClip.isHidden` —— 单段隐藏（快捷键 V，**按需写入**） | 用户藏起来的镜头**回到成片里**：旧版不认识这个键，打开就照常渲染它，随手编辑触发自动保存即永久抹掉，只能一段段重新找出来再藏一遍。合同见 [段的显隐](clip-visibility.md) |
| v17 | `TimelineState.filters` —— 时间轴上的调色段（**按需写入**） | 整条片子**退回原色**；随手编辑触发自动保存，调好的色永久丢失。没用过滤镜的工程不落这个键。合同见 [滤镜](filters.md) |
| v18 | `EditClip.remoteKey` —— 音频库素材的 manifest id（**按需写入**） | 当下还能播，但键一旦被旧版的自动保存抹掉，等缓存被清、或工程发给别人，那几段音乐就**永久失链**，而且没人知道原来是哪一首。见下文第四节「音频库素材：四层之前先认领」 |
| v19 | `EditClip.volumeCurve`、`EditLane.volume`、`TimelineState.mainVolume` / `masterVolume` —— 音量曲线与三级推子（**按需写入**：没画曲线、推子都在 0 dB 的工程不落这些键） | 三样都**直接决定成片的声音**：曲线整条消失（退回画曲线之前的 `volume`）、推子全回 0 dB，压下去的背景音乐当场盖过人声；随手编辑触发自动保存即永久丢失。合同见 [音量曲线](audio-volume-curve.md)、[推子与电平表](audio-mixer.md) |
| v20 | `EditClip.soundScene` —— 段上的声音场景（喇叭 / 室内 / 室外九种 + 强度和两个旋钮；**按需写入**：没挂场景的段不落这个键；认不出的场景整个不认、当作没有） | **直接决定成片的声音**：只认 v19 的旧版打开后场景整个消失，随手编辑触发自动保存即永久丢失。合同见 [声音场景](sound-scenes.md) |
| v21 | `TextOverlay.row` —— 文字在时间线上哪一行，行序就是画面上的叠放序（**无条件落盘**，有文字就是 v21）；`NumberRoll.delay` —— 数字元件先等几秒再滚（**按需写入**：0 不落键） | **直接决定成片**：只认 v20 的旧版打开后行号消失、重叠的文字按时间重排，谁压谁跟着变；等待消失、数字从段起点就开始滚。随手编辑触发自动保存即永久丢失。老工程没有 `row` 键，载入时按当年的自动排布补（`normalizeTextRows`）。合同见 [画面文字](text-overlays.md)「时间线上的行」「等待」 |
| v22 | `TextOverlay.isHidden` / `ShapeAnnotation.isHidden` / `FilterClip.isHidden` —— 文字、形状、滤镜段单个藏起来（V，**按需写入**：没藏过的不落键） | **直接决定成片里有没有这一个**：只认 v21 的旧版打开后藏起来的文字、形状、调色全部回到画面上，随手编辑触发自动保存即永久抹掉。合同见 [段的显隐](clip-visibility.md) |
| v23 | 字幕拆成两条独立轨：译文句有**自己的 ID 和时间**，从哪句原文翻来记在 `SubtitleCompanion.translationLinks`（键是译文句的 ID）；`translationLayout` —— 译文在画面上自己的位置和大小（**按需写入**：叠在原文下面时不落键）；`SubtitleCompanion.hiddenCueIDs` —— 字幕单句藏起来（V，**按需写入**） | 只认 v22 的旧版把译文当成原文的镜像、按 ID 对原文，新工程里的译文一句都对不上，读盘时当坏数据整条丢掉，随手编辑触发自动保存即永久丢失。**老工程（< v23）打开时拆开**：每句译文换新 ID、来源记成原来那句原文，当年标过「过期」的照样过期（`SubtitleCompanion.splitMirroredTranslation`，载入时按版本号判）。合同见 [字幕轨可见性与布局](subtitle-track-visibility-and-layout.md) |
| v24 | `ShapeAnnotation.isFilled` —— 实心的长方形 / 正方形（电影遮幅、色块底；2026-09-28 MCP 第 5 块补的零件，**按需写入**：描边的不落键） | **直接决定成片**：只认 v23 的旧版不认识这个键，实心的遮幅、色块退回成一圈描边，随手编辑触发自动保存即永久丢失。预览和导出都问同一个 `drawsFilled`（线条永远是线），导出的画法在 `ShapePNGRenderer`（VideoEditShapePNGRenderer.swift） |
| v25 | `projectSubtitleStyle` —— 这个工程自己的字幕样式（AI 改样式只改这一份，方案第 54 条）；`subtitleHighlight` —— 逐词高亮（颜色、放大多少）；`SubtitleCue.words` —— 字幕每个词什么时候说（生成、配音的字幕才有）（三样都**按需写入**） | **直接决定成片**：只认 v24 的旧版不认识这些键，字幕退回全 App 的样式、不再高亮，随手编辑触发自动保存即永久丢失；词的时间丢了之后再打开高亮也亮不起来。用样式都问 `TimelineState.subtitleStyle(appWide:)`，合同见 [字幕轨可见性与布局](subtitle-track-visibility-and-layout.md)「工程自己的样式与逐词高亮」 |
| v26 | `ShapeKind.blur` / `.mosaic`（盖一块，2026-09-29）与 `ShapeAnnotation.coverAmount`（力度；**按需写入**：只有盖一块落键） | **直接决定成片**：只认 v25 的旧版把不认识的种类宽容回落成长方形，该糊的地方变成一圈描边、水印 / 旧字幕重新露出来，随手编辑触发自动保存即永久丢失。合同见 [盖一块](cover-blur-mosaic.md) |
| v27 | `Keyframe.easing` —— 关键帧的缓动（2026-09-30；**按需写入**：linear 不落键） | **直接决定成片**：只认 v26 的旧版不认识这个键，缓入缓出的推镜、位移退回直线，画面的节奏当场不一样；随手编辑触发自动保存即永久丢失。合同见 [关键帧动画](keyframe-animation.md)「缓动」 |
| v28 | `TextOverlay.markers` / `ShapeAnnotation.markers` / `FilterClip.markers` —— 文字、形状、滤镜段上的标记；`TimelineState.rulerMarkers` —— 标尺上的标记（2026-09-30；都**按需写入**：一枚都没有的不落键） | 理由同 v8：成片一帧不变，但这是纯手工输入的标注和备注，只认 v27 的旧版随手编辑触发自动保存就把它们抹掉，丢了只能重标一遍。合同见 [标记](clip-markers.md) |
| v29 | `EditClip.upscale` —— 这段的素材换成了 upscale 出来的文件：原片在哪、新文件的 0 秒对应原片的第几秒、档位、原片的探测信息和库键（2026-10-02；**按需写入**：没换过源的段不落键） | 成片一帧不变（段指着的文件旧版照样播），但只认 v28 的旧版随手编辑触发自动保存就把这条记录抹掉：「换回原片」从此找不到原片、入点差多少也没人知道。合同见下面「四之五」 |
| v30 | 形状的 `circle` / `arc` 两个种类和圆弧的 `arcSweep`（2026-10-03；**按需写入**：只有圆弧写扫过的度数） | 只认 v29 的旧版读到不认识的种类按宽容解码退成长方形，随手编辑触发自动保存就把圆和圆弧存成了长方形 —— 成片里的那一圈变成方框。见 [画面上的形状](shapes.md) |
| v31 | `ShapeAnnotation.animation` —— 形状的入场 / 出场动画（2026-10-03；**按需写入**：没设动画的形状不落键） | 只认 v30 的旧版不认识这个键，读进来当没有，随手编辑触发自动保存就把动画抹掉 —— 成片里的圆环又变回突然出现。见 [画面上的形状](shapes.md) 第三节 |
| v32 | `Keyframe.easing` 的 `snap` / `overshoot` / `spring` 三个值 —— 关键帧的急停、回弹、弹簧（2026-10-05；照旧按需写入：linear 不落键） | 只认 v31 的旧版按宽容解码把这三个值退成 linear，推近和弹进来变成直线；随手编辑触发自动保存即永久丢失。见 [关键帧动画](keyframe-animation.md)「缓动」 |
| v33 | `EditClip.crop` 的有效精确源矩形允许单边超过 45%，并保留低于旧空裁切容差的源像素边界（2026-11-02；沿用原四个键） | 只认 v32 的旧版会夹回 45% 或吞掉微小边界，露出区域外内容，自动保存即改坏。新版保留合法四边原值；读旧工程时将当年被忽略的微小裁切迁移为无裁切，保住旧成片。检查器只改一边不夹坏其它边。见 [预览自由变换](preview-free-transform.md)「MCP 的源矩形取景」 |
| v34 | `TimelineState.production`：公开故事 / 镜头图、世界状态与完成历史、输出 / 原生帧锚点、观察证据及声音 cue（2026-11-04，按需写入） | 旧版会在自动保存时抹掉制作计划与待复查记录；新版缺键默认 nil，故事板本身也算非空工程。只存公开值，不存 pin、凭据、私有配方或来源。见 [官方原创短片](official-film.md) |
| v35 | `TimelineState.deliveryIntentions` and `EditClip.isScreenRecording` (2026-11-17, omitted when empty/false) | Older writers would discard human review reasons and native screen-capture provenance. See [finished video inspection](finished-video-inspection.md). |
| v36 | `EditClip.webMotion`: source page, canonical parameter object, parameter form, complete source duration / local hit, render dimensions / fps, and fingerprint / renderer / OS / WebKit / font provenance (2026-11-17, optional) | Older builds would discard the only source capable of rebuilding a deleted motion cache; they must refuse the project rather than silently turn a recoverable title into missing media. See [Web-motion renderer](web-motion-renderer.md). |
| v37 | `TimelineState.minimumDuration` (2026-11-17, omitted when zero) | Older writers would discard an explicit ending and shorten the film. Missing keys retain the old content-driven length. |
| v38 | `EditClip.voiceBandDB` — a clip's own 300 Hz–3 kHz lowered (2026-11-18, omitted at 0) | Older writers would drop the cut and the clip's sound in the film would change. Missing key = no cut; the reader cleans it (non-finite → 0, clamped to −30…0). See [sound scenes](sound-scenes.md) section 5. |
| v39 | `EditClip.soundRole` — what a clip's sound is, saved (voice / music / effects / ambience / object; 2026-11-19, omitted when nothing is saved) | Older writers would drop the saved roles and the delivery checks would fall back to guessing from where each clip came from; the film itself never changes. Missing key or a value this build doesn't know = nothing saved (inferred). Split halves and separated sound carry it. See [finished-video inspection](finished-video-inspection.md), "Saved sound roles". |
| v40 | `TimelineState.editingStyle` — the editing style the film was cut with (2026-11-19, omitted when nil; `EditingStyleRecord` in SrtFlowCore) | Older writers would drop it and the film would silently move to a Sky Studio style's newest version (the user's decision D8: a film keeps its version). Missing key = no record; a record without id, source or checksum is dropped and the project still opens. See below. |

> 2026-10-16 `BurnInStyle.lineSpacing`（字幕行距，见 [字幕轨可见性与布局](subtitle-track-visibility-and-layout.md)「工程自己的样式」第 3 条）
> 加进了 `projectSubtitleStyle` 的 JSON 里，**没有 +1 版本**：缺键读 1 就是以前的样子（成片不变），老版本读到不认识的键忽略、随手保存
> 会把它抹掉但不改别的 —— 两个方向都宽容，不值一个版本号。

> v7 还带一条**读时迁移**：v6 及更早的工程按 `formatVersion < 7` 判断，
> 载入时把 `translationHidden` 置为 true。那些版本的默认预览/烧录就是
> 「只有原文」，缺键回退 false 会把老工程的成片悄悄变成双语 ——
> **升级不该改变谁已经做好的片子**。这是本仓库第一条按版本号做的读时迁移，
> 加类似字段时先问一句「缺键的默认值会不会改变旧文件的渲染结果」。

> v6 是 2026-08-09 复审补的：两个字段在字幕轨 UX 那批里落了盘却忘了升版本，
> 而当时的自检写的是 `latestFormatVersion == 5` —— 拿常量跟自己比是自反断言，
> 忘了升它照样绿。**版本号这类常量，断言里要写死外部真值。**
> 见 [2026-08-09-pr22-review-followups](../bugfixes/2026-08-09-pr22-review-followups.md)。

### 公开制作计划（v34）

制作状态属于正常 `TimelineState`，共用本工程的撤销和两秒自动保存；没有画面但有故事板时也不能当空工程丢弃。
`FilmProductionState` 在 Core 中保存公开持久值，film / render 以严格适配器生成的 canonical Data 存放。
缺少 production 的旧工程默认 nil；已存内容使用前重新验证图和证据形状，损坏值不能冒充可报价计划。
作者 CAS、旧输出绑定和观察过期规则见 [官方原创短片](official-film.md)。
付款恢复回执不放进工程 / undo，也不因清空计划而删除。v33 的精确裁切语义及 `<33` 迁移保持原界限。

### Delivery review data (v35, 2026-11-17)

`TimelineState.deliveryIntentions` stores intentional finding anchors and one-line reasons, omitted when
empty and decoded as an empty array in older projects. `EditClip.isScreenRecording` records native capture
provenance, omitted when false and decoded as false when missing. These values were introduced in v35,
which prevents older writers from discarding them; current writers use the latest project format. Inspection itself does not save; explicit mark/clear requests use normal
project undo and autosave. Matching and report behavior are in [finished video inspection](finished-video-inspection.md).

### Explicit project ending (v37, 2026-11-17)

`TimelineState.minimumDuration` retains an absolute project ending without a placeholder clip. `TimelineDuration` computes the
content end with the existing rules (all video/audio items, texts and ordinary shapes; covers and grades do not extend it), then
`duration` is the greater of that end and the explicit minimum. New content may extend beyond the minimum. Zero clears it;
missing keys decode as zero and invalid negative/nonfinite values normalize to zero. Zero is omitted when saving.

`set_canvas duration=141` sets the minimum as part of the ordinary undo transaction; all fields validate before any write. A
positive request must cover the current content and at least one project frame. It never trims content. `get_timeline` reports
the active `minimum_duration` beside `duration`, so a retained tail can be identified and cleared. Versions and undo preserve it.
Selected-only exports and isolated prerender timelines start from a new state and exclude the project-wide ending.

The existing preview black-base and export black-segment paths fill the tail to `state.duration`; audio config and the playback
clock receive the same end. An otherwise empty project with a positive ending can export black video. Audio-only routing remains
audio-only, including its existing refusal of entirely muted content. A tiny manually authored ending still creates an export
segment instead of indexing an empty segment list. No user clips or rendering frame-grid rules are changed.

Regression: `scripts/check-project-file.sh` exercises defaults, optional encoding, version protection, round-trip, clearing and
selected-export isolation. `scripts/check-parameter-limits.sh` exercises the actual tool, one undo/redo, atomic rejection,
audio/preview/version data flow, and real preview/export black frames and duration, including black-only output.

- [ ] Before a release, retain a black ending from the editor's AI connection, scrub to the end, export, undo/redo, save and
  reopen. The displayed/project length and the export agree, with no placeholder block on the timeline.

### The editing style a film was cut with (v40, 2026-11-19)

`TimelineState.editingStyle` records the editing style the AI followed (SS-5, FL-15; [AI control](ai-control-mcp.md) item 32): a
Sky Studio style's id, version and text checksum (pinned: reading it again for this film returns exactly that version, matched on id,
version and checksum and never on the text alone, until the user moves it with `version=latest`), or a preset's / the user's own id, source, SkyCut version and checksum (recorded, never pinned).
It is part of the timeline, so it goes with undo, the round's undo and saved versions. It is written only inside an AI change:
`recipes` notes what a session read for a project (`AIEditingStyleStamp.noteRead`), and that session's next `perform` on the project
that changes something puts the record into the same final state (`AIEditingStyleStamp.stamped`), one undo step with the change.
No read-only call, user edit or later asynchronous landing writes it. `get_timeline` reports it as `editing_style`, with
`newer_version` when Sky Studio lists a newer one. Guards: `scripts/check-project-file.sh` group 53 (gate, key only with a record,
round trips, missing key, a broken record dropped), `scripts/check-parameter-limits.sh` `EditingStyleAppChecks` (real edit_clip:
recorded in the same undo step; another session, a user edit or a no-op records nothing), `checks/sky-studio-wiring/styles.sh`.

### Opening a project repairs link groups (2026-11-17)

`VideoEditProjectIO.load` runs `LinkGroupRepair.unlinkStrayPieces` after sorting the main track: in one link group, the pictures of
one file at one speed are pieces of one clip and keep one timing (the same timeline time for the file's 0 s) — the one the group's
sound from that file plays at, else the earliest picture's; a picture off it leaves the group. Why: a freeze tail saved before
2026-11-17 kept its clip's group although it plays the hold's length later, so deleting the tail deleted the clip and its sound
([case](../bugfixes/2026-11-17-old-freeze-tails-stay-linked.md)). Only `linkGroup` changes, never a clip's place or media; a group with
one picture is never touched. No format version: there is no new field, and an older build reads the repaired file as plain clips.
Guard: `scripts/check-project-file.sh` group 49, a literal project file saved before the fix.

### 存盘必须带上一次的定位表

`VideoEditProjectIO.save(_:to:knownRecords:)` 的 `knownRecords` **不是可选的优化，
是正确性要求**。素材此刻不可达时（工程开着的时候被移走、外接盘拔了），
`bookmarkData()` 会失败返回 nil；不拿旧记录兜底就会把**还能定位到它的那份书签
覆盖成 nil**。更糟的是：随便哪个素材自动找回触发一次回存，就会连带抹掉其他仍在
丢失状态的素材的全部线索。

调用方（`VideoEditProject.saveNow`）要把返回的新表存回 `mediaRecords`，形成
读 → 存 → 读的闭环。手动重链接之后还要把表里的**键**从旧路径换成新路径。

### 版本校验

`formatVersion` 比当前大的工程**必须拒绝打开**。硬打开的话，这版不认识的字段会在
下一次自动保存时被静静删掉 —— 等于毁掉用户在新版里做的活。

### 与 `timeline` 平级的那一段：轨道行高（2026-09-22 起）

每条轨自己的行高存在 `rowHeights` 里，**故意不放进 `TimelineState`**：

- 它是装饰状态。进了 `TimelineState` 就会跟着进撤销栈 —— 调完行高按 ⌘Z，
  撤掉的是行高而不是用户上一次真编辑；走 `perform` 还会顺手重建预览，
  拖一下行高画面闪一次。所以它挂在 `VideoEditProject.rowHeights` 上，
  只标脏（2 秒去抖的自动保存），不进 `perform` / `liveApply`。
- 键是**轨道身份**（`EditLane.id`，主轨单开一个 case），不是行号。
  与 `colorIndex` 同一条理由：删掉中间一条轨，下面那条不许继承它的高度。
- **按需写键**：没人调过行高的工程里连 `rowHeights` 这个键都不出现，
  老工程存一轮之后 diff 是空的。
- **不开新的 formatVersion。** 登记清单问的是「旧版拿到它会不会毁数据」：
  旧版丢掉这一段，用户损失的只是几条轨的高度 —— 成片一帧不变，再拖一下就
  回来了，不像 v8 的标记那样是丢了就没有的手工输入。
- 写盘时会把已经删掉的轨裁掉，但**只裁写下去的那一份拷贝**。连内存里的条目
  一起清的话，「删一条轨 → 自动保存 → ⌘Z 把轨撤回来」高度就没了
  （`EditLane.id` 撤回来还是同一个 UUID）。
- 2026-09-26 多了一个键 `uniform`：纵向缩放定的统一高度（视频轨和音频轨一样高，单独调过的作废，
  见 [捏合缩放](timeline-pinch-zoom.md) 第三节）。同一个理由**不开新的 formatVersion**：旧版忽略它，
  丢的只是高度。读盘时夹进 28…200（坏数据不许把轨撑到几千点高）。

产品口径和可调范围见
[视频轨对等化](video-tracks.md)。

### 时间线里的 `mainMagnet`：这个工程的磁吸（2026-10-02 起）

磁吸**跟着工程走**（同剪映每个草稿的 `maintrack_adsorb`），存在 `timeline.mainMagnet` 里 —— 和行高相反，**放进 `TimelineState`**：
它决定 V1 上的东西在哪（拨开那一下就把 V1 排紧），拨它是一步撤销，⌘Z 要连开关带排布一起退回去；AI 的「撤销这一轮」快照里也要有它。

- **按需写键**：磁吸关着不写，老工程存一轮之后 diff 是空的。**缺键 = 关**：2026-10-02 之前的工程都是磁吸关着时剪的居多（磁吸默认关），
  打开工程永远不改工程 —— 不会因为这台机器上次拨开过磁吸，就在第一次编辑时把用户留的缝合上
  （[案例](../bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md)）。
- **打开时不排 V1**：文件里写着开、V1 却有缝（手改过的文件），打开也照原样；之后只有改到 V1 的排布才排（`MainMagnet`）。
- **不开新的 formatVersion**：旧版丢掉这个键，丢的只是这个工程的开关 —— 成片一帧不变，和行高同一个口径。
- 新建工程用上次拨的值（`VideoEditProject.newTimeline()` 读 `EditorToggles.magnet`），见 [剪辑页上记住的开关](editor-remembered-toggles.md)。

### Generated web-motion movies are project caches (v36)

A web-motion clip stores its source in `EditClip.webMotion` (`WebMotionClipRecord`), not in a media bookmark. The page and
canonical JSON parameters are authoritative; the parameter fields describe the inspector form. Declared page `fonts` are
separate from editable font parameters and the preceding render's `provenance.fonts`; replacing a font cannot keep a stale
missing-font dependency. The record retains the full
rendered source duration and local hit even after a trim, split or speed change. Splitting carries the full record to the new
piece; copying uses the existing Codable identity renewal. An explicit `edit_clip file=…` replacement clears the old record:
that user-supplied file becomes ordinary imported media and can never be replaced by recovery of the old page.

`WebMotionProjectFiles` owns project-relative paths and carrying movies. A completed render has a 64-character lowercase SHA-256
fingerprint, used as `SkyCut/Motion/motion-<fingerprint>.mov` beside the project. No page-supplied path is trusted. Saving,
including Save As, copies an existing movie to that location before atomically writing the project JSON; copy failure fails
the save and preserves the old project. A missing cache does not prevent saving its recoverable source. Generated movies
are excluded from `TimelineState.mediaURLs` and the media table, so deleting one cannot become a request to relink media.

Opening prefers the carried file beside the project over an absolute path from the previous Mac. An existing carried render
is used unchanged across OS/font differences; the rendering service reports the differences and a later parameter edit renders
on this Mac. If no carried or original movie exists, `LoadResult.motionsToRegenerate` lists the clip IDs for the project's
generation-checked background recovery. `refreshWebMotionCaches` also supports runtime recovery after a cache is deleted.
The page, parameters and provenance survive a missing movie and subsequent saves. A clip's display name comes from the stored
motion name, not its cache filename.

Internal saved versions use the same writer with `motionCaches: .reference`: they keep the source page and existing movie URL,
without copying videos beside the version file. Normal saves keep the default `.carry` policy. Version comparison normalizes
only generated cache URLs; restore explicitly starts missing-cache recovery even for projects without an editor window.

Checks: `scripts/check-project-file.sh` group 50 exercises source/form/provenance round trips, missing-key defaults, split
identity, save and Save As carrying, moving to another Mac's folder while the old path still exists, missing-cache requests,
exclusion from media bookmarks, fingerprint path safety and failed-copy preservation. `scripts/check-mcp.sh` also checks
explicit file replacement and refusal preserving its source. Actual page rendering and cache regeneration are covered by the
App-side motion checks, not by these synthetic-byte I/O fixtures.

Reverse verification (2026-11-17): the full project-file check passed 1,364 assertions; omitting the split record failed one,
treating generated movies as imported media failed five, disabling carried-file preference failed one, and omitting source
encoding failed ten. Each production change was restored individually, then all 1,364 assertions passed again. SwiftPM's
nested manifest sandbox was rejected by macOS; these same checks ran with the user-authorized scoped command escalation.

- [ ] Before a release: save a project containing a web-motion clip, carry the project and `SkyCut/Motion` to a Mac with
      another OS or a missing font, open it and confirm the original video is used with a warning; change a parameter and
      re-render on that Mac, then undo once.
- [ ] Delete a motion movie while the project is closed and open it again: the stored page restores it without a missing-media
      prompt. Repeat while the editor is open and verify recovery or a visible render failure; exporting must not omit it.
- [ ] Save As to another folder, remove the original folder, and reopen the saved copy: the title is still available.

### Saved versions are project files too (2026-11-17)

The versions SkyCut saves around AI rounds are complete project files written by the same `VideoEditProjectIO.save` (with the
project's `mediaRecords` as `knownRecords`) and read back by the same `load` — no new format and no format version. They live in
`~/Library/Application Support/SrtFlow/Versions/<project name> <hash>/`, not next to the project; going back restores the timeline
with `restoreTimeline` as one undo step. Only `ProjectFileWriter` (a project's own file, off the main thread, §5) and
`ProjectVersionStore` write project files. Rules:
[saved project versions](project-versions.md).

### 不进工程文件的东西

- `EditClip.needsStillConversion` —— 导入过程中的临时状态。
- **图片段生成出来的静帧视频**。图片走 `StillImageClipFactory` 转成静帧循环视频
  后才上时间线，那个 mp4 在 `~/Library/Caches` 里，随时可能被系统清掉。所以
  工程只登记 `stillImageURL`（原图），打开时缓存命中就直接接上，没命中就报进
  `LoadResult.stillsToRegenerate` 由 `regenerateStills` 重转，用户无感。
  **不要把 `sourceURL` 当成图片段的真身。**

  这条链上有三个坑，都踩过：

  1. **重转前必须 `awaitVideoEngine()` 等 ffmpeg，不能直接取 `runtime`。**
     冷启动双击工程时，`application(_:open:)` 跑在窗口出现之前，而
     `MediaToolchain.resolveIfNeeded()` 要等 `onAppear` 才被调到 —— 那一刻
     `runtime` **必然**是 nil。直接 return 的话图片段永久停在待转换。
  2. **手动重链接图片之后要再跑一次 `refreshStillClips`。** 重链接只换了
     `stillImageURL`，`sourceURL` 还指着那份多半已经不存在的旧缓存。
  3. **导出遇到 `needsStillConversion` 必须报错，不能过滤掉。**
     `VideoEditExporter.plan` 以前直接把这些段滤掉，导出会「成功」但用户的图片
     凭空消失且毫无提示。

## 四、素材重链接：四层线索（音频库素材前后各多一层）

`VideoEditProjectIO.resolve` 按从快到慢的顺序试，命中即返回：

| 层 | 手段 | 覆盖的情况 |
| --- | --- | --- |
| 1 | 原路径 `fileExists` | 素材没动过 —— 绝大多数情况在这里就返回了 |
| 2 | `URL.bookmarkData()` | **改名、移到同一个盘的任何角落、又改名又移动**。书签记的是 inode + 卷标识而不是路径，这是 macOS 自带的能力 |
| 3 | 相对工程文件的路径 | 工程 + 素材**整个文件夹一起搬走或拷到别的机器**（新 inode，书签失效） |
| 4 | 按文件名 + 大小搜索 | 外接盘换挂载点、从备份恢复。搜索范围：工程目录 + 本次已找到素材的目录 |

四层都没中才进 `missingMedia`，界面上是 `MissingMediaBar`（橙条 + Relink 菜单）。
**素材丢了时间线不能丢** —— 剪辑照样留在轨上，重新链接后接着剪。

### 音频库素材：四层之前先认领，四层之后还有一次（2026-09-22 起）

带 `EditClip.remoteKey`（音频库素材的 manifest id，v18）的段**在四层之外另有两层**，
因为它们有一条别的素材没有的线索：**这段素材本来是什么**。

| 时机 | 做什么 | 覆盖的情况 |
| --- | --- | --- |
| **四层之前**（`relinkRemoteLibraryMedia`，纯路径判断、不碰网络） | 原路径不在了就按 id 指回音频库缓存 | 工程从别的机器拷来、缓存目录重建过 |
| 四层 | 照常 | — |
| **打开之后**（`recoverRemoteLibraryMedia`，异步走网络） | 本地缓存也没有就按 id 从 R2 重新下载 | **用户清过缓存**、换了机器、工程发给别人 |

两条硬约束：

1. **原路径还在就一个字都不许动。** `remoteKey` 只说明「这段素材来自音频库的哪一
   条」，它不该越权去改一个还好好的路径 —— 那可能是用户自己导入的同名文件。
   有断言钉着（`checks/ProjectFile` 第 26 节），反向验证过。
2. **认领之后 `remoteKey` 必须留着。** 下次清缓存还要靠它。

**这两层是 `remoteKey` 存在的全部理由。** 只存字段不实现认领的话，v18 保住的就是
一个没人读的键：用户清过缓存之后看到的仍然是「素材丢失」加一个指向缓存目录的
死路径，而他根本没法知道原来是哪一首。素材制备与 manifest 见
[音频库素材管线](../build/audio-library-pipeline.md)。

### 运行中也要重核对（2026-08-08 起）

四层线索**不只在打开工程时跑**。工程开着的时候素材照样会被改名/挪走，而预览
重建对加载失败的段只能静默跳过 —— 没有运行中的核对就是「黑屏零提示」
（见 [2026-08-08-runtime-media-relink](../bugfixes/2026-08-08-runtime-media-relink.md)）。

- 入口：`VideoEditProject.revalidateMediaLocations()`，两个触发点 ——
  `NSApplication.didBecomeActiveNotification`（去访达动文件必然让 App 失焦）
  和 `scheduleRebuild()`（兜住不经过失焦的路径，保证黑屏出现的那次重建旁边
  一定跟着一次核对）。
- **必须与 `load` 共用同一套 `resolve` 线索**（`relocateMedia` 只是运行中的
  入口）。两边分叉就会出现「重开能找回、运行中却报丢失」的割裂行为。
- 单飞 + 收敛：核对改了引用会触发重建、重建又触发核对，第二轮全部原地命中
  即停。改这段时别打破「无变化就不写 state / 不发布 missingMedia」的守卫，
  那是收敛的前提。
- **await 回来只对此刻仍被引用的路径动手**（编辑没停过），找回来的按
  `promptRelink` 同一套账更新 `mediaRecords` 并立刻回存（同 `didRelink`）。

几条不能改的细节：

- **相对路径最多往上走三层**（`MediaRecord.relativePath`）。再远就不像「一起
  搬走」的关系，容易误配到别的文件。
- **同名搜索必须验大小**，深度限 3 层，并且 4000 条目的预算是**整次载入共用的
  全局预算**（`searchEntryBudget`，按 `inout` 传下去）。每个素材各给一份的话，
  丢 20 个素材 × 5 个已知目录 = 最坏 40 万次 stat，打开工程会卡死。
- **载入要放在后台线程**（`openProject` 里的 `Task.detached`）。它要遍历素材、
  可能还要翻目录，占着主线程就是转圈。
- **手动重链接要按目录批量匹配**：用户指认一个文件后，同目录下其他丢失素材按
  文件名自动配上（`promptRelink`）。素材通常整批一起搬，别让人点十遍。
- **靠 2/3/4 层找回来的要立刻回存一次**（`LoadResult.didRelink` → `saveNow`），
  否则下次打开又要重走慢路径。

### 素材信息里的关键帧间隔（2026-10-01 起）

`MediaInfo.keyframeInterval`（秒）随工程存，导入时由 `MediaKeyframeProbe` 扫采样表探出来，优化媒体靠它判长 GOP
（[优化媒体](optimized-media.md)）。**不升格式版本**：老版本读到不认识的键照旧忽略，老工程缺键解成 nil（不知道），
丢了也只是下次再探一遍，不是数据。

### 运行中素材只开一次（2026-09-25 起）

预览重建时的 `AVURLAsset` 走进程级缓存 `MediaAssetCache`（`VideoEditMediaAssetCache.swift`），
**按「路径 + 文件身份」记**，身份 = inode + 卷 + 大小 + 修改时间。以前每次松手重建都把工程里每个文件
重新 `AVURLAsset(url:)` + `loadTracks`（用户 77 段的工程一次 63 个），
案例 [松手重建把每个素材重新打开一遍](../bugfixes/2026-09-25-rebuild-reopens-every-asset.md)。

- **路径上换成了别的文件必须重开**（删了又放回同名的、先写临时文件再改名盖过来）：inode / 卷变了
  就重开，和上面「运行中也要重核对」是配套的 —— 核对改了引用，路径变了，键也就变了。
- **原地改写过也必须重开**（`ffmpeg -y` 往同一个输出路径写是截断重写，inode 不变）：靠大小和修改时间
  认。这是它比存盘的书签缓存（只认 inode + 卷）多出来的两样 —— 书签跟着 inode 走，原地改写不影响它；
  缓存的 asset 却已经读过旧的文件头，接着用会按旧的采样表去读新内容（自检实测：原地改成白视频，
  拿旧 asset 取出来的帧还是黑的）。
- **路径不存在就不缓存**：现开一个让 builder 自己去失败（它对加载失败的段只能跳过），行为和
  以前一样，不会把「文件回来了」的时刻错过。
- 缓存的是 `AVURLAsset` 实例本身（AVFoundation 缓存已经载入的属性），合成只引用它的轨、不改它；
  最多 256 个、超了丢最久没用的。
- `composition.assetOpen` 这个性能计数从此只记**真开了文件**的那几次。
- 自检 `scripts/check-preview-composition.sh`（`checks/PreviewComposition/AssetCache.swift`）钉着：
  同一份状态建两次第二次一个文件都不重开、取出来的帧一样；同一路径换成黑视频之后必须重开、
  帧变黑；原地改写成白视频之后也必须重开、帧变白。

### 换成 upscale 文件的段（2026-10-02 起）

规则在 `VideoEditClipUpscale.swift`（纯值，`checks/ProjectFile/Upscale.swift` 第 41 组钉着），方案见
[视频 upscale](../plans/2026-10-02-video-upscale.md)：

1. **记在段上**（`EditClip.upscale: ClipUpscaleRecord`）：原片路径、`sourceOffset`（新文件的 0 秒 = 原片的第几秒）、档位、原片的探测信息、
   原片的音频库键。读得宽：只有原片路径是必需的。
2. **换源 = 源时间整体平移**（`ClipSourceSwap.apply`）：入点减去偏移，关键帧、标记、音量曲线一起挪，时间线上的位置和长度不动。
   新文件盖不住这段用到的范围就不换（差一帧以内算盖住：FLUX 会多一帧或少一帧，零头由合成 / 导出各自夹到素材末尾）。
   换源之后段上的 `remoteKey` 清掉、记进记录（留着的话重链接会按键把 upscale 文件换回库里的原片）。
   压在这段上的字幕、文字、音效也不动：联动把同 id 换了素材的段按改之前的素材和入点记账（`TimelineLinkage.Piece.rebased`，
   [联动](timeline-linkage.md) 规矩 1；[案例](../bugfixes/2026-10-15-linkage-follows-source-shift-after-swap.md)：以前按新入点对账，
   全被挪了一个余料的长度）。edit_clip 换文件（`ClipFileReplacement`）同一条。
3. **再次 upscale 仍按原片算**：`sourceOffset` 永远相对原片；记录里的原片只记第一次的。
4. **换回原片**（`ClipSourceSwap.revert`）逐字段还原。原片挪了按存盘时配的书签找（`VideoEditProject.upscaleOriginalURL`），找不到就不换、菜单灰掉。
5. **原片配书签但不进 `mediaURLs`**：存盘的素材表是 `mediaURLs + upscaleOriginalURLs`（`VideoEditMediaReferences.swift`）；
   `mediaURLs` 只有此刻播的文件 —— 原片删了不该亮「缺素材」。重链接（`replaceMedia`）把记录里的原片路径一起改。
6. **从旧段构造新段要抄这个字段**：分割抄给右半（`checks/project-file-wiring.sh` 钉着）；复制粘贴走编码往返自然带着；
   分离出来的音频**不带**（声音留在原片上，upscale 只管画面）。
7. 工程里用同一个原片的画面段**一起换**（`TimelineState.clipIDs(usingPicture:)` / `applyUpscale`），范围被盖住的才换；分离出来的音频不算。

## 五、脏标记与自动保存

- **`state` 的 `didSet` 是唯一的脏标记入口**。所有时间线写入（`perform` /
  `liveApply` / `applySnapshot`）最终都是给 `state` 赋值，挂这一个点就够了；
  别在各个操作里分别标脏。
- 不算用户改动的写入走 `replaceStateForDocument`（整体换）或
  `applyDocumentRepair`（局部修补），它们用 `isLoadingDocument` 把脏标记压住 ——
  打开工程、补静帧、重链接素材都属于这一类。
- **切工程前必须走 `closeCurrentDocument`**：作废工程代号 + 停播放 +
  `clock.detach()` + `cancelLiveEdit()` + 清选择 + 清定位表 + **清撤销栈**。
  漏掉撤销栈的话，⌘Z 能把上一条工程的内容撤回到当前工程里。清的是**这个工程的**撤销栈（窗口交来的或工程自己的，
  2026-10-17 起不再退到键窗口的 —— 那可能是别的工程的窗口，[开着的工程](open-projects.md) 第三节）。
  「清选择」走 `clearSelection()` 一个入口（剪辑/形状/字幕 cue 三类一起），
  别在这里手抄字段名 —— 抄漏过一次（2026-08-09 复审），合同见
  [subtitle-track-visibility-and-layout](subtitle-track-visibility-and-layout.md)。
- **播放头归零要真的归零**（2026-09-29，[新工程停在上一个工程的位置](../bugfixes/2026-09-29-new-project-keeps-old-playhead.md)）：
  `detach()` 把播放头放到 0，可播放器换掉条目之后时间回调还会晚到一拍、报旧条目的时间（带音轨的素材停着卸片也会）。
  `PlayerClock` 没挂条目时丢掉时间回调；以后谁要在卸片之后再读播放器的时间，也要先问有没有条目。
- **换完整份时间线就要 `scheduleRebuild()`**：打开工程、补静帧 / 重链接都这么做，新建工程也要（上一个工程还在路上的
  那次重建靠它作废，不然落地时把旧工程的画面挂进新工程）。`check-project-file.sh` 的接线守卫钉着 `newProject`。
- flush 的三个时机：切走 Edit Video 栏（`onDisappear`）、⌘S、退出 App
  （`applicationShouldTerminate` → `ProjectQuit`）。自动保存有 2 秒防抖，正好卡在那两秒里按 ⌘Q
  会丢改动。

### Writing the project file off the main thread (2026-11-19)

Since [saving a project on a slow or stuck drive froze SkyCut](../bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md):
a project file can live on a sleeping, slow, read-only or stuck external drive, and nothing may wait on it on the main thread.

1. **Only `ProjectFileWriter` writes a project's own file** (`VideoEditProjectIO.save`, the moved-file bookmark, a fresh
   document bookmark after every write), on the project's serial queue. One write at a time; a newer snapshot of the same
   file replaces one still waiting. `checks/project-versions-wiring.sh` pins the writers.
2. **Production code saves only through the async calls** — `saveToFile`, `flushToFile`, `saveAs`, `saveSoon`,
   `prepareToClose`, `startNewProject`, `OpenProjects.closeProject` / `createProject` / `resetPrimary` — which wait for the
   drive at most `ProjectFileWriter.deadline` (15 s). The blocking `saveNow`, `flushAutosave`, `saveDocument(as:)`,
   `prepareToCloseDocument`, `newProject()`, `OpenProjects.close` / `newProject(savingAs:)` write on the caller's thread and
   exist for the checks and dev hooks only (`checks/file-io-off-main-wiring.sh`).
3. **Dirty marks**: every change goes through `noteUnsavedChange` (the `state` / row-height `didSet` and the relinks), which
   bumps the writer's change counter. A write clears `hasUnsavedChanges` only when the counter still has the value its
   snapshot was taken with; a media-table entry changed on the main thread during a write wins over the one written.
4. **A drive that does not answer** is "not responding": the notice says so, the project stays dirty and open, the write
   goes on, and when it lands the project is marked saved and the notice goes away (a late failure is said). Closing,
   switching (New / Open / Open Recent, the project window's close button, the AI's `close_project`) do not happen while a
   project's file can't be written: `prepareToClose` answers ready / refused / waitingForDrive. A project window closes at
   once when there is nothing to write (`closesAtOnce`), otherwise after its save.
   **`.ready` is decided at the moment it is answered** (`ProjectClosing.swift`, since
   [closing trusted a write of an older snapshot](../bugfixes/2026-11-19-close-trusts-a-stale-save.md)): the same document
   generation as when the close started, nothing unsaved, nothing being written. A write that lands only says that *its*
   snapshot is on the drive; an edit made meanwhile (typing, an AI tool call) is written too, within what is left of the
   same deadline, before the answer is ready. Callers act on `.ready` at once, with no other wait in between
   (`replaceWithNewProject`, the window's `close()`, `finishClose`).
5. **Save As** (§ "切工程必须是事务性的" item 6 still holds): the new file is taken only when its write succeeded within the
   deadline; a Save As that lands later never moves the project. A file already at the URL is replaced only when that was
   confirmed for exactly that URL (macOS's own save window, the replace question, the AI's `save_project` back to the
   project's own file); otherwise the project file is written under a private name in the same folder and takes the name in
   one step that fails when it is taken, so a file there, or one that appears meanwhile, stays as it was (`.occupied`;
   [open and save windows](system-file-windows.md) rule 9, [export settings](export-settings.md) §5 item 9).
6. **Quit** (`ProjectQuit`): `.terminateNow` when no project needs writing or asking; otherwise `.terminateLater` and one
   reply. Each project gets 3 s quietly, then an alert that keeps waiting by itself (SkyCut quits once the file is written),
   with "Don't Quit" and "Quit Anyway" (giving up only that project's unsaved changes). Quitting after a screen recording goes
   through the same `prepareAll`, which runs once when asked twice. The atomic write keeps the file on disk whole if SkyCut
   quits while a write is stuck. Before it replies, Quit looks again: a project it let through that changed since (an AI
   tool call while another project's alert was up) is settled again, and so is a project opened meanwhile; one given up
   with "Quit Anyway" is not. The reply is a closure called in the same main-thread turn as that last look
   (`prepareAll(reply:)`), never after awaiting another task, which would leave a gap for an edit.
   **"Quit Anyway" belongs to the document its alert showed**, not to the project object (since
   ["Quit Anyway" covered a replaced document](../bugfixes/2026-11-19-quit-anyway-covers-a-replaced-document.md)): the
   mark carries the document generation taken right before asking, and another document opened in that project since (an
   Open that waited for the write, the AI's `open_project`) is settled like any other. Whatever Quit remembers about a
   project is compared by document generation, never by object identity alone.
7. Behaviour: `scripts/check-project-saves.sh`.

### What an empty project is (2026-11-27)

`TimelineState.isEmpty` is the one answer to "is this project empty?": would its file hold anything the person made. Closing an
untitled project asks Save… / Discard / Cancel only when it would (`prepareToClose`, `closesAtOnce`, `prepareToCloseDocument`:
Quit, Restart and Update, New, Open / Open Recent, a project window's close button, the AI's `close_project`). The same answer
decides the start screen and the timeline's empty state, Play and Export, whether the AI may take over an untitled main window
and must save an untitled project it changed, and whether a version is saved. There is no second notion of empty: a new field
the project file keeps goes on one side of this list in the same change, and `scripts/check-project-file.sh` group 54 pins
both sides.

- **Content** (each alone makes the project not empty): clips on any track (with their markers, curves and keyframes), the
  original subtitle track, a translation track (SkyCut keeps it only beside an original, but the file can hold it alone),
  shapes (covers too), texts, grades (with their markers), **markers on the ruler, with or without a note**, the storyboard
  (`production`), an explicit ending (`minimumDuration`), **review reasons** (`deliveryIntentions`: `inspect_video` keeps
  listing them, as not reproduced once their clips are gone, until they are explicitly cleared —
  [finished-video inspection](finished-video-inspection.md)), and **a pinned Sky Studio style version** (`editingStyle` with
  `isPinned`: it decides which version of the style the film reads next time, v40 below).
- **Not content** (alone): the canvas shape and frame rate, the faders, the eyes and the magnet, tracks without clips, the
  project's subtitle style, place, word highlight and line count, a subtitle companion's languages and generation settings
  without a translation, a style record that only says where a style came from (a preset's or the user's own: recorded,
  never pinned), and outside the timeline the row heights (decoration, above) and the media table (made from the clips).

Ruler markers were missing from the list until
[an untitled project with only ruler markers closed without asking](../bugfixes/2026-11-27-untitled-project-with-only-markers-closes-unasked.md):
the markers and their notes were thrown away unasked. Review reasons and the pinned version joined the list in that case's
review round (CXL1): an untitled project left with only a review reason closed on New Project without asking, and the reason
was gone.

### 切工程必须是事务性的

**`flushAutosave()` / `saveNow()` 的返回值必须被在意。** 磁盘满、权限变了、外接盘
被拔掉的时候保存是失败的；以前无条件 flush 完就关，未保存的编辑直接没了。

固定顺序（`prepareToCloseDocument` → `closeCurrentDocument` → 应用新内容）：

1. **`openProject` 要先把目标读出来验明正身，再动手里这条。** 反过来的话，目标
   文件损坏时当前工程已经被关掉了 —— 画面还在，但 `documentURL`、撤销栈、脏标记
   全没了，后面的编辑再也不会自动保存。
2. `prepareToCloseDocument()` 返回 false 就**原地不动**，别调 `closeCurrentDocument`
   （它会把保存失败的 notice 一起清掉）。
3. 从没存过、又有内容的未命名工程要弹 Save…/Discard/Cancel。自动保存的语义只覆盖
   已经有位置的工程，没位置的直接扔就是数据丢失。What counts as content: "What an empty project is" above (ruler markers
   and their notes too).
4. **打开的就是当前工程时，只 flush，不载入。** 「先读后关」的顺序在这个特例上
   会反噬：读到磁盘旧状态 → flush 写下新状态 → 又拿旧状态盖回内存并标成干净，
   下一次编辑把新状态从磁盘上也抹掉。Open Recent 里永远有当前工程，这条路是
   真实可点的。
5. **每个 await（含模态框的嵌套 runloop）之后要验 `openRequestToken`。** 连点
   两个最近工程时，慢的那个后回来会把先打开的顶掉。The close itself checks the document generation after every wait
   (`prepareToClose`): a save window answered after another document replaced the untitled project it was opened for
   writes nothing — the check comes before the write, not after it.
6. **Save As 的新身份只有写盘成功才作数**：先暂存旧 `documentURL`/书签，
   `saveNow()` 失败就整个回滚，否则工程卡在一个写不进去的 URL 上。
7. **退出必须走 `applicationShouldTerminate`**，**每个开着的工程都过一遍**（2026-10-17 起，[开着的工程](open-projects.md)），失败或用户点取消就
   不退。`willTerminate` 那一步已经拦不住退出，写盘失败只能眼睁睁
   丢数据。Since 2026-11-19 through `ProjectQuit` and `.terminateLater`: the files are written off the main thread (the
   section above).

### 后台导入要带工程代号

导入（探测时长、图片转静帧）是脱手的 Task，工程切走之后它们才回来。
`closeCurrentDocument` 会 `invalidateDocumentGeneration()`，**每个 await 之后、
每次写 `state` 之前都要 `isCurrentGeneration(generation)` 复核**，否则素材会被
追加进新工程，或者平白把新工程标脏。新增任何后台导入都要走 `trackImportTask`。

两个容易搞错的细节：

- **代号必须在创建 Task 之前抓，作为参数传进任务体。** Task 创建后未必立刻跑；
  等它跑起来时工程可能已经切了，那时在体内读 `documentGeneration` 读到的是
  **新**工程的代号，守卫形同虚设。任务入口再补一道 `Task.isCancelled`。
- **失败分支写 `notice` 之前也要验代号**，否则旧工程素材的报错会写到新工程脸上。

### 图片段的身份要在复制路径上跟着走

`stillImageURL`（和 `needsStillConversion`）是图片段的真身标记。**任何从旧段
构造新段的代码**（分割 `split`、定格、复制粘贴）都必须把这两个字段带上 —— 同理还有
`remoteKey`（音频库素材的身份）和 `isHidden`（段的隐藏）：2026-09-26 发现分割漏了这两个
（[案例](../bugfixes/2026-09-26-split-drops-hidden-and-library-key.md)）。复制粘贴不手写照抄，
走「编码 → 换 `id` → 解回来」（[复制粘贴](timeline-clipboard.md)）；
丢了的话新段会把静帧缓存 mp4 当真实素材写进工程，缓存一清这段就无法重建。

## 六、工程文件自己也会被搬走

`documentURL` 是普通路径 URL，用户在访达里把**正开着的**工程改名或挪走之后，
按旧路径保存会在旧位置重新造一个旧名字的文件 —— 用户以为在编辑的那份反而再也
不更新。所以打开/保存时给工程文件本身也存一份书签（`documentBookmark`），
写盘时（`ProjectFileWriter`）发现旧路径不在了就用它把 `documentURL` 跟过去。
**The bookmark is made again after every write** (2026-11-19): the atomic write gives the file a new inode, and a bookmark
made before it no longer finds the moved file — until then this only worked before the first save after opening
([case](../bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md)).

## 七、回归清单

改上述任何一块后，至少跑：

1. `scripts/check-project-file.sh` —— 存取往返、四层重链接（含运行中的
   `relocateMedia`）、丢失上报、宽容解码、**书签保全**、版本校验、重链接后
   补静帧。**加了新字段要往 `checks/ProjectFile/main.swift` 里补一条**，
   升版本时还要改那批**写死版本号**的断言（写死是故意的，见上）。
   A new field also goes into group 54 (`EmptyProject.swift`), as content or not (§5 "What an empty project is").
   脚本末尾另有一段**接线守卫**（grep 级）：自检编不动
   `VideoEditProject` / `TranscriptionTask` 这类 @MainActor App 类型，
   「纯函数有没有被调用、参数对不对」只能在源码层面钉住。
2. 真实窗口冒烟（流程见 `docs/testing/gui-smoke-testing.md`）：
   - 双击 `.skycut`（和改名之前的 `.srtflowproj`）→ 落到 Edit Video 并载入素材、画布比例正确
   - 空工程 → 起始页显示最近工程，重启 App 后还在
   - 把素材**改名** → 重开工程 → 应当**无感自动找回**（书签），且工程被回存
   - **工程开着**把素材改名+挪走 → 切回 App → 剪辑块显示新名字、预览不黑、
     工程被回存；把素材删掉 → 切回 App → 橙条当场出现；放回去 → 自动消条
   - 把素材**删掉** → 重开工程 → 橙条报丢失、剪辑仍在轨上
   - **冷启动**双击一个含图片段、且静帧缓存不存在的工程 → 图片段应当自动转好
     并出现在预览里（验 `awaitVideoEngine`）
   - 未命名工程里加一段素材 → File ▸ New Project → 应弹 Save…/Discard/Cancel，
     点 Cancel 后剪辑还在；⌘Q 也应弹同一个框，Cancel 能取消退出
   - An untitled project: add media, mark the ruler and write a note in the marker, delete the media → the timeline stays
     (the flag on the ruler, not the start screen); ⌘Q, File ▸ New Project and a project window's close button each ask
     Save…/Discard/Cancel; Cancel keeps the marker and its note (2026-11-27)
   - 两条音频轨各拖成不同高度 → 存盘 → 重开工程 → 两条轨各自的高度都还在；
     新建工程时每条轨回到默认高度（不会带着上一份工程的条目）
   - 播放头停在工程后半段（在播、停着各一次）→ File ▸ New Project / 打开另一个工程 → 播放头在 0:00
     （卸片之后晚到的时间回调由 `check-player-clock.sh` 用真播放器钉着，这一条看真窗口）
3. `scripts/check-project-saves.sh` — the project file written off the main thread (§5 "Writing the project file off the main
   thread"): slow, stuck and failing drives, switching away, Save As, Quit; an edit made while New / a close / Quit is
   writing, Quit looking again at a project it let through, a document opened in a project after "Quit Anyway" was chosen
   for the one before it, a save window answered too late; an untitled project left with only a ruler marker and its note
   asked about by every close, and one left with only a review reason or a pinned style version asked about by New Project
   (§5 "What an empty project is"). Real windows and a real drive, before a release:
   - a project on a USB hard drive that has gone to sleep: edit, wait for the autosave — the timeline stays responsive while
     the drive spins up; ⌘S right after — no beachball, the notice says the drive is not responding if it takes over 15 s;
   - the same project, then ⌘Q while the drive is asleep: SkyCut quits once the drive answers, or after about 3 s shows
     "“Name” isn't saved yet" — left alone, it quits by itself when the write lands; "Don't Quit" keeps SkyCut open
     with the project dirty; "Quit Anyway" quits and the file on the drive is the last saved one (not half-written);
   - close a project window with unsaved edits on a slow drive: the window stays until the save lands, then closes; with
     nothing unsaved it closes at once; type into a subtitle while it waits: the window closes only after a save that
     includes the typing (reopen the project from Open Recent: the typing is there);
   - rename and then move an open project in Finder after it has been saved a few times: the next save follows it, no new
     file appears under the old name.
