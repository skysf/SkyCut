# 预览区自由变换（ClipPlacement + Transform 面板）：两条管线必须同账

> 2026-08-04 引入，同日扩入 Transform 面板（旋转/不透明度/翻转/裁切）。
> 改预览合成（CompositionBuilder）、导出滤镜图（ExportGraph）
> 或预览交互层（ClipTransformCanvas）之前必读。

## 模型

`EditClip.placement: ClipPlacement?` —— 中心 + 宽高，全部是**相对画布的 0…1
归一化值**（宽随画布宽、高随画布高）。约定：

- **nil = 默认布局 = 等比铺满画布、居中，不分轨道**（2026-09-17 起）。
  主轨和上层视频轨走**同一份账**，公式只有 `defaultPlacement` 一处，
  合成 `fittingTransform` 和导出 `transformSteps` 都从它派生。老工程、
  没摆过的段都是 nil。

  在此之前上层轨是「画中画」：nil 表示按 `overlayFraction`（画布宽 40%）+
  `overlayAnchor` 九宫格停在角上。那两个字段、`OverlayAnchor`、导出的
  `xExpression`/`yExpression` 九宫格表达式**全部删除**，没有迁移 ——
  这是一次语义换代，工程格式因此升到 v10（见 VideoEditFormatVersion.swift
  的 `requiresFormatVersion10`）。

- **等比是 contain，留空处不补黑**。比例对不上的素材两侧（或上下）留空，
  露出来的是**下面那一层**：主轨下面是画布黑底，上层轨下面是主轨画面。
  这来自 overlay 合成本身 —— 导出侧**不许**给上层轨补 `pad`，补了就把
  主轨遮死。回归靠 `scripts/check-video-fade.sh` 的四个像素探针守着。

- **上层轨盖住主轨是正常语义**，不是 bug：上层段满幅不透明时，那段时间
  主轨就是看不见。连带后果是预览里点画面只会命中最上面那一段，所以
  `ClipTransformCanvas.selectClip` 提供 **⌥ 点击在命中的那一摞里轮换**
  —— 没有它，被盖住的主轨在预览里选不中。
- 宽高**各自独立**（拉边把手允许变形），所以不能只存一个 scale。
- `resolvedPlacement(canvas:isOverlay:)` 是唯一的"此刻实际框"换算口；
  预览选中框、拖动起点、Inspector 的 Position/Scale 都从它取。

### A canvas change keeps every clip's shape (2026-11-17)

The stored numbers are fractions of the canvas, so the same numbers on a canvas of another shape stretch the picture: a clip filled
into 9:16 came out 3.16× wide after set_canvas 16:9 ([case](../bugfixes/2026-11-17-canvas-change-stretches-framed-clips.md)). Rule
(`CanvasReframe`, run at the end of `VideoEditProject.perform` after the magnet; every path that changes the canvas's shape goes through
it: set_canvas, the canvas menu, auto following a new first V1 clip, a screen recording setting the ratio):

- Every picture clip whose framing that edit did not set keeps what the inspector and the AI read — its centre (x, y on the canvas)
  and its size relative to the default layout (scale), each axis on its own. So its shape stays (a deliberately stretched clip stays
  stretched by the same factors), its crop stays, and switching back restores the old numbers exactly. Position / size keyframes
  are re-expressed the same way; rotation and opacity are untouched.
- Nothing is re-cropped or re-filled: this is how the default layout (nil) already behaves on a new canvas (contain, letterbox).
  A clip that filled the old frame may not fill the new one. set_canvas lists `reframed` (the clips whose numbers were redone) and
  `no_longer_fill` (picture clips that covered the old frame and not this one, default-layout clips included) so the AI can call
  edit_clips fit=fill on them (`AICanvasReframe`). Re-filling on its own would have to guess the window and could bring back what a
  crop had removed (black bars, a watermark); keeping the shape never shows anything the clip did not show before.
- A clip framed by the same edit that changes the canvas is left as that edit set it.
- **Texts and shapes** (2026-11-17, `OverlayReframe`, called from `CanvasReframe.keepShapes`;
  [case](../bugfixes/2026-11-17-canvas-change-resizes-texts-and-shapes.md)): their lengths are stored against two edges — pixels of a
  1080-high frame (font size, stroke, shadow, plate, letter spacing, a shape's line width and cover strength) and fractions of the
  frame's width or height (a shape's width, a rectangle's height) — so on another shape they stretched and drifted apart. Every text
  and shape the edit did not size itself keeps its centre (x, y) and its size against the frame's **short side**: all its lengths get
  one factor, so nothing is stretched. Every preset is 1080 on its short side, so a preset switch keeps the pixels; switching back
  restores the numbers (unless a text value hits its range). Ordinary and manually set text wrap widths (`boxWidth`) keep their
  share of the frame's width; a line that no longer fits wraps. A preset text whose wrap width hugged its words is remeasured with
  `MotionPresetLayout.snugBoxWidth` after its style is scaled and clamped: the wrap still hugs the words and remains automatic when
  they are edited later. Each member keeps its own centre; do not rearrange the group or overwrite manual offsets.
  (Fitting the old frame inside the new one was rejected: it shrinks again on the way back.) set_canvas lists them in `reframed`,
  including a text whose only change is its wrap width, and in `off_frame` those that sat inside the old frame and
  stick out of the new one.
- Out of scope: subtitle layouts (their size follows the subtitle style).
- Checks: `scripts/check-mcp.sh` → `CanvasReframeChecks` (the walkthrough's fill, a corner picture, size keyframes, auto canvas,
  the reply) and `CanvasOverlayChecks` (texts and shapes keep their pixels and proportions, the way back, 4:3, auto 4K, the reply's
  `off_frame`), plus `CanvasPresetChecks` (all three native presets on 16:9 → 9:16 → 16:9 and auto 4K → 720p phone → 4K;
  snug wraps, typing after the switch, manual widths, style clamping and width-only replies), wiring in
  `checks/MCP/canvas-wiring.sh` (perform runs it after the magnet; set_canvas reports it).
- [ ] Manual, before a release: in the editor, zoom a clip to cover a 9:16 frame and put a small picture in a corner, switch the
  canvas menu to 16:9 and back: nothing stretches in the preview or the export, and 9:16 looks exactly as before; ⌘Z undoes each switch.
- [ ] Manual, before a release: on 16:9 add a title, a rectangle, a ring and a tilted line, switch the canvas menu to 9:16: the
  rectangle is not stretched, the ring's stroke is as thick as before, the title is as big as before (longer lines wrap), the
  export matches the preview; back to 16:9 everything is as it was.

### Does the picture cover the frame (2026-11-17)

get_timeline / edit replies said `fills_frame: true` for a clip turned 5° at scale 1.1 while look showed a bare corner, and a keyframed
drift bared the left edge with nothing said ([case](../bugfixes/2026-11-17-fills-frame-ignores-rotation-and-motion.md)): the old test
looked at the static box only. Rule — **one geometry** (`PictureCoverage`) answers every "does it cover" the AI reads:

- A picture is its box (`ClipPlacement.frame(in:)`) turned clockwise about the box's own centre — the order both pipelines draw it in
  (the transform order above). Flips mirror inside the box and a crop only changes the box's shape (the default fit follows the
  cropped picture), so neither changes what it covers; a wipe part-way draws only part of the box (on the right when flipped).
  It covers when every canvas pixel's centre is inside (half a pixel, the tolerance the axis-aligned test always had).
- `fills_frame` (`ClipCoverage.fill`, via `AIFrameFit.describe`) is the clip **at rest** — static placement or the default fit, position /
  size / rotation keyframes (`animatedPlacement` / `animatedRotation`) — at every frame it is on screen: a moving clip is tested on a
  1/120 s grid (every frame of 24, 30 and 60 fps lands on it; one test when the box does not move). When it fails: `fill_scale`, the
  smallest steady scale that covers throughout keeping x, y, rotation and shape, measured to the canvas's own corners and rounded up
  (the preview compositor draws edges up to about a third of a pixel off the geometry: at the pixel-centre value two corner pixels of
  a real frame stayed dark), and `fills_except`, the [from, to] timeline seconds when it fails only part of the time (at most 8).
  set_keyframes returns `picture` too.
- look's `uncovered` (`AIPictureCoverage.uncovered`) is that moment's frame: the pictures on screen then (the clips `on_screen` lists,
  `ClipCoverage.onScreen`), each with the entrance / exit motion of that moment as the builder applies it (a V1 transition takes its
  edge), their union; a bare edge reports how deep the gap reaches, a bare corner how far it runs along each edge, canvas pixels.
  Pictures with transparency and stills still converting do not cover. Never from pixels: dark footage is not uncovered.
- Not counted anywhere: opacity, fades and transitions (they show what is below on purpose; at a seam each clip counts alone).
  Entrance / exit motion is not part of `fills_frame` (framing at rest): a turned clip with rise or pop bares the frame during the
  motion, because the builder's no-bare-edge compensation (`placementCoversCanvas`) treats any turned clip as not covering — look shows it.
- The render path's own tests (`coversCanvasOpaquely` for the dissolve path, `placementCoversCanvas` for that compensation) stay as they
  are: they choose drawing paths and stay conservative for turned clips. No AI file tests coverage by itself (`checks/MCP/coverage-wiring.sh`).
- Checks: `scripts/check-mcp.sh` → `PictureCoverageChecks` (a 1,092-case rotation / scale / offset sweep against an independent
  pixel-centre bitmap, fillFactor is the smallest growth, gaps between pictures, a half wipe) and `ClipCoverageChecks` (the walkthrough's
  turn and drift, flips, a crop, rotation keys, a spring dipping below its keys, the sampling grid, look's uncovered with V2, hidden clips
  and tracks, transparency, a gap, wipes, a transition, rise); real frames of the preview compositor against the same geometry in
  `scripts/check-preview-composition.sh` (`RotatedPictures.swift`: turned, flipped, drifting, turning, and at fill_scale).

Transform 面板追加的四个字段（都有「无操作」默认值，全默认走原来的轻量路径，
`hasVisualTransform` 是统一的判定口）：

- `rotationDegrees` —— 绕摆放框中心，**正角度 = 顺时针**（SwiftUI
  rotationEffect、CGAffineTransform 在 Y 朝下坐标系、ffmpeg rotate 三边天然
  一致，别再加负号）。
- `opacity`、`flippedHorizontally/Vertically`。
- `crop: ClipCrop?` —— 四边各裁掉源画面（显示方向）的归一化比例。裁完剩下
  的画面填进摆放框；**默认摆放框按裁后的宽高比算**（裁成 1:1 默认就显示成
  正方形），见 `croppedDisplaySize`。
  传统 `ClipCrop(top:bottom:leading:trailing:)` / MCP `crop` 仍每边最多 0.45；
  **精确源矩形**用 `ClipCrop(keeping:)`，允许单边超过 0.45，四边共同留下有效矩形。
  不增加遮挡层、不改素材。检查器单边改值只改那一边，不能把其它边夹回 45%。
  v33 的空裁切判定只容纳浮点零误差，不再用固定 0.05% 吞掉高分辨率素材里的真实像素；
  读 v32 及更早工程时，将当年被忽略的微小裁切迁移为无裁切，保住旧成片。

### Automatic black-bar removal (2026-11-17)

`edit_clip` and `edit_clips` analyze the source window that the call will commit, including simultaneous source_in / source_out
changes. Source-window validation is shared with the actual edit (`AIClipEdit.applySourceWindow`); probing never applies a partial
edit. Five midpoint samples use zero decoding tolerance, so a nearby shot outside the window cannot cancel its bars.

Removal and look measure with `AIBlackBars` at the same 1280-pixel long side, before Vision's separate thumbnail. The default
256-pixel luma helper stays unchanged for other consumers. Each edge still takes the minimum across the confident samples, with
zero cancelling that edge and uncertain readings not voting; content in a full-frame shot is never cropped to match another shot.
The reported `black_bars` are the measured widths. Automatic cropping includes one more analysis pixel at a detected boundary,
because a row mixing picture and black fails the fully-black threshold. Zero and uncertain edges gain no crop. The actual crop is
visible in `picture`, as for any framing edit. `fit=fill` without removal reports baked-in bars and a warning; that notice never
adds a crop of its own.

Regression: `scripts/check-parameter-limits.sh` uses synthetic thin asymmetric bars and two shots with different framing. It
checks the production single-call plan, look before / after removal, simultaneous trim, conservative mixed-shot handling, and one
undo for the complete change. Pure boundary-allowance checks are in `scripts/check-mcp.sh`.

- [ ] Before a release, remove bars from a real clip in one call, including a simultaneous source trim; compare preview and export
  with look at the beginning, middle and end. One undo restores both its source window and framing.

### MCP 的源矩形取景（2026-11-02）

`edit_clip` / `edit_clips` 的 `region={x,y,width,height}` 是**按素材旋转信息摆正后的源显示画面**上的比例，
左上原点，全部在 0–1 内、宽高大于零。先按显示尺寸向外取整源像素（每边最多多一个源像素），
`fit=fit`（默认）完整展示，`fit=fill` 在区域内取居中、与画布同比例的窗铺满。
实际区域和 fill 的窗每个方向至少留下 2 个源像素，否则整次拒绝。

- 参数和冲突只在 `AIFramingRequest`；几何适配在 `AIRegionFraming`，fill 的窗与映射仍只有
  `AIFrameFit.fillWindow` / `mapping`。原生预览继续逆着 preferredTransform 换算裁切，导出继续由 ffmpeg 按源旋转摆正。
- region 替换旧的裁切 / 摆放。不能同时给 crop、remove_black_bars、focus、focus_x/y、follow、x/y/scale、
  rotation、flip_horizontal/vertical（即便是 false / 0）。不运行主体识别，不额外生成形状或素材。
- 已有素材的静态翻转保留，坐标始终按翻转前的源显示画面；已有额外旋转 / 旋转关键帧 / 几何入出场先拒绝。
  可先清掉这些设置；旋转关键帧也能显式用 keyframes=clear 清。位置 / 大小关键帧沿用已有 fit 语义：
  fit=fit 拒绝，fit=fill 替换它们，opacity / 音量关键帧不动。
- 返回 `framing`：requested_region、region（实际原生裁切保留的区域）、visible_region（经过摆放后画布看得见的源窗）、
  source_display_size、transform（画布归一化中心 / 宽高、额外旋转及翻转）。`picture` 同样带实际区域和变换，
  get_timeline 可复查。坐标保留六位小数，不把小窗口四舍五入成零；动画取景不给误导性的固定 visible_region。
- 仍走单项计划和批量事务，一步撤销。保存只用原有 crop 四个键；**格式 v33** 保护超过 45% 的值，旧版必须拒开，
  避免它读进来夹坏后自动保存。新版读旧工程行为不变。

调用例子（把源画面右下角 8% × 6% 的控件完整展示）：

```json
{"clip_id":"a1b2c3d4","region":{"x":0.92,"y":0.94,"width":0.08,"height":0.06},"fit":"fit"}
```

`scripts/check-region-framing.sh` 在隔离 App 中运行实际编辑、look、预览和生产 plan() + ffmpeg；横屏、竖屏、
90/180/270 度旋转、不同画布比例、4% × 6% 四个边角、奇数像素边界，独立源坐标像素尺对账，包含一次撤销 / 重做及批量失败原子性。
`SRTFLOW_REGION_ARTIFACTS=/tmp/…` 可保留 look / 预览 / 导出图与测量值。MCP 参数和工程往返分别由 check-mcp / check-project-file 覆盖。

发版前人工回归：

- [ ] 真实网页录屏分别取提示词、模型菜单、角色卡；用 look 核对原稿小字，比较预览与导出同一帧。
- [ ] 在检查器改一次区域的一条边，另外三边（含 >45% 的值）不动；复位、撤销、保存重开均保持对应画面。
- [ ] 将带旋转信息的真实手机素材取到四角；确认左上角坐标按播放时看到的方向解释。

**变换顺序是合同**：裁切 → 翻转 → 缩放进摆放框 → 绕框中心旋转 → 平移到位
→ 画面渐变（`docs/architecture/video-fades.md`）。
预览（`fittingTransform` 拼 CGAffineTransform + `setCropRectangle`）和导出
（filter 链顺序）都按这个来，改一边必改另一边。

Inspector 的语义：Position = 摆放框中心相对画布中心的**输出像素**偏移；
Scale = 相对默认布局宽度的百分比，改动等比乘在当前宽高上（保留边拉伸变形）；
`setPlacement` 会把约等于默认布局的摆放归一回 nil（规则只有 `PlacementDefault` 一处，AI 摆画面
也走它，见 [AI 接口](ai-control-mcp.md) 第四节第 11 条）。**归一化容差必须小于
一个可见输出像素**（现为半像素：X/宽 `0.5/renderWidth`、Y/高
`0.5/renderHeight`）——固定归一化容差（如 0.001 ≈ 1920 宽下 1.9px）会把
Inspector 的 ±1px 步进整个吞回默认值，点了没反应。

## 两条渲染管线，一份时间账

| 管线 | 落点 |
| --- | --- |
| 预览（AVFoundation） | `fittingTransform`：完整 CGAffineTransform（翻转=负缩放）+ `setCropRectangle`（裁切矩形要逆着 preferredTransform 换算回源轨自然坐标）+ layer opacity（转场斜坡整体乘 clip.opacity） |
| 导出（ffmpeg） | `transformSteps`：`crop:exact=1` → `hflip/vflip` → `scale` → `format=rgba`（旋转/半透明/画面渐变才加）→ `rotate=θ:ow=rotw(θ):oh=roth(θ):c=black@0` → `colorchannelmixer=aa` → `fade=…:alpha=1`（画面渐变，必须在链尾）；**奇数裁切边界先把完整画面转为 RGBA 再裁**，避免 4:2:0 色度起点偏移被局部放大。主轨叠 `color=black` 画布，**overlay 用中心表达式 `cx-w/2`** —— 旋转会把输出框撑大，只有中心是不变量。**不用 pad**：pad 不接受负坐标/超界，overlay 允许探出画面 |

改任何一边都要对照另一边；验收标准是同一时刻预览截图和导出抽帧长一样。
像素尺寸过 `evenPixel`（正偶数，yuv420 要求），坐标取整。

**Upper video on the frame grid** (2026-11-17): its window is left-closed, right-open, just like the native preview
composition used by the player and AI look. Count its first frame and the first frame after its end with `FrameGrid`;
reuse `OverlayExportFile.enableWindow` (half-frame edges), never `between(t, start, end)` on raw seconds. Both ordinary
video and prerendered fill + matte are placed with `OverlayExportFile.placement`, half a frame before their output
frames, and clone two tail frames before placing. After cuts / crossfades the main stream has AVTB timestamps a few
microseconds off the grid; exact-grid placement can select the previous moving frame, and EOF can drop the last one.
The window still removes the layer exactly at its end. `scripts/check-export-frame-rate.sh` checks every frame of
ordinary and prerendered upper video at 24 / 30 / 60 fps against the native preview composition, over cuts and crossfades.
Timeline look requests first use the containing project frame (`TextAnimator.quantize`, shared with the overlays),
then `NativeSourceFrameSampler.requestedTime`: an exact frame converted by raw
`CMTime(seconds:preferredTimescale:)` can land one native tick early. The existing nearest-tick request policy preserves
the grid; the look generator's half-frame tolerance and the composition's truncating insertion/slice times stay unchanged.

**预览的黑底轨**：时间线上有任何半透明图层（不透明度、转场淡入淡出）时，
CompositionBuilder 会垫一条 `BlackBaseVideoFactory` 的不透明黑视频当底 ——
默认合成器在混合路径上不铺 `backgroundColor`，见
[2026-08-04-opacity-green-background](../bugfixes/2026-08-04-opacity-green-background.md)。
工厂是 actor 单飞：唯一临时文件 → 校验 → 原子替换，消费前还要再验一遍，
「文件存在」不等于「文件可用」。

**带透明的段**（透明静帧、ProRes 4444 / HEVC 带透明的视频）：两条管线按文件里的预乘 / 直通标记用同一种约定 —— 预览给预乘的源
（直通的换预乘副本）并垫黑底，导出在预乘的画面上裁切缩放、叠之前反预乘。规矩只在 [定格 / 静帧管线](freeze-frame.md) 第 4a3 节写全。

**往合成轨上接东西的两条规矩**（`CompositionTime`，2026-09-27）：合成器（和声音场景的余音载体）把素材、
空白、定格接到合成轨上时，① **只往合成轨真正的末尾后面接**，不信 Double 算出来的游标 —— `insertTimeRange` /
`insertEmptyTimeRange` 是插入，落点早于末尾就把已有内容挤走、而且不报错；秒换 1/600 秒的格子用的
`CMTime(seconds:)` 会截断，5.3 + 1.4 = 6.699999999999999 落在前一格，拿它当落点就插进了上一段里面；
② 合成完**每条合成轨裁到时间线总长** —— 视频合成的指令只铺到总长，哪条轨多一格，合成就判无效，预览只剩
黑底（叠层照样画在上面）。**换格子照旧截断，别改成四舍五入**：截断保证从素材里取的范围不超出素材本身；
改成四舍五入的那一版在 CI（macOS 15）上把声音渐变自检卡死过（原因没找到）。
案例：[加了音效预览整个黑屏](../bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md)，
回归在 `scripts/check-preview-composition.sh` 的 `AppendOnly.swift`。

**切片表按格子铺、接缝的零头不算空隙**（`CompositionSlices` / `TimelineState.mainGapTolerance`，2026-09-29）：
③ 视频合成的指令表先把每个切片边界落到 1/600 秒的格子上（同一个截断），**按格子去重**，相邻两格之间一片 ——
以前按秒去重（差不到 0.5 毫秒的片不切），两个边界各自截断落在相邻两格，指令表就空出一格，整个视频合成判无效、
预览从头黑到尾；求值照旧用边界本身的秒（关键帧、渐变的半程都是精确的折点）。④ 主轨上两段之间不到 0.01 秒的
空隙不算空隙：成片的分节不补黑场，预览把后一段接在前一段真正的末尾上 —— 两条管线读同一个常量；否则各自截断
之后 A/B 两条轨之间空出一格，24 fps 的一帧正好落在里面，接缝上一帧黑而成片没有。AI 按报出来的三位小数放段
（19.96 对 19.9598）、变速后的零头都会撞上。案例：[叠化 + 关键帧之后预览全黑](../bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md)，
回归在 `scripts/check-preview-composition.sh` 的 `SliceTicks.swift`，接线在 `checks/transition-handles-wiring.sh`。

**叠化 × Transform 的合成模型**：转场语义上作用在**压平到黑底之后**的段上
（导出就是这么做的：先合黑底再 xfade）。预览的叠化按接缝分两条路径，判定
用 `coversCanvasOpaquely(canvas:isOverlay:)`：

- 两侧都**盖满画布且不透明**（仅翻转、放大出画布都算满足）→ 「后段垫底、
  前段淡出」，逐像素精确等于 dissolve，全程不变暗；
- 任一侧盖不满或半透明 → 后段改为全程线性淡入（从黑亮起）贴合压平模型，
  残余近似是中点亮度轻微下凹（默认合成器层叠乘法所致，最坏 25%）。

判定条件必须贴着数学前提（盖满 + 不透明）写，别拿 `hasVisualTransform`
这类粗粒度标志凑 —— 仅翻转被误送进近似路径就是白闪变暗。回归靠
`scripts/check-preview-composition.sh` 真取帧量像素守着。

**压黑 / 闪白（2026-10-14 起，[案例](../bugfixes/2026-10-14-look-transitions-differ-from-export.md)）**：成片是 xfade 的
fadeblack / fadewhite —— `dst = mix(mix(a, c, ss(0.8,1,P)), mix(c, b, ss(0.2,1,P)), P)`（`P` 从 1 走到 0，`c` 黑 / 白；
用仓库的 ffmpeg 实测核过，差 ≤ 0.004）。不是「前半灭、后半亮」：出场段在头 20% 就没了，颜色在 20% 左右最满，进场段之后
慢慢亮起来。预览拿三层叠出来：出场段 `α = P·ss(0.8,1,P)` 在上、进场段 `β = (1−P)(1−ss(0.2,1,P))/(1−α)` 在中、颜色底在下，
`α·a + (1−α)(β·b + (1−β)·c)` 逐像素等于成片（`XfadeColorCurve`、`CompositionFade.xfadeColor`）。曲线不是直线，窗口里**按帧切片**
（`CompositionSlices.frameTimes`，工程帧的格子），每片两端取值。前提同叠化：两侧都盖满画布且不透明；不满足时退回半程模型（近似）。
**闪白垫白底**：接缝那段时间在两段底下垫一层白（`BlackBaseVideoFactory.whiteVideoURL`，`Int.min + 1` 层：黑底之上、画面之下）。
以前只有黑底，闪白在预览和 AI 的 look 里成了黑场。

**推移 / 擦除转场（2026-08-23 起，`ClipTransition` 三族）**：转场语义仍然
作用在「压平到黑底之后」的段上。接缝分派集中在 CompositionBuilder 的
「主轨接缝的转场分派」后处理（要等两侧的 fitted transform 都算完才判得了
前提，别搬回主轨循环里）：

- **推移族**（pushLeft/Right/Up/Down → xfade slideleft/…）：两段各挂平移
  斜坡（出场滑出、进场从对面滑进），并把裁切收进「静止时的画布」——
  压平模型里滑出画布的内容不会被滑回来看见，不裁的话放大出画布的段一滑
  就穿帮。前提：两侧变换**轴对齐可逆**（90° 的 preferredTransform、翻转、
  缩放、半透明、盖不满都行；任意角旋转、旋转关键帧、要逐帧渲的预设入 / 出场动画不行）。
  满足时逐像素等于「压平再整幅滑动」。**位置 / 大小 / 不透明度的关键帧段也走精确路径**（2026-10-14 起）：
  画布裁切每一片按那一刻（不含推移平移）的摆放算（`cropRectangle`），推移窗口里按帧切 —— 以前一律回退成双向淡变，
  跟拍铺满的竖屏片子每段都带位置关键帧，pushUp 在预览和 look 里就像叠化，成片却是滑动。
- **擦除族**（wipeLeft/… → xfade wipeleft/…）：只给**出场段**挂线性缩小的
  `setCropRectangleRamp` 窗口（∩ 用户裁切；求交的 min/max 在移动边扫过
  用户裁切边处各有一个折点，必须进切片表）。进场段整幅垫底、**无任何
  前提**：窗口外露出的就是进场段 + 黑底，天然贴合压平模型。出场段前提：
  满幅不透明（`coversCanvasOpaquely`）+ 轴对齐。
- 前提不满足 → 回退成叠化的「双向线性淡变」近似路径。
- **方向语义是实测合同**：pushLeft/wipeLeft 的进场段从**右**边进来（画面
  内容 / 擦除边向左运动），与 xfade 的 slide/wipe 逐向实测一致，写死在
  `ClipTransition.motion` / `wipeRemainingRect` 里。改方向前先用纯色素材
  跑一遍 xfade 确认，预览与导出必须同向。
- 回归：`scripts/check-preview-composition.sh` 的推移/擦除组（`checks/PreviewComposition/TransitionLook.swift`）—— 方向探针、
  「两色探针」（分辨擦除露出自己的另半边 vs 推移滑进另半边，纯色素材下
  两者长得一样）、旋转段回退、带关键帧的段真滑动且画布外那一截不滑进来（P6–P7）、压黑 / 闪白逐帧对 xfade 的公式、
  盖不满的闪白露出白底（X1–X3）；`scripts/check-export-frame-rate.sh` 逐种
  转场真跑生产 `plan()` + ffmpeg（xfadeName 拼错在滤镜图配置期就 EINVAL）。

转场选择器（`VideoEditTransitionPicker.swift`）的卡片小样是 SwiftUI 的示意
动画，不走合成器；悬停演示的几何直接复用 `ClipTransition.motion` /
`wipeRemainingRect`，跟合成模型同源。

## 交互层（ClipTransformCanvas / ResizableFrameBox）

- 把手手势一律 `DragGesture(coordinateSpace: .global)` + 手势开始抓
  `startRect` 重放绝对增量 —— 把手挂在框边上，手势一生效框就动，`.local`
  就是反馈回路（同 [timeline-drag-gestures](timeline-drag-gestures.md) 的裁切把手教训）。
- 角把手等比（增量大的方向定 scale）、边把手单边自由拉伸、框内拖动移动。
- 拖动过程只写 `state`（`livePlace` → liveApply），**不重建合成**；松手
  `endLiveEdit()` 才重建 —— 所以拖动中画面不动、框动，松手后画面跟上（~0.3s）。
- 形状复用 `ResizableFrameBox`（movable=false，移动仍走形状自己的手势）：
  线条只给左右把手，正方形只给四角，长方形全套。
- 命中测试从最上层往下：画中画行号大的在上，主轨垫底；形状叠层在
  ClipTransformCanvas 之上，形状点击天然优先。
- 中心对齐（`CenterSnap` / `CenterGuideLines`）：移动接近画布正中时吸附并亮
  黄色横/竖参考线，缩放只在恰好对中时亮线不吸（吸中心会拽歪锚在对角的
  手感）。剪辑变换框和形状拖动共用同一套，别各写一份阈值。

## 工程文件

`placement` 走手写宽容解码（`decodeIfPresent`，nil 兜底），
`checks/ProjectFile/main.swift` 里有存取往返检查。**分割等"从旧段构造新段"
的代码必须把 `placement` 带上**（同 `stillImageURL` 的教训）。
