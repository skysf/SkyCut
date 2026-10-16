# 开着的工程（`OpenProjects`）：工程不再是单例

> 2026-10-17 起，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 第 ① 刀（①a 拆单例、①b 工程窗口）。已生效的长期约束：
> 谁持有工程、谁该找哪一个、工程的身份怎么认、撤销登记到哪、工程窗口里哪些东西只认自己的。后台工程、AI 按 `project` 参数找工程是
> 方案的后几刀，加进来的时候更新这里。

## 一、谁持有工程

- **`OpenProjects.shared` 持有开着的全部工程**。`VideoEditProject` 没有 `shared`，也只许注册表建（它发短 id；别处自己建一个，
  注册表就不知道它开着）。
- **`primary`**：主窗口剪辑页里的那一个（用户的）。永远有一个，启动时是空的 Untitled；File ▸ 新建 / 打开 / 最近打开、
  双击 `.srtflowproj` 换的是**它的内容**（实例不换，同以前）。
- **`others`**：主窗口以外开着的，各自在一个**工程窗口**里（第四节），按开的先后。开法只有 `openInWindow(url)`：
  这个文件已经开着就把那个窗口摆出来、回它；开到顶（`limit` = 8，主窗口那个也算）、打不开就回 nil，原因在 `failure`（给 AI 的英文）。
  现在只有冒烟驱动在开；AI 按 `project` 开工程是方案第 ② 刀。
- **`focused`**：键窗口是工程窗口就是它的工程（`keyProjectWindow`，窗口变成 / 不再是键窗口时更新），否则是 `primary`。
  编辑菜单的拷贝 / 剪切 / 粘贴和它们亮不亮、⌘S / 存储为作用在它身上；这几项在「主窗口停在剪辑页」**或**「键窗口是工程窗口」时可用。
- **`all`**：开着的全部。退出时每一个都要过 `prepareToCloseDocument()`（落盘、未命名的问存不存），**有一个不放行就不退出、
  后面的不再问**。
- **同一个文件只开一份**（两份同时自动存盘会互相盖掉）：主窗口要开的文件已经在某个工程窗口里开着，就把那个窗口摆出来、不载入
  （`openProject(at:)` 开头那一句）；`openInWindow` 同理。认法是 `ProjectFileIdentity.same`：规范化、跟着符号链接走之后路径一样。
- 剪辑页 `VideoEditView(project:host:)` 剪哪一个、装在哪由外面给：主窗口给 `(primary, .mainWindow)`，工程窗口给 `(它的工程, .projectWindow)`。
- **App 一激活就重核对素材位置**：注册表挂一个观察者、把每个开着的工程过一遍（以前每个工程在 init 里挂一个、从来不摘）。

## 二、工程的身份

- **短 id**（`shortID`）：`p1`、`p2`……按开的先后发，这一次运行里不重用（关掉的号不再发给别人，免得 AI 拿旧号改到新工程上）。
  一个实例一个，换内容不变。
- **工程代号**（`documentGeneration`）：**全 App 一个计数**（`DocumentGenerations.next()`），建工程、换工程（`invalidateDocumentGeneration`）
  都拿新号，不许各自 +1。理由：代号被当作「这一个工程的这一次打开」跨对象比较 —— AI 会话记着的工程（`AIProjectBinding.token`）、
  路由记的谁换了工程（`switches`）、「撤销这一轮」的快照、导出面板记住的标题、upscale 任务、录屏请求和崩溃恢复的记录、
  转写 / 翻译绑着哪个工程。每个工程各从 0 数的话，两个工程会撞号、被判成同一个。工程自己的「回来的后台任务还是不是这个工程的」
  （`isCurrentGeneration`）照旧。

## 三、撤销登记到哪

- **工程窗口**：window delegate 的 `windowWillReturnUndoManager` 交出**工程自己的**（`ownUndoManager`）。⌘Z、编辑菜单的亮灭和标题、
  工具栏的撤销按钮（读 `@Environment(\.undoManager)`，进了窗口之后就是它）撤的都是这个工程的；窗口关了、以后再挂一个，历史还在。
  **先挂 delegate 再放内容**：窗口头一回被问撤销管理器时才问 delegate、之后就记住那一个；SwiftUI 的内容一放进来就会问 ——
  反过来写的话窗口自己建一个，⌘Z 撤不到工程（2026-10-17 冒烟撞上的：`undo:` 有人接、工程的撤销栈一动不动）。
- **主窗口**：剪辑页出现时把主窗口的撤销管理器交给 `primary`（`if host == .mainWindow { project.undoManager = undoManager }`）。
  **主窗口改不了**：它是 SwiftUI 的 `Window` 场景，窗口类是 SwiftUI 自己的 `AppKitWindow`，**不问 delegate**（探针：给它套一层转发的
  delegate，delegate 照答、`undoManager` 照旧是窗口自己的）。所以从主窗口挪出去的工程带不走 ⌘Z 的历史（方案的退路；「撤销这一轮」
  按快照换回，照样能用）。
- 没有窗口交过来时用工程自己的；**不许退到键窗口的**（以前的 `NSApp.keyWindow?.undoManager`）：几个工程开着时键窗口可能是别的工程的
  窗口，改动会登记进它的撤销栈 —— 撤销的 target 是工程对象，在那个窗口里按 ⌘Z 撤的却是这个工程；那个工程换内容时
  `removeAllActions()` 还会顺手清掉这个工程的历史。

探针（2026-10-17，scratchpad 里一个独立的 SwiftUI App）：AppKit 建的窗口 + `NSHostingView`（`sceneBridgingOptions = [.toolbars, .title]`）+
delegate 交出自己的撤销管理器 —— 窗口的撤销管理器、宿主视图沿响应链找到的、`undo:` 沿响应链撤的、`NSWindow` 判 `undo:` 亮不亮、
SwiftUI 的 `.toolbar` 进了窗口的工具栏、`.sheet` 挂在这个窗口上、关窗，全过；`@Environment(\.undoManager)` 在 `onAppear` 那一刻还是 nil，
进了窗口之后就是工程的。SwiftUI 的 `Window` 场景套转发 delegate 那三项全不过。

## 四、工程窗口（`ProjectWindowController`）

- AppKit 自己建的窗口装同一个剪辑页（为什么不用 SwiftUI 的 `WindowGroup`：上一节）。宿主视图套 `.appLanguage()`（新的根不带应用内语言）、
  标题跟着工程名（`.navigationTitle` 经 `sceneBridgingOptions` 交给窗口）。
- 开的时候层叠排开（第一个放正中），**摆到最前面一次、不激活 App**（`orderFrontRegardless`，键盘留在用户正在打字的地方；方案板 3）。
- 关窗：`windowShouldClose` 先过 `prepareToCloseDocument`（落盘；未命名又剪了东西的问存不存，点取消就不关），关了这个工程就关掉、
  收拾干净（第五节）。方案第 ③ 刀起，AI 在剪的工程关窗是转后台，不是关工程。
- **几个剪辑页同时在时，这些只认自己的**：
  - **按键**：`handleEvent` 先认 `event.window` 是不是这个剪辑页的窗口（`TimelineScrollGeometry.live(for: project)?.window`）——
    每个剪辑页各挂一个本地按键监听，不分的话按一次空格每个工程都开播。
  - **时间线的滚动几何**：`TimelineScrollGeometry.live(for: project)`（以前全 App 一份 `live`，指着最后挂上来的那条时间线）：
    工具栏缩放、⌘V 找指针、AI 把时间线滚过去都按工程找。
  - **录屏的框**（`ScreenRecordingSheets`）：设置页和残缺的结果弹在开录的那个工程的窗口里（`ScreenRecordingCoordinator.begin(for:)`
    记下 `targetProject`，录完也落进它）；崩溃恢复只在主窗口查、只在主窗口弹。
  - **upscale 的面板和对比窗口**（`UpscalePresenter`）：只在它那一段 / 那个任务所在的工程的窗口里弹；以前每个窗口各弹一个，
    别的窗口还会因为「这一段不在我这儿」把它收掉。
  - **存盘前让输入框辞职**（`endPendingTextEditing`）：只在键窗口是这个工程的剪辑页时（主窗口还要停在剪辑页那一栏，`editorIsKey`）——
    后台工程每次自动存盘都去踢键窗口的话，用户在别处正打的字会被打断。
- **全 App 一份的东西**：工具栏的吸附 / 联动 / 播放跟随（一个窗口里拨了，别的开着的工程跟着拨：`OpenProjects.sync`，
  [剪辑页上记住的开关](editor-remembered-toggles.md)）；预览的「优化媒体 / 原片」（每个工程都换过去、各自重建，[优化媒体](optimized-media.md)）。
- **还没分开的**（方案后几刀）：导出只有一个（`VideoEditExporter.shared`，B 窗口的工具栏也显示 A 的导出进度、导出按钮也灰着 —— 第 ④ 刀排队）；
  AI 那一轮的横幅全 App 一份（第 ② 刀）；送 fal 的活的状态行每个窗口都列（`FalStatusRows`）。

## 五、关一个工程（不是换内容）

`ProjectTeardown.close`（落盘已经由调用方做过）：作废后台导入、只取消**它自己的**转写和翻译（`invalidateDocumentGeneration`）、停自动存盘、
停播卸片、**停音频引擎**（每条轨的喂样线程在 `stop` 之前一直留着自己）、作废优化媒体的转码、只作废**它自己的** upscale、清撤销栈。

**换 / 关一个工程只停它自己的活**（几个工程开着时别把别人的停了）：转写按 `boundGeneration`（`cancelIfBound(toGeneration:)`）、
翻译按 `ownerGeneration`（`cancel(ifOwnedBy:)`）、upscale 按任务的 `projectGeneration`（`cancelAll(projectGeneration:)`）认 ——
都是换之前那个代号。以前是 `cancelIfBoundToProject()` / `cancel()` / `cancelAll()`：哪个工程换内容都会停掉别的工程的生成、翻译、upscale。

## 六、谁找哪一个

| 地方 | 用哪个工程 |
| --- | --- |
| 编辑菜单的拷贝 / 剪切 / 粘贴、它们亮不亮 | `focused` |
| File ▸ 新建 / 打开 / 最近打开，双击 `.srtflowproj` | `primary`（文件已经在工程窗口里开着就摆出那个窗口） |
| File ▸ 存储 / 存储为 | `focused` |
| 「最近打开」菜单什么时候刷新 | 读 `all` 的 `documentURL`（任何一个工程开 / 存都刷新） |
| 退出（App 的、录屏收尾之后答复的） | `all`，一个不放行就不退 |
| 录屏：设置页、残缺的结果、入轨 | 点 Record 的那个剪辑页的工程 / AI 的 `start` 传进来的那一个（`targetProject`）；它不在了交给 `primary`，代号全 App 不重号，入轨前那道代号核对照样拦住 |
| 录屏的崩溃恢复、恢复时的提示 | `primary`（恢复是启动时、主窗口的事） |
| 音频库试听时让时间线让路 | 试听面板所在的那个工程的引擎 |
| 设置 ▸ 优化媒体 ▸ 清空 | `all`：每个工程都 `reset()` 再 `scheduleRebuild()`（只管一个的话，别的工程的表还指着删掉的块） |
| App 一激活重核对素材位置 | `all` |
| 主线程卡顿日志的 context（在不在播） | `primary` |
| AI 的工具 | `primary`（方案第 ② 刀改成按 `project` 参数） |

## 七、守卫

`checks/open-projects-wiring.sh`（`check-all` 第 1 组）：全仓的代码里没有 `VideoEditProject.shared`、`VideoEditProject(` 只在注册表里；
`effectiveUndoManager` 退到 `ownUndoManager`、不碰 `keyWindow`；工程代号正好两处从 `DocumentGenerations.next()` 拿、没有自己数的；
App 的退出和录屏收尾之后的退出都问每个工程；录屏开录时记下 `targetProject`、入轨落回它；
工程窗口的 delegate 交出 `ownUndoManager` 且**先挂 delegate 再放内容**（按行号比）；主窗口的撤销管理器只交给 `.mainWindow` 的剪辑页；
按键先认自己的窗口；录屏的框走 `ScreenRecordingSheets`；换工程只取消自己的翻译、只作废自己的 upscale；关工程停引擎、作废导入、作废 upscale；
存盘前让输入框辞职要先过 `editorIsKey`。
写死旧字符串的几条也跟着改了：`checks/timeline-clipboard-wiring.sh`（编辑菜单接到 `focused`）、`checks/MCP/router-wiring.sh`（路由拿工程的那一行）、
`checks/project-file-wiring.sh`（转写按代号取消）、`checks/screen-recording-ai-wiring.sh`（设置页搬进 `ScreenRecordingSheets`）。

反向验证（2026-10-17）：①a 的六条 —— 往别的文件里加一行 `VideoEditProject.shared`、在注册表外建一个工程、撤销改回退到键窗口、代号改回 `&+= 1`、
退出改成只问 `primary`、录屏入轨改成落进 `primary` —— 各自当场红，恢复后绿。①b 的见第 ①b 刀的 PR 说明。

进程内冒烟（`scripts/gui-smoke/in-process/run.sh`，2026-10-17，两个工程：主窗口 p1、`projectWindow` 开的 p2，同一个素材文件夹里的两份工程文件）：
往 p2 的窗口按空格只有 p2 在播；在 p2 里加一条文字、沿 p2 窗口的响应链发 `undo:`：p2 的文字 7 → 6、撤销栈空了，p1 的撤销栈从头到尾是空的；
p2 里拨吸附，p1 跟着变；关掉 p2 的窗口之后开着的只剩 p1。

## 八、人工回归（发版前在真机上走一遍）

- [ ] 开一个工程剪几刀，⌘Z / ⇧⌘Z 一步步退、进；切去压缩页再回来，⌘Z 照常。
- [ ] 未命名工程剪了东西直接 ⌘Q：照旧问存不存；点「取消」不退出，工程还在。
- [ ] 时间线上选几段 ⌘C、⌘V：照旧粘在鼠标那一处；编辑菜单里拷贝 / 粘贴亮不亮和以前一样。
- [ ] 录一段屏：落在当前工程的 V1 末尾，⌘Z 一步退掉。
- [ ] 音频库试听一首：时间线的声音让路、停了恢复。
- [ ] 设置 ▸ 优化媒体 ▸ 清空：预览照常，之后后台重新转。
- [ ] 两个工程窗口（等 AI 能开工程窗口之后）：在一个窗口里按空格、⌫、⌘Z 只动这个工程；编辑菜单的「撤销」标题跟着键窗口的工程变；
      工程窗口的工具栏（工程菜单、素材库、录屏、字幕、导出）都在；在 B 窗口里点 Record，设置页弹在 B 上、录完落进 B。
- [ ] 一个工程窗口里正在改字幕文字，另一个工程在后台被 AI 改着（自动存盘）：打字不被打断。
