# 2026-11-11 系统深色时森林色切经典色，开着的窗口只变一半（窗框深、内容浅）

## 症状

系统设成深色、SkyCut 是森林色时，在「设置 → 通用 → 界面」（或 AI 的 `set_settings theme=classic`）切到经典色：

- 主窗口、工程窗口、录屏控制条：窗框和标题栏变深了，里面的 SwiftUI 内容（材质、文字、控件）还是浅色；
- 开着的 sheet、popover：整个停在浅色，连窗框都不变；
- 之后系统再切一次深浅色，普通窗口会被「捅醒」，sheet、popover 还是不变，要关掉重开。

提示面板没有这个问题（[#388](2026-11-11-tooltip-dark-on-dark-in-forest-theme.md) 起每次弹都按主题自己设外观）。
这件事是修[提示深底深字](2026-11-11-tooltip-dark-on-dark-in-forest-theme.md)时探针顺带撞出来的，用户还没在真机上碰到，
0.18.66 之前修掉。

## 根因

- 呈现根的主题修饰器（`AppThemeModifier`）按主题交 `.preferredColorScheme(palette.colorScheme)`：森林色 `.light`，
  经典色 **nil**（「跟系统」）。
- **交过 `.light` 再交 nil，SwiftUI 不撤掉之前的浅色。** 它只把窗口的 `NSAppearance` 还给系统（所以窗框跟着系统变深），
  内容里的 colorScheme 不重新推导，body 一次都不重算（探针：SwiftUI 读到的一直是 light）。sheet、popover 这两种由
  SwiftUI 弹出来的窗口更彻底：窗口的外观也留在 aqua。之后系统切深浅色时，普通窗口的有效外观变了、内容被带着重算，
  所以「再切一次系统就好了」；sheet、popover 的外观是 SwiftUI 明确设的 aqua，系统怎么切都不动。
- 明确的 `.light` ↔ `.dark` 之间换，SwiftUI 是照常换的（森林色 ↔ 经典色在系统浅色时、或者经典色起步时都看不出问题）。
  只有「交过明确值、又交回 nil」这一种转换坏，所以只在「系统深色 + 从森林色切到经典色」时露出来。
- 为什么上线时没发现：主题上线时的人工清单是「来回切主题……经典色在系统深色下仍可读」，可那时系统是浅色、或者起步就是经典色；
  森林色是默认、经典色是后加的老配色，系统深色下从默认切过去这一条路没人走过。

探针（scratchpad，不入库）：一个 SwiftUI App，同时开着 SwiftUI 场景窗口（主窗口那种）、AppKit 建的窗口里宿主就是
contentView（工程窗口那种）、它弹的 sheet、提示面板，系统的深浅色只在探针进程里模拟（`NSApp.appearance`）：

| 步骤 | 主窗口 / 工程窗口 | sheet | 提示 |
| --- | --- | --- | --- |
| 森林色、系统深色 | 全浅 ✓ | 全浅 ✓ | 浅 ✓ |
| → 经典色、系统深色 | 窗框深、SwiftUI 读到 light、画出来浅 ✗ | 窗框浅、内容浅 ✗ | 深 ✓ |
| 经典色、系统切浅 | 全浅 ✓ | 全浅 ✓ | 浅 ✓ |
| 经典色、系统切回深 | 全深 ✓（被捅醒） | 窗框浅、内容浅 ✗ | 深 ✓ |
| → 森林色 | 全浅 ✓ | 全浅 ✓ | 浅 ✓ |

## 修复

- **永远不交 nil**：`AppThemePalette.resolvedColorScheme(system:)`（换算还是只有 `AppThemePalette` 一处：
  `colorScheme` 是规矩，这里把经典色的 nil 换成系统此刻的那一个），呈现根交
  `.preferredColorScheme(palette.resolvedColorScheme(system: SystemColorScheme.shared.value))`。
  森林色 → 经典色在系统深色时就是明确的 `.light` → `.dark`，SwiftUI 照常换。
- **系统此刻的浅 / 深**：`SystemColorScheme`（`AppThemeAppearance.swift`），读 `NSApp.effectiveAppearance`、KVO 跟着它变
  （用户在系统设置里切深浅色时它会变），变了呈现根重新交、开着的窗口 / sheet / popover 一起换。只在经典色时才读
  （`system:` 是 autoclosure），森林色从不建它、不订阅系统的深浅 —— 默认主题和性能台架什么都不变。
- **SkyCut 不设 `NSApp.appearance`**：`SystemColorScheme` 把它当成系统的。扫描守卫钉着。
- 提示面板照旧按 `windowAppearance` 自己设（经典色 nil = 跟着 `NSApp`，AppKit 的继承没有这个毛病）。
- 考虑过改成主题直接设 `NSApp.appearance`、去掉 `.preferredColorScheme`：森林色时系统的对话框、打开 / 存储面板、菜单也会变成
  浅色，超出这次的范围，#388 的面板外观、测试里模拟系统深浅色的办法也要一起改。没选。

## 验证

- **`scripts/check-theme-switch.sh`**（新，要图形会话，不在 check-all）：一个 SwiftUI App 同时开着六种宿主 —— SwiftUI 场景窗口
  （主窗口）、AppKit 窗口宿主是 contentView（工程窗口）、titled + fullSizeContentView 的 NSPanel（录屏控制条）、sheet、
  popover、生产的提示面板 —— 走八步（森林色 / 系统深 → 经典色 → 系统切浅 → 系统切回深 → 森林色 → 系统切浅 → 系统切回深 →
  再切经典色），每一步每个宿主量三样：窗框的外观、SwiftUI 读到的 colorScheme、离屏渲出来的材质亮度，最多等 2 秒等它一致。
  修后 9 项全过；把呈现根换回 `.preferredColorScheme(palette.colorScheme)`：红 3 项（「→ 经典色」主窗口 / 工程窗口 / 录屏控制条
  内容是浅的、sheet / popover 整个是浅的；「系统切回深」sheet / popover 还是浅的；「再切经典色」同第一条），恢复后全过。
  窗口放在屏幕左下角、完全透明、不吃鼠标（挪到屏幕外不行：挂上 sheet 的窗口会被 AppKit 拉回屏幕里，锚在屏幕外的 popover
  弹不出来）；先挂 sheet 再弹 popover（sheet 挂上时成为 key，会把同时弹的 transient popover 关掉）。
- **`checks/app-theme-wiring.sh`**（扫描守卫，进 check-all）：呈现根交 `resolvedColorScheme(system:)`、`SystemColorScheme`
  观察 `effectiveAppearance`、全仓只有这一处 `.preferredColorScheme`、Sources 里没有设 `NSApp.appearance` 的。反向验证三条：
  换回旧写法、别处再加一个 `.preferredColorScheme(nil)`、`setTheme` 里设 `NSApp.appearance`，各自红；恢复后绿。
- **`scripts/check-app-theme.sh`**（纯值，进 check-all）：森林色在两种系统下都解成 `.light`、经典色解成系统的那一个、森林色
  不求值 `system`；外观换成浅 / 深两档（含 vibrant 和高对比度的深浅色）。
- **够不着的**：真的在系统设置里切深浅色（不能替用户切）。`NSApp.effectiveAppearance` 的 KVO 在系统切换时会通知是 AppKit
  文档写明的；检查里用 `NSApp.appearance` 模拟同一个变化。发版前实机过（[界面主题](../architecture/app-themes.md)人工清单）。

## 教训 / 防回归

- **`.preferredColorScheme` 交过明确值就别再交 nil。** nil 不是「恢复默认」：SwiftUI 只把窗口外观还给系统，内容里那份
  浅 / 深撤不掉，sheet / popover 连窗口外观都撤不掉。要「跟系统」就自己读系统此刻的浅 / 深、交明确值。长期约束写进
  [界面主题](../architecture/app-themes.md)。
- **切换类的功能要按「从哪到哪 × 外部条件」铺开测。** 森林 ↔ 经典 × 系统深 / 浅 × 起步主题，只有一个格子坏；
  人工清单上写「来回切主题」，没写在哪种系统外观下、从哪个主题起步。
- **测窗口外观别把窗口挪到屏幕外**：挂了 sheet 的窗口会被拉回屏幕，popover 锚在屏幕外弹不出来。放在屏幕上、
  透明、不吃鼠标，离屏渲染照样量得准。
