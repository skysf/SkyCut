# 2026-11-11 系统深色时按钮提示是深底深字，看不清

## 症状

用户报：macOS 系统设成深色时，鼠标停在 SkyCut 的按钮上弹出的提示（例如空工程首页「添加素材…」下面的
「把视频、音频或图片加到时间线」）是深灰底、深色字，几乎看不见，提示外面还有一圈黑底白边；系统设成浅色时一切正常
（浅底深字）。主窗口本身两种系统外观下都是森林色的暖白，只有提示不对。

量出来（见下「验证」）：系统深色 + 森林色时这条提示的对比度是 **1.17:1**，系统浅色时是 13.55:1。

## 根因

- **森林色固定浅色、字也定死了。** 森林色（2026-11-05 起的默认主题，`8c1810d`）在每个呈现根上挂
  `.preferredColorScheme(.light)`，同时把字定成森林色的深墨色 `#19221d`（`AppThemeModifier` 的
  `.foregroundStyle(palette.text)`，提示里的 `.primary` 解析成它）。
- **`.preferredColorScheme` 只改得了「宿主视图就是 contentView」的那个窗口。** 它不是直接改视图，而是往上传的偏好，
  由宿主去改窗口的外观。2026-11-11 的探针（只把探针进程的 `NSApp.appearance` 设成深色，不碰系统设置）：
  - 录屏控制条那种（titled `NSPanel`，`contentView = NSHostingView`）、工程窗口那种（`NSWindow`，`contentView = NSHostingView`，
    带 `sceneBridgingOptions`）：系统深色 + 森林色时窗口外观被 SwiftUI 改成 aqua（浅色）。
  - 提示面板那种（宿主垫在一层普通 `NSView` 下）：窗口的 `appearance` 一直是 nil，跟着系统走，是 darkAqua。
- **提示面板的宿主必须垫一层 NSView。** 那一层是 2026-08-12 为「提示弹在很远的地方」加的
  （[即时提示](../architecture/instant-tooltips.md)第五节第 4 条：宿主直接当 contentView 会把尺寸约束灌成窗口的
  `contentMinSize`），不能去掉；它顺带把 `.preferredColorScheme` 挡在了面板外面。
- 合起来：系统深色时，`.regularMaterial` 按面板的深色外观画成深灰，字却被主题定成深墨色 → 深底深字。黑底白边是深色外观下
  窗口服务器给面板画的阴影和描边，同一个原因。
- **为什么上线时没发现。** 只有「森林色 + 系统深色」这一种组合坏：系统浅色时面板跟系统也是浅色；经典色本来就跟系统，
  字是动态的 labelColor。主题上线时的人工清单（[界面主题](../architecture/app-themes.md)「经典色在系统深色下仍可读，
  森林色保持浅色」）看的是窗口，提示只在鼠标停住时才出现，没人划过按钮。
- **这件事其实早就有人知道。** 声音库的离屏渲染工具（`checks/VoiceLibraryUI/Render.swift`）给自建的窗口手动设了 aqua，
  注释写着「真 App 里 sheet 的浅 / 深外观由 `.preferredColorScheme` 给；自建的窗口够不着它」—— 绕路写在了测试工具里，
  生产代码里同样够不着的提示面板没跟着改。

## 修复

- **浅 / 深的规矩只留一处**：`AppThemePalette.colorScheme`（森林色 `.light`，经典色 nil = 跟系统）；`AppThemeModifier` 的
  `.preferredColorScheme` 改读它。同一条规矩给 AppKit 的换算：`AppThemePalette.windowAppearance`（`.light` → aqua，nil → nil）。
- **提示面板自己设外观**：`InstantTooltipController.show` 每次弹之前
  `panel.appearance = AppThemePalette.current.windowAppearance`。每次都按此刻的主题，切了主题下一次就对；经典色设的是 nil，
  和以前一样跟系统。
- 录屏控制条、工程窗口不用改：宿主就是 contentView，SwiftUI 自己改得到（探针结果见上）。面板的那层普通 NSView 照旧保留。

## 验证

**探针**（scratchpad，不入库）：只把探针进程设成深 / 浅色，走生产的 `InstantTooltipController.show`，按窗口号
`screencapture -l` 拍面板，量文字和底的对比度（WCAG；底 = 中位亮度，字 = 偏离底最远的那一端 1%）：

| 系统 + 主题 | 修前 | 修后 |
| --- | ---: | ---: |
| 深色 + 森林色（用户报的） | 1.17:1 | 13.55:1 |
| 浅色 + 森林色 | 13.55:1 | 13.55:1 |
| 深色 + 经典色 | 11.82:1 | 11.82:1 |
| 浅色 + 经典色 | 6.70:1 | 6.70:1 |

修后「深色 + 森林色」和「浅色 + 森林色」逐项一样：系统是什么外观，森林色的提示都是同一张浅色的。

**自检与反向验证**：

- `scripts/check-instant-tooltip-panel.sh` 第 5 段（要图形会话，不在 check-all）：系统深 / 浅 × 森林 / 经典四种，量面板最终的
  外观。修前 18 项红 1 项（深色 + 森林色：面板是 darkAqua，期望 aqua），修后全过。切主题时主题 Store 不写偏好（脚本开着
  PerfCounters）。
- `checks/app-theme-wiring.sh`（扫描守卫，进 check-all）：宿主视图 `addSubview` 进别的视图的文件，必须设
  `.appearance = AppThemePalette.current.windowAppearance`；`.preferredColorScheme` 读 `palette.colorScheme`。修前红在
  `InstantTooltip.swift`，修后绿。
- `scripts/check-app-theme.sh`：森林色 `.light` / aqua，经典色 nil / nil。把 `colorScheme` 临时改成永远 nil，红两条；改回来绿。
- 鼠标真放上去这一段 `.onHover` 合成不了（[即时提示](../architecture/instant-tooltips.md)第八节），实机清单加了一条，发版前过。

## 教训 / 防回归

- **`.preferredColorScheme` 是偏好，不是外观**：它只改得了宿主视图就是 contentView 的那个窗口。自建窗口里宿主垫在别的视图下时，
  窗口的浅 / 深要按 `AppThemePalette.windowAppearance` 自己设。长期约束写进 [界面主题](../architecture/app-themes.md)
  「AppKit 自建的窗口」和 [即时提示](../architecture/instant-tooltips.md)第五节第 6 条。
- **字的颜色定死了，背景就要和它同一个外观来源。** 主题定了字色而背景还是系统材质 / 系统控件时，只换一边就是深底深字。
- **测试工具里的绕路，多半就是生产代码里的 bug。** 渲染工具早就写明「自建的窗口够不着」，看到这种注释要回头查生产代码里
  同样的窗口。
- **只在悬停时出现的界面，要单列进主题 / 外观的人工清单**（这次加进了两份清单）。
