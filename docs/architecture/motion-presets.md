# 动效预设：一套现成的字 + 形状 + 动画，落在某一下上

> 2026-11-16 起（研究清单 MCP-45 入口 + MCP-46 / 47 / 53 三套）。改 `MotionPreset*.swift`、`AIMotionPresetEdit.swift`、
> 检查器「动画」区的「预设」（`VideoEditInspector+MotionPreset.swift`）、加字的「动效预设」一栏（`MotionPresetPanel.swift`），
> 或者改文字 / 形状的模型、`VideoEditProject.updateTextOverlay` 之前必读。相关：[画面文字](text-overlays.md)、
> [画面上的形状](shapes.md)、[AI 接口（MCP）](ai-control-mcp.md)。

## 一、是什么

用户看了南极预告片的 8 套片头字 / 片名动效样片（2026-11-16）：「这些不用剪辑」，要把它们**做进 SkyCut：AI 能一句话调用，
用户也能在软件里自己选**。8 套里 3 套 SkyCut 现成的字和形状动画就拼得出来，只差一个入口，这次做入口和这 3 套：

| 预设（AI 用的名字） | 样子 | 拼的是 |
| --- | --- | --- |
| 框住再放开（`frame_reveal`） | 细框从左上角顺时针画出来框住名字，到「放开」那一下倒着收回去，字留下；上面一行小字（FROM）在框里，下面一行小字（PRESENTS）压在「放开」那一下出来 | 长方形：入场、出场都是「画出来」；标题：擦除进、淡出；小字：淡入淡出 |
| 对焦出字（`focus_pull`） | 细字、字距拉宽，从虚收清进来，出的时候继续推近、虚掉 | 标题和小字：入场、出场都是「对焦」 |
| 标题 + 滚动的数字（`title_counter`） | 标题弹出来，下面一条细线画出来，数字像老虎机滚到一个数（带单位、千分位） | 标题：弹性缩放；线条：画出来；数字元件：老虎机，等 0.5 秒、滚 1.2 秒 |

另外 5 套（字在前景后面、形状变形、沿画面里的东西描边、两个词撞到一起、从裂缝里露出来）要底层能力（透明视频 MCP-56、
抠前景 MCP-55……），排在后面。

入口（名字和位置 2026-11-16 用户定的）：

- **加字时多一栏「动效预设」**：剪辑页「+」→「动效预设…」弹出一栏，三张卡带小样（停着是最好看的那一刻，鼠标放上去循环播一遍），
  点一张就在播放头放一套，选中标题、浮出就地编辑（占位字起手全选，直接打字换掉）。
- **选中字后，检查器「动画」区最上面一个「预设」**：换一套，字不变；选「无」拆成普通的字和形状。这段字在一套里时多一行「落点」：
  改它整套一起挪。
- **AI**：`set_text` 的 `motion_preset`、`hit_at`、`small_text`、`small_text_below`（`text` 是标题，`number` 给标题 + 数字用；
  位置、字体、颜色用 set_text 原来的参数）。不另开工具：一套的主体就是一段标题字，另开一个长得像的工具违反
  [AI 接口](ai-control-mcp.md)第一节第 5 条；参数定义仍在 4,500 字节以内。怎么用写在说明书 `skycut_guide topic=set_text` 的
  `motion_presets` 一节。

## 二、只能这样做

The numbered rules here and sections 3–6 describe the native text/shape designs. Web entries use the shared library and UI in sections 7–8, with the locked renderer contract.

1. **放上去的就是普通的字和形状。** 一套 = 几段 `TextOverlay` + 几块 `ShapeAnnotation`，样式、动画都在它们自己的字段里，照常能一块一块地改、
   删、藏；预览和成片走现成的同一条绘制路径（`TextRenderer`、`ShapeOutline`），预设只把参数配好，**不另开渲染管线、不另造动画种类**。
   底层真缺能力（字关键帧、形状变形、发光……）就不进这一批，记进研究清单。
2. **规则只有一份**：`MotionPresetGroups`（造、放进时间线、换一套、挪落点、拆开、跟着标题走）。界面（`MotionPresetActions`）和
   AI（`AIMotionPresetEdit`）都只调它，所以「用户在软件里选框住再放开」和「AI 一句话调同一套」做出来一样。每个动作一次 `perform` = 一步撤销；
   AI 照 set_text 的老路一次提交（批量 `set_texts` 每一项也可以是一套）。
3. **组只是一个标记**：`motionPreset = {group, preset, role}`（`MotionPresetTag`，文字和形状都有）。按需写键，**不抬格式版本**：
   旧版读不懂就当普通的字和形状，成片一帧不变，丢的只是「是一组」（同 `rowHeights` 的口径，[工程文件](video-edit-project-file.md)）。
   读不懂的标记（以后多出来的预设 / 角色）当没有，不报错。
4. **落点 = 最早出来的那一块的起点**（框住再放开是框，另两套是标题）；整套的尾 = 最晚收走的那一块。挪落点 = 每一块平移同样多，
   各自改过的长短、动画不动；挪过去撞上同一行别的字往上找空行（同拖文字换行）。
5. **标题是锚**。标题挪了（预览上拖、检查器、AI 的 x / y）：同一套别的几块平移同样多，各自的微调留着。标题改了字、字号、字体、字距
   （框住再放开里上面那行小字也算）：按标题重新排一遍 —— 框跟着字变大变小、小字和数字贴回去。所有改字的入口都经
   `MotionPresetGroups.update`：`VideoEditProject.updateTextOverlay` / `liveUpdateTextOverlay`（检查器、就地编辑、预览上拖 / 缩放）和
   AI 的 set_text。别的几块自己挪、自己改，不牵动谁。字和形状的选择互斥，所以在画面上整套挪就拖标题；时间线上拖一块只挪它自己，
   整套挪用「落点」。
6. **按短边设计**：预设的数是「短边 1080」上的像素（`MotionPresetDesign`），横屏的短边是高、竖屏是宽 —— 同一套在 9:16 上占画面宽的比例和在
   16:9 上占高的比例一样；存进模型时按画布高换算（`MotionPresetLayout.modelSize`）。一行字太宽先收字号（最多占画面宽的 86%），
   收到 60% 还放不下才让它折行。AI 自己给了 `font_size` 的照给的，不收。
7. **按墨迹量、按墨迹摆**（每个字形用它自己的字体量 `CTFontGetBoundingRectsForGlyphs`），不按版面框：版面框的宽是折行宽度（画面的 80%），
   `TextLayout.inkBounds` 也是行框，拿它们排的框和间距比看起来的大一圈。框的描边全在框内，所以框再让出半个线宽。
8. **换一套**：标题沿用原来那段字的 id（AI 手里的 `text_id` 不失效、选中不丢）；字、小字、数字、落点、总长、整套的中心、用户自己换过的
   字体和颜色留着；旧的几块拿掉，按新的一套重新造。一段普通的字也能直接变成一套（它的字当标题、起点当落点、时长当总长）。
9. **粘贴 / 复制**（⌘V、AI 的 `duplicate_items`）：同一组在这一批里至少两块换成同一个新组号，粘出来的一套自成一组；只拿到一块的不留标记
   （同链接组，`MotionPresetTag.renew`，在 `TimelinePaste.apply` 里）。
10. **字体**：用户没有品牌字体，默认用这台 Mac 自带的 Avenir Next、DIN Alternate 一路（存字体的全名，Core Text 和字体选择器都认），
    用户可以换；数字那一行不跟着换（老虎机要等宽的数字）。
11. **Preset texts hug their words** (added 2026-11-17): a preset text's wrap width (`boxWidth`) is its longest line plus a small margin
    (`MotionPresetLayout.snugBoxWidth`), because the text wipe sweeps the layout box, not the ink — in the default 0.9-wide box a short
    centred title is wiped in a third of the entrance and looks like a cut. New words or type keep it snug (`MotionPresetGroups.update`),
    unless that edit set the width itself or the width had already been set by hand (then it is no longer snug and stays as it is);
    a `box_width` the AI passes with `motion_preset` stays too. On a canvas change, `OverlayReframe` recognizes the old snug
    width and remeasures it after scaling and clamping the style, so a short title does not wrap just because the frame narrows.
    Ordinary and manually set widths keep their frame fraction; the same edit's explicit sizing is respected. This does not
    rerun `arrange`: each member keeps its normalized centre and manual offsets. See the [canvas wrap case](../bugfixes/2026-11-17-canvas-preset-wrap-width.md).

## 三、三套的数（照样片量的，720p × 1.5）

单位是「短边 1080」上的像素和秒；时间相对落点。改数先改 `MotionPresetDesign`，再看出图（第五节）。

| | 框住再放开 | 对焦出字 | 标题 + 滚动的数字 |
| --- | --- | --- | --- |
| 标题 | Avenir Next 64、字距 22；+0.1 擦除 0.35、结尾淡出 0.25 | 同左；对焦进 0.45、对焦出 0.3、强度 0.4 | Avenir Next Demi Bold 120、字距 26；弹性缩放 0.5（强度 0.8）、淡出 0.4 |
| 小字 | Avenir Next Medium 30、字距 14；上面的 +0.15 淡入；下面的在「放开」那一下淡入 | 上面的和标题一起对焦；下面的在「放开」那一下对焦进来 | — |
| 形状 | 框：线宽 3、比字的墨迹多 40 × 26；画出来 0.4，「放开」时倒着收 0.4 | — | 细线：长 450、线宽 3、离标题 34；+0.35 画出来 0.4 |
| 数字 | — | — | DIN Alternate 60；离细线 42；+0.3 淡入，等 0.5、滚 1.2 |
| 默认总长 / 最短 | 3 / 1.2 秒 | 3 / 1.2 秒 | 3.5 / 2.4 秒 |

「放开」= 总长的一半，至少 0.8 秒、离结尾至少 0.6 秒（样片：1.9 秒的那张 1.1 秒放开，3.2 秒的那张 1.46 秒放开）。
对焦的强度一个旋钮同时管推近和糊的程度：样片从 0.94 倍收到 1、起手糊约字高的五分之一，SkyCut 取 0.4 是折中（从 0.88 倍收到 1、
糊约字高的 9%）。

## 四、守卫

- `scripts/check-mcp.sh` 的 `MotionPresetChecks`（`checks/MCP/MotionPresetChecks.swift`）：词表和 `MotionPresetKind` 对账；三套各自的几块、时间、
  动画；框把标题和上面那行小字框在里面、贴着字、默认居中；9:16 上字号按短边换算、每一行都在画面里；标题 + 数字没给 `number.to` 拒绝、
  不留半套；换一套标题 id 不变、字和颜色留着、旧框没了；`hit_at` 整套挪、长短不变；一段普通的字变成一套；标题改了字框跟着变宽、标题挪了
  框和小字跟着挪、小字自己挪不牵动标题；几种报错（`hit_at` / `small_text` 用在不是一套的字上、加的时候缺 `motion_preset` 或标题、
  不认识的名字）一样都不改；`set_texts` 一项一套；粘贴出来的自成一组、只粘一块的不留标记；存盘往返、普通的字不写键、读不懂的当普通的字。
  Also (2026-11-17): a short title's wrap width hugs it, grows with longer words and keeps them on one line, and a `box_width` set by hand is kept.
- `CanvasPresetChecks` in the same MCP check runs all three native presets through a canvas round trip (16:9 → 9:16 → 16:9 and
  auto 4K → 720 × 1280 → 4K): words stay snug, pixel lengths retain their share of the short side, model values return, and
  identities, centres, timing and animations stay. It also checks typing afterwards, manual widths, the minimum-font clamp and
  `set_canvas` reporting a width-only text change.
- 说明书和清单的上限、名字都真的存在：`GuideChecks` / `GuidePilotChecks` / `CatalogTextChecks`（set_text 的参数定义 ≤ 4,500 字节）。
- 界面：`checks/preview-perf-wiring.sh`（新视图第一行计数）、`checks/presented-views-app-language.sh`（「动效预设」那一栏是 popover，
  套 `.appLanguage()`）、`checks/inspector-live-binding-wiring.sh`（「预设」下拉和「落点」的打字走离散写入）、`checks/inspector-fits-width.sh`、
  `scripts/check-localization-coverage.sh`（三张字符串表）。
- 出图：`scripts/render-motion-presets.sh <输出目录>`（要图形会话，**不在 check-all.sh 里**）：加字的「动效预设」一栏、检查器的「预设」
  （英 / 中 / 西 × 森林色 / 经典色深色），三套各几帧的预览（预览叠层）和成片（真导出抽帧），16:9 和 9:16。用户 2026-11-16 定：
  软件里看得见的新东西，合并前出离屏渲染的图给他看。

## 五、人工回归清单（发版前实机过）

- [ ] 「+」→「动效预设…」：一栏弹在「+」下面，三张卡的小样是三套的样子；鼠标放上去小样从头播一遍；点一张，播放头处放上一套、
      标题浮出输入框、打字直接换掉占位字，框跟着字变宽。⌘Z 一步撤掉整套。
- [ ] 选中标题，检查器「动画」区最上面是「预设」：换成另两套，字、位置、落点不变；选「无」，几块都还在、不再跟着标题走。
- [ ] 「落点」打字 / 箭头 / 横着拖：整套一起挪，⌘Z 一步撤回。
- [ ] 预览上拖标题：框、小字、细线、数字跟着走；拖框或小字只挪它自己。
- [ ] 9:16 工程里放三套：字不出画面、大小和横屏看着一样；中文标题（苹方回退）也好看。
- [ ] 导出一段带三套的片子，逐帧和预览比：一样。
- [ ] ⌘C ⌘V 一整套：粘出来的那套换预设、挪落点不牵动原来那套。
- [ ] 让 AI「在 25.25 那一下放一个框住再放开的 FROM SKY STUDIO」：一次 set_text、一步撤销，和界面上放的一样。

- [ ] Manual before a release: add each native preset with a short title, switch 16:9 → 9:16 → 16:9, and compare preview and export.
  The automatic wrap stays snug, switching back restores the preset, and typing longer words after the switch still grows the
  wrap. A width set by hand keeps its frame fraction.

## 六、还没做的

1. Foreground occlusion and tracing (MCP-48 / MCP-50) still need their own capabilities. MCP-49 / MCP-51 / MCP-52 use the official web templates below.
2. 时间线上拖一块不带整套（整套挪用检查器的「落点」或 AI 的 `hit_at`）；框住再放开里「放开」那一下没有单独的旋钮（跟着总长走，
   要改就拖框那一块的尾巴）。
3. 「落点」不吸附到音乐的重音上（AI 用 `listen` 找到那一下再给 `hit_at`）。

## 7. One library, two kinds (2026-11-17)

`MotionPresetLibrary` is the common ordering for the panel and AI: native text/shape presets first, bundled official web designs next,
then reusable web pages stored in this project. Native presets remain normal editable text/shapes and use `set_text`. A web entry uses `set_motion` and becomes a checked
ProRes 4444 upper-track clip. Its page and parameter form are retained in the project, so the video is a disposable cache rather than
imported media. `get_timeline.motion_library` advertises the entry id and correct tool; a custom page is available for reuse after its
first successful placement. Do not add a competing web-only library or a separate entry point.

Choose the existing native motion first, then a reusable template, and only write a new page when neither fits. New AI-written pages use
the existing two permission modes: ask once in request-approval mode, proceed in full access. Neither mode can relax the page locks.
Parameters, portable caches, local hit alignment, system/font warnings and the six page checks are specified in
[the renderer contract](web-motion-renderer.md#15-stored-motion-and-the-ai-call-mcp-74-2026-11-17). The official web designs are added as
library entries rather than new rendering paths.

## 8. Unified panel and web parameter inspector (2026-11-17)

The existing `+` → Motion Presets popover remains the only entry. `MotionPresetPanel` consumes
`MotionPresetLibrary.entries`: native titles first, official web designs next, then this project's stored web templates. Native cards retain
their existing title/shape action and hit timing. A web card previews its checked movie: an idle poster capped at
272 × 153 pixels, and a muted looping player only while hovered. The bounded poster cache owns no players;
leaving the hovered card tears its player down. No page runs inside the App to draw a thumbnail.

Adding a web card starts it at the captured playhead; dragging chooses a timeline start on an upper video lane.
`WebMotionPresetRequest` captures document generation, start and any existing target lane UUID before creating
a Task. The task rejects another document, resolves a fresh template for the destination canvas/fps, then calls
`WebMotionActions`. The timeline routes the custom payload through its existing single drop destination, via
`TimelineDropRouterFactory`; it does not introduce another `.onDrop`. Preview/commit use the existing shared
media landing rule, and incompatible lower/audio targets lift to upper video lanes.

Selecting a web clip shows `WebMotionInspectorSection`. Text, font, color and number fields come from the stored
form; authored names/labels remain verbatim. Fonts use the existing installed-font browser. Duration and local
hit are separate timing fields, always synchronized with reserved `MOTION_PARAMS.duration` / `hit`.
`WebMotionEditorModel` keeps an uncommitted draft: typing does not edit the timeline or start a render. Re-render
validates the captured document/clip/source lane, runs the locked helper, and updates that same clip in one undo
step while retaining its trim, speed and effects. Failed or stale work retains the preceding movie. Reload Parameters
explicitly discards an old draft. Source OS/font warnings remain visible until the source is re-rendered.

Show Page in Finder prepares the stored HTML and parameter sidecar beside the original movie through queued IO,
then reveals the HTML with Finder. It does not execute the page in a browser or write unapplied draft values.
Page diagnostics remain verbatim; ordinary UI refusals use the current app language. All new buttons use instant
help and the existing theme/language presentation root; inspector rows fit the normal 220-point content width.

`checks/MotionPlacement/Editor.swift` drives the real model/helper, draft isolation, typed fields, timing, trims,
one-step undo, sidecars and stale/document rejection before helper startup. The full A+B fixture passed 197/197;
removing the UI stale/document gates produced 6/197 failures, then exact restoration returned it to green.
`render-motion-presets.sh <output> --web-only` renders the real panel, parameter section, selected-clip inspector
and portability warnings in en/zh-Hans/es with light/dark themes, using an isolated bundle and synthetic source.

Manual regression before a release:

- [ ] Hover each web card, leave it and close the popover: playback stops; idle cards remain still.
- [ ] Add a project template at the playhead, then drag it to an upper lane and a lower/audio row: it stays on upper
      video lanes, the preview matches the committed start, and undo removes one insertion.
- [ ] Drag out and back, cancel outside the timeline and drag again: the placeholder and auto-scroll stop without
      losing the next drop. Native file/filter/audio/transition drops still work through the same destination.
- [ ] Edit all four field kinds in each language; type first, re-render once, then undo. Show Page in Finder reveals
      the stored page/parameters. Switch projects during queued work and retain the newer project unchanged.

## 9. Original official web templates (2026-11-18)

`OfficialWebMotionTemplate` supplies three bundled pages through the same `MotionPresetLibrary`, `set_motion`, add/drop service,
parameter inspector and cache. The source pages are original SkyCut designs; no OpenFilm code or probe renderer is included.

| Template id | Design | Default words / local hit |
| --- | --- | --- |
| `official:box_to_earth` | A title box stretches into a globe, then reveals meridians and parallels | EARTH / 0.6 s |
| `official:word_collision` | Two words approach from opposite sides, with a local flash and moving fragments | NORTH, SOUTH / 0.9 s |
| `official:ice_crack_light` | A jagged seam opens around the title, then its light recedes | THROUGH THE ICE / 0.5 s |

All default to four seconds, Avenir Next and a pale blue colour. Their text, installed font and colour are editable; the collision
adds `second_text`. Duration and local hit use the existing dedicated controls and reserved parameter values, without duplicate
form rows. The collision moves only its two words and fragments: camera/picture shake remains an ordinary SkyCut edit.

The pages draw only from `t`, use CSS short-side geometry, and run only in the locked helper. Canvas pages use output-sized backing
stores; the ice design uses vector SVG. Each placement stores the complete page and parameters, so later bundled edits cannot
silently change an existing project's source. Official code is trusted bundled content; new AI-written code retains its approval rule.

Browsing uses the three small bundled ProRes 4444 previews; opening the library does not render template movies. Each preview has
a generation receipt binding its HTML hash, default parameter object and movie hash to its real six-check renderer result.
`AppResources` locates both source and previews in the installed app and SwiftPM layouts. Ordinary timeline placements still use
project-owned fingerprinted caches, never the browser preview movie as their full-resolution source.

`checks/MotionPlacement/Official.swift` renders each complete default page twice through fresh helpers at 320×180 / 24 fps and
compares every frame hash. It exercises discovery, trusted template requests, parameter changes, project-file round trips,
independent reuse and undo through the real AI path. `OfficialPreviews.swift` verifies the bundled bytes, defaults, six-check receipt
and actual movie size, frame rate, duration and premultiplied alpha. The existing offscreen UI harness covers all three languages
and both themes; recognized official default names/labels follow the UI language while custom names, labels and values remain verbatim.
The timeline clip label and the selected-clip inspector header both use `WebMotionClipName`, whose locale dependency redraws an
already-mounted label after a language switch. This is display-only: `EditClip.name`, the stored web record, and ordinary media names
are not rewritten or translated. `checks/MotionPlacement/ClipNames.swift` compares the same mounted view with the newly localized
reference text and keeps a custom-name view unchanged; the motion wiring guard requires both production consumers.

Manual regression before release:

- [ ] Browse all three official cards, hover and leave each one; idle posters remain visible and players stop on exit.
- [ ] Add every official design on 16:9 and 9:16 canvases, edit its words, font, colour, duration and hit, then undo once.
- [ ] Align the collision's hit to music and confirm that only words/fragments move; the underlying picture remains steady.
- [ ] Compare impact and settled frames in preview/export at normal and 4K output sizes; lines and lettering remain sharp.
- [ ] Add an official design in English, keep it selected and switch to Chinese and Spanish: its timeline label, inspector header
      and parameter heading change together. A custom-renamed web clip and an ordinary media filename remain unchanged.
