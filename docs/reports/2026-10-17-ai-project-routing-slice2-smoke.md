# AI 多开第 ② 刀（一个会话一组工程）的冒烟（测试版 0.18.39）

> 2026-10-17，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 第 ② 刀合进 main 之后（PR #229 `project` 参数 / 一组工程 / 按工程排队，
> #230 每个工程一份「这一轮」/ 停止 / 撤销这一轮，#231 `set_view` 带 `project` / 窗口只在开工程时摆一次；main 9e45671）。
> 长期约束在 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 46 条、第五节。

## 测试版

- 从 main 9e45671 打：`VERSION=0.18.39 scripts/build-app.sh` + `scripts/build-beta-app.sh`（干净的 worktree）。验包：0.18.39 / arm64 /
  `codesign --verify --deep --strict` 过 / 证书 leaf 76d27565…（和 `packaging/signing-identity.sha1` 一致）/ 打包日志里没有 ad-hoc 的退路 /
  小程序 `SRTFLOW_MCP_NO_LAUNCH=1` 喂 initialize 能答、不拉起 App。测试版当时没在跑，原地 `rm -rf` + `ditto`。
- 素材：`vendor/ffmpeg` 现做的 4 段 6 秒测试画面，拷在 scratchpad 的两个文件夹 Trip、Wedding 里，**两边各有一个同名的 `C0001.MP4`**（内容不同、
  大小 0.1 MB 和 3.8 MB）—— 专门看子代理各剪一个文件夹时相对路径会不会串台。

## 会话一：一个会话开两个工程（`scripts/gui-smoke/mcp-client/client.py`）

后台模式（`set_view background`）开着，两个工程都开在自己的窗口里、放在后面。

| 调用 | 结果 |
| --- | --- |
| `open_folder Trip` → `new_project Trip cut` | 回 `project: p2`、`shown_in: own window`，工程建在 `Trip/SrtFlow/Projects/` |
| `add_clips beach.mp4`（不带 project） | 落在 p2（最后打开的那个） |
| `open_folder Wedding` → `new_project Wedding cut` | 回 p3；**`output_folder` 还是 `Trip/SrtFlow`** —— 见下面「撞出的问题」 |
| `add_clips project=p2 C0001.MP4` | 落在 p2，用的是 Trip 那一份（工程记的文件夹） |
| `add_clips C0001.MP4`（不带 project） | 落在 p3，用的是 Wedding 那一份 |
| `add_clips project=p2 vows.mp4`（只在 Wedding 里有） | 落在 p2，路径退到这个会话后来点名的 Wedding（结果里写全路径） |
| `get_timeline project=p2` / 不带 | p2 三段、p3 一段，结果都带 `project` 和 `project_name` |
| `get_status` | `projects` 列出 p1（主窗口、不是你的）、p2、p3（你的、`view: background`） |
| `export_video project=p3` → 马上 `close_project p3` | 拒：「p3 still has a job running (export-1)」 |
| `get_job export-1` | done，结果带 `project: p3`，成片在 `Wedding/SrtFlow/Exports/` |
| `add_clips project=p3 vows.mp4` → `undo round=true project=p3` | p3 退回这一轮开始之前（空的）；**p2 三段原样**（撤销这一轮只退那个工程） |
| `close_project p3` → `get_timeline`（不带） | p3 存好、关掉（`saved_to`、`your_open_projects: [p2]`）；不带 project 的落回 p2 |
| `set_view visible project=p2` | 只改 p2，`projects: [p2]` |

`undo round=true` 退掉的是 p3 这一轮的全部（导出前后两次 `add_clips` 都在同一轮里：一轮按 30 秒没调用划分），和设计一致。

## 会话二：另一个 AI 会话（另起一个小程序 = 另一个会话号）

紧接着会话一（会话一 5 分钟内调用过）：

| 调用 | 结果 |
| --- | --- |
| `get_timeline project=p2` | 拒：「p2 Trip cut (…) is being edited by another AI session (Claude), and only that session may change it. Nothing was changed.」，并说自己还没有工程、怎么拿一个 |
| `open_project` p2 那个文件 | 拒：「…another AI session (Claude) is editing it right now…」，叫它问用户、5 分钟后再试 |
| `cancel_job export-1`（会话一的任务） | 拒：「started by another AI session, and only that session may cancel it」 |
| `get_status` | p2 标 `edited_by: Claude`、`yours: false` |
| `get_timeline`（不带） | 收下主窗口里那个空工程 p1 |
| `new_project Other` | 装进主窗口（p1 是这个会话自己收下的空 Untitled，照样算空着） |
| `add_clips`（Trip 里的文件，全路径）→ `undo round=true` | 落在 p1，撤销这一轮退回空的 |

## 撞出的问题

- **`open_folder` 第二个文件夹时，结果里的 `output_folder` 还是上一个**：`AICallContext` 在调用开始时抄了一份文件夹，`open_folder` 当场换了文件夹
  再报出来拿到的是旧的。之后的调用都是对的，只有那一次的结果错。已修：PR #232（上下文只放「是谁」，文件夹现查；
  [案例](../bugfixes/2026-10-17-open-folder-reports-previous-output-folder.md)），用那个分支打的 0.18.40 测试版重放同一段，第二次报的是 `Wedding/SrtFlow`。
- 冒烟表第一版把 `add_clips` 的参数写成了 `path`（应为 `file`），是表写错了，App 的报错说得清楚。

## 没验到的

- **按某个工程窗口横幅上的「停止」**：本机的界面自动化工具（cmux-cua）没有辅助功能 / 录屏授权（要用户在系统框里点），冒烟点不了按钮。
  停止按工程的接线由 `checks/MCP/router-wiring.sh` 钉着；真点一次留在 [AI 接口](../architecture/ai-control-mcp.md) 第八节的人工回归里（两个工程同时在剪，
  在 p2 的窗口按停止，p1 照剪）。
- 窗口实际摆到哪（后台模式放在后面、`set_view visible` 摆到前面一次）、两个工程窗口里各自 ⌘Z：没截图核对，同样在人工回归清单里。
- 顺带看到（不是这一刀引入的）：`get_timeline` 的 `project_name` 带着 `.srtflowproj` 后缀、没存过的写 `unsaved`，`get_status` 的 `name` 不带后缀 —— 两处口径不一，
  先记下。
