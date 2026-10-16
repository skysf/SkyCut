# 开着的工程（`OpenProjects`）：工程不再是单例

> 2026-10-17 起，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 第 ① 刀。已生效的长期约束：谁持有工程、
> 谁该找哪一个、工程的身份怎么认、撤销登记到哪。工程窗口、后台工程、AI 按 `project` 参数找工程是方案的后几刀，
> 加进来的时候更新这里。

## 一、谁持有工程

- **`OpenProjects.shared` 持有开着的全部工程**。`VideoEditProject` 没有 `shared`，也只许注册表建（它发短 id；
  别处自己建一个，注册表就不知道它开着）。
- **`primary`**：主窗口剪辑页里的那一个（用户的）。永远有一个，启动时是空的 Untitled；File ▸ 新建 / 打开 / 最近打开、
  双击 `.srtflowproj` 换的是**它的内容**（实例不换，同以前）。
- **`focused`**：键盘焦点所在的剪辑页的工程。编辑菜单的拷贝 / 剪切 / 粘贴和它们亮不亮、⌘S / 存储为作用在它身上。
  现在只有主窗口的剪辑页，所以就是 `primary`；工程窗口进来之后按键窗口认。
- **`all`**：开着的全部。退出时每一个都要过 `prepareToCloseDocument()`（落盘、未命名的问存不存），**有一个不放行就不退出、
  后面的不再问**。现在 `all` 里只有 `primary`。
- 剪辑页 `VideoEditView(project:)` 剪哪一个由外面给；主窗口给 `primary`。

## 二、工程的身份

- **短 id**（`shortID`）：`p1`、`p2`……按开的先后发，这一次运行里不重用（关掉的号不再发给别人，免得 AI 拿旧号改到新工程上）。
  一个实例一个，换内容不变。AI 用它指工程是下一刀的事。
- **工程代号**（`documentGeneration`）：**全 App 一个计数**（`DocumentGenerations.next()`），建工程、换工程（`invalidateDocumentGeneration`）
  都拿新号，不许各自 +1。理由：代号被当作「这一个工程的这一次打开」跨对象比较 —— AI 会话记着的工程（`AIProjectBinding.token`）、
  路由记的谁换了工程（`switches`）、「撤销这一轮」的快照、导出面板记住的标题、upscale 任务、录屏请求和崩溃恢复的记录。
  每个工程各从 0 数的话，两个工程会撞号、被判成同一个。工程自己的「回来的后台任务还是不是这个工程的」（`isCurrentGeneration`）照旧。

## 三、撤销登记到哪

- 剪辑页出现时把窗口的撤销管理器交给工程（`undoManager`，现状）；没有窗口交过来时用**工程自己的**（`ownUndoManager`）。
- **不许退到键窗口的**（以前的 `NSApp.keyWindow?.undoManager`）：几个工程开着时键窗口可能是别的工程的窗口，改动会登记进它的
  撤销栈 —— 撤销的 target 是工程对象，在那个窗口里按 ⌘Z 撤的却是这个工程；那个工程换内容时 `removeAllActions()` 还会顺手清掉
  这个工程的历史。
- 方案 G 的后续：工程窗口和后台工程只用工程自己的那一个，挂上 / 摘下窗口不丢历史；主窗口能不能也接到工程自己的那一个，先做探针。

## 四、谁找哪一个

| 地方 | 用哪个工程 |
| --- | --- |
| 编辑菜单的拷贝 / 剪切 / 粘贴、它们亮不亮 | `focused` |
| File ▸ 新建 / 打开 / 最近打开，双击 `.srtflowproj` | `primary` |
| File ▸ 存储 / 存储为 | `focused` |
| 退出（App 的、录屏收尾之后答复的） | `all`，一个不放行就不退 |
| 录屏入轨 | 开录时 `start(options:project:)` 传进来的那一个（`targetProject`）；它不在了交给 `primary`，代号全 App 不重号，入轨前那道代号核对照样拦住 |
| 录屏的崩溃恢复、恢复时的提示 | `primary`（恢复是启动时、主窗口的事） |
| 音频库试听时让时间线让路 | 试听面板所在的那个工程的引擎 |
| 设置 ▸ 优化媒体 ▸ 清空 | `all`：每个工程都 `reset()` 再 `scheduleRebuild()`（只管一个的话，别的工程的表还指着删掉的块） |
| 主线程卡顿日志的 context（在不在播） | `primary` |
| AI 的工具 | `primary`（下一刀改成按 `project` 参数，方案第 ② 刀） |

## 五、守卫

`checks/open-projects-wiring.sh`（`check-all` 第 1 组）：全仓的代码里没有 `VideoEditProject.shared`、`VideoEditProject(` 只在注册表里；
`effectiveUndoManager` 退到 `ownUndoManager`、不碰 `keyWindow`；工程代号正好两处从 `DocumentGenerations.next()` 拿、没有自己数的；
App 的退出和录屏收尾之后的退出都问每个工程；录屏开录时记下 `targetProject`、入轨落回它。
写死旧字符串的两条也跟着改了：`checks/timeline-clipboard-wiring.sh`（编辑菜单接到 `focused`）、`checks/MCP/router-wiring.sh`（路由拿工程的那一行）。

反向验证（2026-10-17）：往别的文件里加一行 `VideoEditProject.shared`、在注册表外建一个工程、撤销改回退到键窗口、代号改回 `&+= 1`、
退出改成只问 `primary`、录屏入轨改成落进 `primary` —— 六处各自当场红，恢复后绿。

## 六、人工回归（发版前在真机上走一遍）

- [ ] 开一个工程剪几刀，⌘Z / ⇧⌘Z 一步步退、进；切去压缩页再回来，⌘Z 照常。
- [ ] 未命名工程剪了东西直接 ⌘Q：照旧问存不存；点「取消」不退出，工程还在。
- [ ] 时间线上选几段 ⌘C、⌘V：照旧粘在鼠标那一处；编辑菜单里拷贝 / 粘贴亮不亮和以前一样。
- [ ] 录一段屏：落在当前工程的 V1 末尾，⌘Z 一步退掉。
- [ ] 音频库试听一首：时间线的声音让路、停了恢复。
- [ ] 设置 ▸ 优化媒体 ▸ 清空：预览照常，之后后台重新转。
