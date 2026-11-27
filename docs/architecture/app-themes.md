# 界面主题：森林色与经典色

2026-11-05 用户先确认本地 mockup，再授权实施：官网同款暖白 / 森林绿为新增的
**森林色（默认）**，保留已有配色并命名为**经典色**。入口在「设置 → 通用 → 界面」，
主题选择紧跟语言。界面布局、素材的内容颜色与工程格式不随主题改变。

## 偏好与呈现根

- `AppTheme` 稳定身份是 `forest` / `classic`；没有值或坏值回退 `forest`。
- `AppThemePreference` 只写 `SrtFlow.ui.theme.v1`。全 App 一份，不进工程文件、
  不进撤销栈。`AppThemeStore` 是唯一现值，设置窗口和 MCP 共用。
- 森林色保持用户确认的浅色外观；经典色保留系统浅 / 深外观及原来的强调色。浅 / 深的规矩只有
  `AppThemePalette.colorScheme` 一条（森林色 `.light`，经典色 nil = 跟系统），呈现根的 `.preferredColorScheme` 读它。
- **交给 SwiftUI 的永远是明确的 `.light` / `.dark`，不交 nil**：呈现根交
  `palette.resolvedColorScheme(system: SystemColorScheme.shared.value)`，经典色换成系统此刻的浅 / 深。交过 `.light` 再交 nil，
  SwiftUI 只把窗口外观还给系统、不撤掉内容里的浅色（系统深色时森林色 → 经典色：主窗口、工程窗口、录屏控制条窗框深、内容浅，
  sheet / popover 整个停在浅色，[案例](../bugfixes/2026-11-11-theme-switch-leaves-windows-half-light.md)）。
  `SystemColorScheme` 读 `NSApp.effectiveAppearance`、KVO 跟着系统切深浅色，只在经典色时才建；所以 **SkyCut 不设
  `NSApp.appearance`**，全仓也只有呈现根这一处 `.preferredColorScheme`（`checks/app-theme-wiring.sh` 钉着）。
- **AppKit 自建的窗口**：`.preferredColorScheme` 是往上传的偏好，只改得了宿主视图（`NSHostingView`）**就是
  contentView** 的那个窗口 —— 录屏控制条、工程窗口都是这样，SwiftUI 自己改得到。宿主垫在别的视图下的（提示面板，
  [即时提示](instant-tooltips.md)第五节第 4、6 条）够不着，要自己设
  `window.appearance = AppThemePalette.current.windowAppearance`（由 `colorScheme` 换算）。不设的话系统深色时
  材质 / 原生控件画成深色，而字是森林色定死的深墨色：深底深字
  （[案例](../bugfixes/2026-11-11-tooltip-dark-on-dark-in-forest-theme.md)）。`checks/app-theme-wiring.sh` 钉着嵌套的宿主。
  透明、形状由内容决定的自建面板（提示）还要把宿主的根在 `.appLanguage()` **外面**裁成自己的形状：呈现根会铺主题的
  窗口底色（森林色是整块矩形的暖白），不裁就露出直角、窗口服务器也按矩形画影子 / 描边
  （[即时提示](instant-tooltips.md)第五节第 7 条，[案例](../bugfixes/2026-11-11-tooltip-square-frame-in-forest-theme.md)）。
- `appLanguage()` 是既有的场景、sheet、popover、自建 `NSHostingView` 呈现根入口。
  它组合独立的语言与主题修饰器；主题逻辑不写在语言 Store 里。主题宿主只注入
  控件颜色、背景和外观，不用 `.id` 换树，不读播放器时钟或工程。
- `AppThemePalette.current` 的 Observation 依赖只有主题。`.equatable()` 的块也
  在主题变化时更新；播放、拖动、选中不额外广播主题变化。
- 性能台架使用同一个森林色默认值，偏好 store 为 nil，不读取或覆盖用户选择。

## 界面色与内容色

语义色只在 `AppThemePalette` 一处：森林色主背景 `#F3F0E8`、面板 `#F8F6EF`、
强调色 `#123F32`，与官网对应；预览画面**周围**使用中性色 `#E6E5DF`。
真实画布黑底、素材像素、滤镜 LUT、字幕 / 文字 / 形状的用户颜色不换主题。
音量越界的红色、警告色等仍表达原来的状态。

时间线继续一轨一色，`EditLane.colorIndex` 与补号规则不变。经典色直接复用原来的
`TrackPalette`；森林色的视频为低饱和绿 / 青灰，音频为暖棕 / 鼠尾草 / 橄榄色，
字幕两条仍可分辨。标签用深色、波形用深绿。切主题不重排或改写轨道色号。
不能按当前行号或素材内容猜「音乐 / 音效」另分颜色。

两套主题共用工具图标：磁吸为原生 Shape 画的马蹄磁铁（最低系统没有 `magnet`
SF Symbol），自动吸附用 `arrow.right.and.line.vertical.and.arrow.left`，播放跟随
用 `play.square`。图标表达动作，颜色表达开关状态；开关记忆与行为不改。

## On / off at a glance (since 2026-11-27)

The user, 2026-11-27, on the toolbar toggles: 「这几个button，到底是选中了，还是没有，UI没有反应，都是一个样子」 ([case](../bugfixes/2026-11-27-on-off-invisible-in-forest.md)).
They picked look A, the light chip, for Forest; Classic does not change (one approved exception below).

- **One shared look** (`Sources/SrtFlow/StateMarks.swift`). An icon toggle goes through `.stateToggle(classicTint:)`: in
  Forest the icon is the accent #123F32 on the light green chip `onChip` #CFE0C8 when on, the secondary grey #676D62 with
  no chip when off (padding either way, so nothing moves; the label is at least 18 × 16 pt, so the chip and the click
  target are at least 24 × 20 pt); in Classic it is exactly what the control drew before (AppKit's button toggle, its teal
  `toggleAccent` or the root's tint). VoiceOver gets one "toggle button" per control with its on / off value and the chip's
  frame (no accessibility representation: that made an image plus an unnamed switch); every toggle has a name
  (`.accessibilityLabel`). The text of a current or selected thing (`.chipText(_:normal:semibold:)`: the current subtitle
  line and its number, a selected filter / transition card's title) is the accent on the same chip in Forest, drawn
  around the text so it takes no width from it; the macOS accent in Classic. Users: the timeline toolbar's magnet /
  snapping / linkage / follow playhead, the inspector's Flip, both subtitle lists' follow playback, `CurrentCueHighlight`,
  the edit page's cue number, the library cards' titles.
- **Count-neutral** ([预览性能 ratchet](preview-perf-ratchet.md)): `stateToggle`, `chipText` and the other marks are plain
  functions, no ViewModifier type, and `ForestStateToggleStyle.makeBody` counts nothing (it re-runs on every evaluation of
  the view holding the toggle). The bench's paths count what they counted before (review FBG1, measured with its probe).
  The Burn In page's follow toggle is its own small view (`BurnInFollowToggle`): the panel's body runs on every clock tick,
  the toggle doesn't.
- **Numbers never wrap or truncate** (`SubtitleIndexColumn`): the edit page's number column is sized by a hidden template of
  the list's largest number (formatted as the numbers are, "#9,999"), never narrower than its old 24 pt; the Burn In
  table's "#" column is 30 pt as before and wider when the largest number (semibold, with Forest's chip) wouldn't fit.
- **One "on" chip**: `onChip`. The workbench's Library and Subtitles buttons show their panel with it (`.workbenchChip(isOn:)`)
  in both themes — the Subtitles button's chip is the only Classic change the user approved; Classic's chip is the one the
  Library button always had. `selectionFill` stays for selected rows (Settings, the voice picker).
- **Selected**: a selected row of the edit page's subtitle list is outlined in the accent in Forest (`rowSelectionStroke`;
  a light fill would melt into the current line's chip on a row that is both) and keeps the macOS accent at 18 % in
  Classic (`rowSelectionFill`). Every timeline block outlines a selection with `selectionStroke` (Classic white).
- **No `Color.accentColor` outside `AppThemePalette`.** The theme root's `.accentColor(_:)` doesn't reach it, so in Forest
  it is the macOS accent (yellow / blue…). Selected, current and drop-target marks use `highlight` (Forest: the accent;
  Classic: `Color.accentColor` itself, so Classic stays as it was). Marks over the video (the text frame box, the Burn In
  margin guides) must read on any picture: `overVideo` is white in Forest in a dark casing 1 pt beyond each side
  (`overVideoCasing`, `.overVideoCasing` / `.overVideoOutlineCasing`; the clip transform box gets the same casing in Forest),
  dark inside hollow handles and behind the white numbers; Classic keeps the macOS accent and no casing.
- **Selected marks on dark content**: a selected transition cap in Forest is the on chip with the accent's ring and icon
  (`selectedCapFill`, `selectedCapIcon`), a selected card's title is on the chip, a selected shape block has a light inner
  line inside its dark outline (`selectionInnerStroke`), so a selection shows on black footage, a black thumbnail or a black
  shape. Classic: as before.
- **The rule** (`scripts/check-app-theme.sh`, `checks/AppTheme/StateRuleChecks.swift`, measured on the palette's own values):
  two states tell apart when their mark (icon or text colour) differs by CIEDE2000 ≥ 20, or their area (chip, row fill,
  outline, against what is behind it) by ≥ 10; a current line's text keeps WCAG contrast ≥ 3 on its own background. The
  old Forest toggles (#123F32 on / #19221D off, no chip: mark 13.4, area 0) and the old current line (accent against the
  primary text, no chip: mark 18) fail it; look A passes (mark 21.7, chip 12.3); Classic passes with its teal (24 dark,
  50 light) and the default blue accent. `selectionFill` alone (ΔE 6.8 on the panel) is why a selected cue row is outlined.
  A toggle must show its chip (area ≥ 10), not only the icon colour. Over the video, on #FFFFFF and on #000000: the casing
  and the white line each keep contrast ≥ 3 against what is behind them (a white line alone on white is 1 : 1). On dark
  content: the selected cap's chip and a dark shape's inner line keep ΔE ≥ 10 (a dark ring alone melts into black).
  `checks/AppTheme/StateViewChecks.swift` lays out #9 … #9999, current or not, in both themes (one line, the column fits,
  every row's column equally wide) and reads the VoiceOver tree of two Forest toggles (two named toggle buttons with their
  values, no image or switch, the chip's frame).
  `checks/app-theme-wiring.sh` keeps raw `.toggleStyle(.button)` (allowlist: the Upscale compare's bordered Loop, whose
  bezel shows the state; also `ButtonToggleStyle()`), `toggleAccent` tints, the macOS accent in any spelling
  (`Color.accentColor`, `controlAccentColor`; allowlist: `ScreenRecordingRegionPanel`, which draws over the user's whole
  screen outside SkyCut's themed windows as macOS's own screenshot selection does) and a hand-made toggle in the accent
  against the text colour out of the views; pins the shared looks' colours, the VoiceOver names, the casings, the cap's chip
  and the shape's inner line; and keeps StateMarks.swift free of accessibility representations and counted bodies.
- **Offscreen renders can't show AppKit's toggle state**: a window of an app that isn't active draws AppKit controls as
  inactive, so Classic's teal "on" never appears in them (both themes looked "off" there before the fix). Forest's look is
  drawn by SwiftUI and renders exactly. Judge AppKit's states in a real window (manual items below).

## MCP

`get_settings section=general` 返回 `theme`、`default_theme`、`available_themes`。
`set_settings theme=forest|classic` 与原生选择器共用 Store，全验完再写任何偏好。
与权限 / 额度一起改时，原来的批准要求仍先执行，不能先改主题再等待批准。
不触碰工程、激活窗口、重建媒体或中断播放。

## 验证

`scripts/check-app-theme.sh` 验证默认 / 坏值、持久化、脚本隔离、原配色精确保留、
稳定色号、浅 / 深的规矩与 SF Symbols。`checks/app-theme-wiring.sh` 检查生产接线（含自建窗口里嵌套的宿主要设外观）。
`scripts/check-instant-tooltip-panel.sh`（要图形会话）量提示面板在系统深 / 浅 × 两套主题下最终的外观、气泡外面四个角透不透明。
`scripts/check-theme-switch.sh`（要图形会话）开着主窗口、工程窗口、录屏控制条、sheet、popover、提示六种宿主，切主题、模拟系统切
深浅色共八步，每步量窗框、SwiftUI 读到的浅 / 深、画出来的底色三样都和新主题一致。三张字符串表、
呈现根、源文件清单及性能接线照原守卫检查。独立 Sky Studio 设置冒烟同时验证
主题发现、修改、错误的原子性与持久化，不使用正式账号或缓存。
`scripts/gui-smoke/sky-studio/themes.py` 在同一 MCP 会话里持有两个装入素材的工程，
来回切四次主题，逐次比对时间线内容、颜色字段、身份与几何，不能重连后拿旧工程
id 冒充当前会话的工程（保护租约会正确拒绝）。

修改主题后、发版前用真实窗口检查：

- [ ] 新设置域默认森林色；语言下方有主题选择，三种界面语言齐全。
- [ ] 来回切主题，主窗口、另一个工程窗口、设置及新开的导出 / 字幕浮层同步；
  经典色在系统深色下仍可读，森林色保持浅色。
- [ ] 系统深色 + 森林色：鼠标停在按钮上，提示是浅底深字（和系统浅色时一样）；录屏控制条也是浅色。
  只在悬停 / 录制时才出现的界面要专门划过去看，只看窗口看不出来。
- [ ] 两套主题 × 系统深 / 浅：提示是圆角的气泡，外面没有直角的方框（森林色以前有一圈）。
- [ ] 系统深色、开着工程窗口和一个 sheet（比如导出面板）时从森林色切到经典色：主窗口、工程窗口、sheet 立刻整个变深（窗框和内容一起）；
  经典色下在系统设置里切浅 / 深，开着的窗口和 sheet 跟着变；切回森林色全部是浅色。系统设置里的切换自动化够不着，只能实机过。
- [ ] 播放中切换后继续播放，播放头、选择、窗口位置、缩放与撤销历史不变。
- [ ] 主轨 / 上层轨 / 音频 / 两条字幕 / 文字 / 滤镜都可分辨，空轨色条和块对应，
  标签、选中框、标尺、波形在两套颜色里清楚。
- [ ] 素材、黑场、用户的文字 / 形状颜色、导出参数不变；重启保留主题选择。
- [ ] MCP 与原生选择器双向同步，坏参数不会造成半次主题更新。
- [ ] On / off at a glance, in real windows, Forest and Classic (system light and dark): the timeline toolbar's magnet,
  snapping, linkage and follow playhead, the inspector's Flip, both subtitle lists' follow playback and the workbench's
  Library and Subtitles buttons each look different on and off without hovering; the current subtitle line and a selected
  row tell apart, and a row that is both shows both.
- [ ] Classic: the toggles' teal "on" tint shows in a real, active window (offscreen renders can't show it).
- [ ] VoiceOver (both themes): each toolbar, Flip and follow-playback toggle reads its name and on / off, once.
- [ ] Forest with a non-default system accent (e.g. yellow): no Forest control turns that colour (cards, the transition cap,
  drop targets, the cloud tasks' current project); over a bright and a dark picture the text frame box and the Burn In
  margin guides stay readable.
