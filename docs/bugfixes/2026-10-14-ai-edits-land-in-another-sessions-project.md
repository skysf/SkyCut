# 2026-10-14 几个 AI 会话共用一个 SrtFlow：改动落进别人的工程

## 症状

2026-10-06 审美盲测（新旧风格卡各剪 3 条，[剪辑美感方案](../plans/2026-10-05-editing-aesthetics.md)）时，同一台 Mac 上同时开着
两个 AI 会话：Claude Code 在剪南极那一条，Claude 桌面版的另一个会话中途调了 `open_project`，把 SrtFlow 切到了用户自己的
`Edit.srtflowproj`。Claude Code 这边接着改 —— 那几步碰巧都是按 id 改的（`edit_clip clip_id=…`），新工程里没有这些 id，
才「安全地」失败了；收尾的两处微调就这样没做成。换成不按 id 的调用（`add_clips` 接在 V1 最后、`set_text` 加字、
`set_canvas` 改画幅、`export_video`），改动会一声不吭地落进用户的工程，导出的也是别人的片子。

2026-09-29 婚礼工程那一轮已经撞见过一次（当时 5 个 `srtflow-mcp` 连着同一个 App，`open_project` 说开了 B、`get_timeline`
却是 C），那次只在 `get_timeline` 里加了工程名（[案例](2026-09-29-mcp-tool-followups-from-wedding-session.md) 第 5 条）：
看得出来，但拦不住。

## 根因

- SrtFlow 一次只开一个工程（`VideoEditProject.shared`），每个工具都对「此刻开着的那个」动手。谁调 `open_project` / `new_project`，
  就替所有会话换了工程。
- 小程序 ↔ App 的通道（`MCPBridge.Request`）只有工具名、参数和客户端名，**没有「这个会话以为自己在剪哪一个工程」**，App 无从
  判断开着的是不是它的。
- 每个会话其实有自己的小程序进程（Claude Code、Codex 每个会话各起一个 `srtflow-mcp`），是记这件事最合适的地方 —— 但它什么都不记。
- 婚礼那次的修法只让结果「说出」工程名，AI 不会每一步去对名字，别的会话换走工程的那一刻它也看不到。

## 修复

不加工具参数（清单离 80,000 字的上限只剩约 400 字），全在通道里做：

- **工程是谁**：`MCPBridge.ProjectStamp`（`token` = 这一次运行的代号 + 工程代号 `documentGeneration`，外加路径、名字）。同一个
  token、或者同一个文件路径，就是同一个工程：存储为、第一次自动存盘改了路径还是它；App 重启过、中间被换走过就不是（同一个文件
  被换走又换回来仍算它）。
- **小程序记着**（`MCPSessionProject`，`Sources/SrtFlowMCPKit/`）：每个小程序进程一个随机会话号；第一次碰工程的调用回什么就记什么，
  之后只有 `open_project` / `new_project` 做成了才换；每个请求带上会话号和记着的工程（`Request.project` / `session`）。
- **App 查**（`AIProjectBinding` + `AIToolRouter`）：哪些调用碰工程按工具和参数判（读时间线也算；只看文件、只碰设置 / 任务的不算；
  `usesProject`）。排到这个调用之后、摆窗口和开一轮之前，开着的不是会话记着的那个就**一样都不做**，回一句话：谁换的（另一个 AI
  会话及其客户端 / 用户在界面上 / App 重启过）、两个工程的名字和路径、「什么都没改」、先问用户、回去或改用开着的那个各怎么调
  `open_project`。会话自己刚换的工程（并排发来的几个调用）不拒。碰了工程的调用把此刻的工程回给小程序（`Response.project`）。
- 两个新字段都是可选的：老小程序不带、老 App 不认，照旧能通（解码有自检）。

长期约束写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第三节和第四节第 46 条。

## 验证

- `scripts/check-mcp.sh` 的 `ProjectBindingChecks`：小程序那份记法（第一次碰工程时记、别的工程的回答不顶掉、被拒不变、存储为
  跟着改路径、`open_project` 失败不换、做成了换、`new_project` 换）；**真起小程序**接一个假 App：一批调用按顺序走，
  `open_project` 之后的 `add_clips` / `set_text` 带着它打开的那个、`new_project` 之后带新的那个，一个进程一个会话号、另起一个
  小程序是另一个会话号且没记着工程；App 的判断（同一个工程 / 同一个文件 / 自己刚换的不拒，别的会话换的、用户换的、App 重启过
  各说各的，路径、「Nothing was changed」、怎么回去都在）；每个工具碰不碰工程的表（会改东西的工具除了只碰文件的几个都必须查）；
  老格式的请求和回答照样解得开。
- `scripts/check-mcp.sh` 的扫描：路由在摆窗口、开一轮之前查；记下谁换的工程；用到的工程回给小程序；小程序发请求带上、收回答记下。
- 反向验证（[草稿 PR](#) 上跑 CI，跑完关掉）：见 PR 描述。

## 教训 / 防回归

- **「一个 App、几个会话」是常态**（用户会开第二个窗口的 AI 去复现 bug、剪另一条），共享的东西（开着的工程）要么每个会话
  各有一份，要么每次调用都核对一遍。只在结果里「说出来」拦不住：AI 不会每一步去对名字。
- **按会话记的东西放在每个会话自己的进程里**（小程序），App 重启了也还记得；App 只负责核对和说清楚。
- 拒绝时要说清楚：谁换的、两个工程各是哪一个、什么都没改、怎么回去 —— AI 能照着做，也知道该先问用户。
- 已知不足：Claude 桌面版的几个对话共用一个小程序（它只起一份 MCP 服务器），在它里面算一个会话；协议里没有对话号可用。
