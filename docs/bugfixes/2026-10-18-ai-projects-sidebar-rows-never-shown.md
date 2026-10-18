# 2026-10-18 侧边栏「AI 在剪的工程」只有标题、工程那几行从来没出来过

## 症状

AI 多开第 ③ 刀（PR #235）合进来之后，屏幕一直锁着，侧边栏没人看过。2026-10-18 屏幕亮着补测（测试版 0.18.42）：一个 AI 会话开了两个工程，
p2 开在自己的工程窗口里、AI 正剪着，主窗口侧边栏里**只有一行灰字「AI Projects」**，下面什么都没有；侧边栏收成图标时多出来的那一格是空的。
辅助功能树里也一样：标题那一行之后再没有行。后台工程（0 个窗口）因此在界面上**完全看不见**：停不了、打不开窗口、关不掉 ——
这一节本来是用户唯一能看见、停下后台工程的地方（方案板 8、I 节）。

## 根因

主窗口侧边栏是一个 `List(.sidebar)`，这一节挂进去的写法是 `AIProjectsSidebarSection(isCompact:).equatable()`，它的 body 是
`if !listed.isEmpty { Section { ForEach(...) { 行 } } header: { Text("AI Projects") } }`。

List 按视图的结构把内容拆成一行一行（`Section`、`ForEach` 都是透明的，自定义视图的 body 也是）。`.equatable()` 包出来的 `EquatableView`
却只算**一个**视图：List 把它整个当成一行，里面的 `Section` 不再被当成分节 —— 只把标题画了出来，`ForEach` 的行一行都没有。

最小探针（同一个 `List(selection:)` + `.listStyle(.sidebar)`，一节三种行：根是 `TimelineView` 的、普通的 `HStack`、`TimelineView` 包在 `HStack` 里）：
套着 `.equatable()` 时三节的标题挤在同一行里、一行内容都没有；去掉 `.equatable()` 三节都对（标题一行 + 内容一行，`TimelineView` 做根也没问题）。

当初套 `.equatable()` 是照着时间线上「块要按值比较」的做法（性能 ratchet 第十三节），想让主窗口的根视图重算时不带着这一节重算；
这一节的输入只有一个 `Bool`，SwiftUI 本来就按值比、不会多算，`.equatable()` 什么都没省下。接线守卫（`checks/open-projects-wiring.sh` 第 13 条）
还按字面钉着带 `.equatable()` 的那一句 —— 把错的写法钉成了对的。屏幕锁着，第 ③ 刀的冒烟只能看工具结果，侧边栏这一项留了人工回归，直到这次才看。

## 修复

- `MainWindowView` 的侧边栏挂 `AIProjectsSidebarSection(isCompact: isSidebarCompact)`，不再套 `.equatable()`；`AIProjectsSidebarSection` 不再做成
  `Equatable`（免得有人顺手再套上），文件头写明为什么（`Sources/SrtFlow/MainWindowView.swift`、`Sources/SrtFlow/AIProjectsSidebar.swift`）。
- 接线守卫第 13 条改成：挂着、而且**没有** `.equatable()`。
- 新的通用扫描守卫 `checks/list-section-not-equatable.sh`：body 里写了 `Section` 的视图，构造处（同一行或紧跟的几行）不许套 `.equatable()`。
- 长期约束写进 [预览性能 ratchet](../architecture/preview-perf-ratchet.md)「时间线上的块」那一节之后（`.equatable()` 只用在一个视图就是一块东西的地方，
  List 里会产出几行的不许套）和 [开着的工程](../architecture/open-projects.md) 第五节之二。

## 验证

- 反向验证：把 `.equatable()` 加回去（同一行的写法、拆成多行参数再在后面另起一行 `.equatable()` 的写法各一次），新守卫当场红、报出
  `MainWindowView.swift:157`；去掉之后绿。`scripts/check-guards.sh` 全绿。
- 真机：这个修复合进去之后出测试版，回来在同一个场景（一个后台工程、一个 AI 在剪的工程窗口）看侧边栏的宽档和图标档、点停止 / 打开窗口 / 关掉，
  结果在 [AI 多开补测报告](../reports/2026-10-18-ai-multi-project-ui-smoke.md)：0.18.43 上宽档每个工程一行、停止 / 打开窗口 / 关掉都对，图标档每个工程一个图标。

## 教训 / 防回归

- **`.equatable()` 不是免费的性能开关**：它把一个视图包成一个整体。时间线上的块本来就是一块，套上只省重算；List 里一个会产出几行（`Section`、
  `ForEach`）的视图套上，就只剩一行。要省重算，先看输入是不是只有值类型（SwiftUI 自己会按值比），而不是顺手套 `.equatable()`。
- **按字面钉写法的接线守卫，钉之前要先确认那个写法是对的**：这条守卫没验过界面，只是把当时的代码抄进了 grep。
- 只能在界面上看的东西，屏幕锁着时留进人工回归清单是对的，但要尽快补：这一处从合并到发现隔了一天，用户要是这期间用了后台模式，后台工程就成了看不见的东西。
