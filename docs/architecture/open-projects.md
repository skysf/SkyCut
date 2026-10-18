# 开着的工程（`OpenProjects`）：工程不再是单例

> 2026-10-17 起，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 第 ① 刀（①a 拆单例、①b 工程窗口）、第 ②a 刀（AI 按 `project`
> 参数找工程、开 / 建 / 关工程窗口）。已生效的长期约束：谁持有工程、谁该找哪一个、工程的身份怎么认、撤销登记到哪、工程窗口里哪些东西只认自己的。
> 第 ③a 刀加了**后台工程**（没有窗口，第五节之二）。AI 那一面的规矩在 [AI 接口（MCP）](ai-control-mcp.md) 第四节第 46 条。

## 一、谁持有工程

- **`OpenProjects.shared` 持有开着的全部工程**。`VideoEditProject` 没有 `shared`，也只许注册表建（它发短 id；别处自己建一个，
  注册表就不知道它开着）。
- **`primary`**：主窗口剪辑页里的那一个（用户的）。永远有一个，启动时是空的 Untitled；File ▸ 新建 / 打开 / 最近打开、
  双击 `.srtflowproj` 换的是**它的内容**（实例不换，同以前）。
- **`others`**：主窗口以外开着的，按开的先后：各自在一个**工程窗口**里（第四节），或者在**后台、没有窗口**（第五节之二）。开法只有
  `open(url, placement:)`：这个文件已经开着就回它（看得见时把它的窗口摆出来）；开到顶（`limit` = 8，主窗口那个、后台的都算）、打不开就回 nil，
  原因在 `failure`（给 AI 的英文）。新建是 `newProject(savingAs:placement:)`（建好就存到那个路径）。`Placement`：`.window(inFront:)`
  （摆到最前面一次 / 放到后面）或 `.background`（AI 的后台模式）。
  关是 `close(_:)`（先过 `prepareToCloseDocument`，录屏中一律拒）；主窗口那个不关，`resetPrimary()` 换成空的 Untitled（AI 的 `close_project`）。
  谁在开：AI 的 `open_project` / `new_project`（主窗口那个是没人剪的空 Untitled 时装进主窗口，否则开工程窗口）、冒烟驱动。
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
- 关窗：`windowShouldClose` **先问「AI 还在剪吗」**（`aiIsEditing`：归一个 5 分钟内调用过的会话、这一次打开的）—— 是就只摘窗口、
  工程转到后台接着剪（方案 A.6，第五节之二），不问存不存；不是才过 `prepareToCloseDocument`（落盘；未命名又剪了东西的问存不存，点取消就不关），
  关了这个工程就关掉、收拾干净（第五节）。
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
- **全 App 一个的**：导出器只有一个（`VideoEditExporter.shared`，一次只导一条）—— **忙不忙大家都看得见，进度、停止、成片和报错只给发起导出的那个工程**
  （`exporter.belongs(to:)`：工具栏的进度条、预览条上的停止、导出面板底栏的 `VideoEditExportStatus`；开始导出的两条路都传 `export(for: project, …)`）。
  别的工程在导时，这个工程窗口的「导出」照样点得开面板，面板底下写「“名字”正在导出… 42%」、导出键是灰的、没有停止键。2026-10-18 以前 B 窗口里显示 A 的进度和成片、
  还能停掉 A 的导出（[案例](../bugfixes/2026-10-18-export-progress-shown-in-every-project-window.md)）。AI 起的导出第 ④a 刀起排队
  （`AIWorkQueue`，[AI 接口](ai-control-mcp.md) 第四节第 7 条），面板上的导出照旧在空着时直接开始；送 fal 的活的状态行每个窗口都列（`FalStatusRows`）。
  AI 那一轮的横幅第 ② 刀起每个工程一条（`AIRound`）。

## 五、关一个工程（不是换内容）

`ProjectTeardown.close`（落盘已经由调用方做过）：作废后台导入、只取消**它自己的**转写和翻译（`invalidateDocumentGeneration`）、停自动存盘、
停播卸片、**停音频引擎**（每条轨的喂样线程在 `stop` 之前一直留着自己）、作废优化媒体的转码、只作废**它自己的** upscale、清撤销栈。

**换 / 关一个工程只停它自己的活**（几个工程开着时别把别人的停了）：转写按 `boundGeneration`（`cancelIfBound(toGeneration:)`）、
翻译按 `ownerGeneration`（`cancel(ifOwnedBy:)`）、upscale 按任务的 `projectGeneration`（`cancelAll(projectGeneration:)`）认 ——
都是换之前那个代号。以前是 `cancelIfBoundToProject()` / `cancel()` / `cancelAll()`：哪个工程换内容都会停掉别的工程的生成、翻译、upscale。

## 五之二、后台工程（没有窗口，2026-10-17 第 ③a 刀）

方案板 8：AI 的后台模式开 / 建的工程**一个窗口都不开**，也不建预览那一套 —— 播放器的条目、预览合成、实时音频引擎、优化媒体的转码；
缩略图、波形条没有时间线，本来就不会去读。AI 的「看」「听」、导出、字幕本来就不靠播放器（各自建合成、读波形那一份），后台照常。

- **认法**：`isHeadless`（主窗口以外、没挂窗口）；`showsEditor`（主窗口那个永远算，后台的不算）。
- **不建预览**：`VideoEditProject.scheduleRebuild` 开头先问 `showsEditor`，防抖之后再问一次（摘窗口之前排上的那次重建不许把条目挂回去）。
  开 / 建工程的那几秒它还没窗口，重建被跳过；挂上窗口（`place` / `showWindow`）之后马上重建一次。
- **挂上 / 摘下**：`showWindow(for:inFront:)` 给后台工程挂一个工程窗口并重建（AI 的 `set_view visible`、主窗口「AI 在剪的工程」里点打开）；
  `moveToBackground` 摘掉窗口（AI 的 `set_view background`）→ 控制器 `closeKeepingProject` → `windowClosed(keepsProject: true)` →
  `ProjectTeardown.stopPreview`：只停播放器、引擎、优化媒体，文档、撤销历史（工程自己的撤销管理器）、在跑的任务、自动存盘都留着。
- **关**：`close(_:)` 有窗口的关窗口、后台的直接收拾（同第五节），都先过 `prepareToCloseDocument`。退出时后台的也要落定（在 `all` 里）。
- **主窗口侧边栏的「AI 在剪的工程」**（`AIProjectsSidebarSection`，第 ③a 刀后半，方案 I 节）：后台工程和 AI 正在剪的工程窗口各一行 —— 名字 · 短 id、
  在做什么（已停止 / 等你点一下 / 导出 42% … / 排队中 / 在剪… / 空闲；排着队、还没开始的任务问 `AIWorkQueue`，不写成「导出中」）、
  停止（`AIRound.stop`，只停这个工程）、打开窗口（`focus`：后台的先挂窗口，交出键盘）、
  关掉（存过盘、没在跑任务才能点，`close`）。宽档一行的排法：名字和三个按钮一行（名字从中间截、短 id 留在尾巴上），状态独占第二行 ——
  挤在按钮旁边时默认宽度下只剩「Exportin…」（[案例](../bugfixes/2026-10-18-ai-projects-sidebar-row-status.md)）。
  侧边栏只剩图标时每个工程一个图标：点一下打开窗口，提示写名字和状态，右键菜单里有那三样。
  只在有这样的工程时出现；这一节只读注册表的 `others`，每一行自己订阅那个工程的 `AIRound`、任务进度每秒问一次（`TimelineView`）。
  **挂进侧边栏的 List 时不许套 `.equatable()`**：套了整节只算一行、只画出标题（第 ③ 刀就这样合了进去，2026-10-18 补测才发现，
  [案例](../bugfixes/2026-10-18-ai-projects-sidebar-rows-never-shown.md)）；输入只有一个 `Bool`，SwiftUI 自己按值比。

## 六、谁找哪一个

| 地方 | 用哪个工程 |
| --- | --- |
| 编辑菜单的拷贝 / 剪切 / 粘贴、它们亮不亮 | `focused` |
| File ▸ 新建 / 打开 / 最近打开，双击 `.srtflowproj` | `primary`（文件已经在工程窗口里开着就摆出那个窗口）；**AI 正在剪它**（`aiIsEditing`）就不换掉、开到新的工程窗口里（`userNew` / `userOpen`，方案 A.5 的做法）。工程窗口里的工程菜单同理，按那个窗口的工程判 |
| File ▸ 存储 / 存储为 | `focused` |
| 「最近打开」菜单什么时候刷新 | 读 `all` 的 `documentURL`（任何一个工程开 / 存都刷新） |
| 退出（App 的、录屏收尾之后答复的） | `all`，一个不放行就不退 |
| 录屏：设置页、残缺的结果、入轨 | 点 Record 的那个剪辑页的工程 / AI 的 `start` 传进来的那一个（`targetProject`）；它不在了交给 `primary`，代号全 App 不重号，入轨前那道代号核对照样拦住 |
| 录屏的崩溃恢复、恢复时的提示 | `primary`（恢复是启动时、主窗口的事） |
| 音频库试听时让时间线让路 | 试听面板所在的那个工程的引擎 |
| 设置 ▸ 优化媒体 ▸ 清空 | `all`：每个工程都 `reset()` 再 `scheduleRebuild()`（只管一个的话，别的工程的表还指着删掉的块） |
| App 一激活重核对素材位置 | `all` |
| 主线程卡顿日志的 context（在不在播） | `primary` |
| AI 的工具 | 按 `project` 参数（短 id），不带就是这个会话最后打开的那个，会话还没碰过工程就是 `primary`（`AIProjectTargeting`，[AI 接口](ai-control-mcp.md) 第四节第 46 条） |

## 七、守卫

`checks/open-projects-wiring.sh`（`check-all` 第 1 组）：全仓的代码里没有 `VideoEditProject.shared`、`VideoEditProject(` 只在注册表里；
`effectiveUndoManager` 退到 `ownUndoManager`、不碰 `keyWindow`；工程代号正好两处从 `DocumentGenerations.next()` 拿、没有自己数的；
App 的退出和录屏收尾之后的退出都问每个工程；录屏开录时记下 `targetProject`、入轨落回它；
工程窗口的 delegate 交出 `ownUndoManager` 且**先挂 delegate 再放内容**（按行号比）；主窗口的撤销管理器只交给 `.mainWindow` 的剪辑页；
按键先认自己的窗口；录屏的框走 `ScreenRecordingSheets`；换工程只取消自己的翻译、只作废自己的 upscale；关工程停引擎、作废导入、作废 upscale；
存盘前让输入框辞职要先过 `editorIsKey`；**后台工程**：`scheduleRebuild` 开头和防抖之后都问 `showsEditor`、挂上窗口之后重建、摘窗口只停预览
（`keepsProject` 那一支先 return）、关窗先问 AI 还在不在剪（第 ③a 刀，各自反向验证过：拆掉一处就红）；**导出的进度 / 停止 / 成片按工程分**
（第 14 条：编辑窗口和面板里不许只看 `exporter.isExporting`、状态视图先问 `belongs(to: project)`、每个 `exporter.export(` 都带 `for: project`，2026-10-18，三处各自反向验证过）。
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
- [ ] 两个工程窗口（让 AI `open_project` 两个工程）：在一个窗口里按空格、⌫、⌘Z 只动这个工程；编辑菜单的「撤销」标题跟着键窗口的工程变；
      工程窗口的工具栏（工程菜单、素材库、录屏、字幕、导出）都在；在 B 窗口里点 Record，设置页弹在 B 上、录完落进 B。
- [ ] 一个工程窗口里正在改字幕文字，另一个工程在后台被 AI 改着（自动存盘）：打字不被打断。
- [ ] 让 AI `set_view background` 之后 `open_project` 一个工程：不开窗口；AI 照样改、导出；`set_view visible project=…` 之后窗口出来、预览是改过的样子、
      ⌘Z 撤得到 AI 在后台做的每一步。
- [ ] AI 正在剪一个工程窗口里的工程时，用户点它的关闭按钮：窗口没了、不问存不存，AI 接着改照样成功；AI 停下 5 分钟以上再关窗：照常落盘关掉。
- [ ] 侧边栏的「AI 在剪的工程」：后台工程在列表里，导出时写「导出中 42%」；点停止只停这一个（另一个工程照剪）；点打开窗口出窗口、预览是改过的样子；
      导出完点关掉：工程存好关掉、列表里没了。侧边栏收成图标时每个工程一个图标，鼠标停上去看得到名字和状态，右键有三样。
- [ ] AI 正在剪主窗口里的工程时，用户 ⌘N / ⌘O / 最近打开 / 双击一个 .srtflowproj：开到新的工程窗口里，主窗口里 AI 的工程原样、AI 接着改照样成功。
- [ ] 两个工程窗口，A 在导出（面板起的、AI 起的各一次）：A 的工具栏有进度条、预览条上有停止；B 的工具栏没有进度条、预览条上没有停止，B 点导出打开面板，
      底下写「“A 的名字”正在导出… 42%」、导出键是灰的、没有停止键；A 导完，B 的面板里不出现 A 的成片，A 的面板里有。
