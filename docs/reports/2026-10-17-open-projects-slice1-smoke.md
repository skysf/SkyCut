# AI 多开第 ① 刀（拆单例 + 工程窗口）的冒烟（测试版 0.18.38）

> 2026-10-17，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 第 ① 刀合进 main 之后（PR #225 拆单例、#226 工程窗口，main 1bb18fb）。
> 长期约束在 [开着的工程](../architecture/open-projects.md)。这一刀对用户和 AI 应该**看不出变化**（AI 还只剪主窗口那一个，工程窗口还没有生产入口），
> 所以冒烟分两半：工程窗口用进程内驱动在真窗口里验，AI 的老流程在装好的测试版上验没坏。

## 测试版

- 从 main 1bb18fb 打：`VERSION=0.18.38 scripts/build-app.sh` + `scripts/build-beta-app.sh`（在一个干净的 worktree 里，不带手上没合的代码）。
  验包：0.18.38 / arm64 / `codesign --verify --deep --strict` 过 / 证书 leaf 76d27565…（和 `packaging/signing-identity.sha1` 一致）/ 打包日志里没有 ad-hoc 的退路 /
  小程序 `SRTFLOW_MCP_NO_LAUNCH=1` 喂 initialize 能答、不拉起 App。测试版当时没在跑，原地 `rm -rf` + `ditto` 装进「应用程序」。
- 坑：本机终端在 Rosetta 下，`arch -arm64 bash scripts/build-app.sh` 找到的 `bash` 只有 x86（「Bad CPU type in executable」）；用系统的通用二进制
  `arch -arm64 /bin/bash scripts/build-app.sh`。

## 工程窗口（进程内驱动，开发版）

`scripts/gui-smoke/in-process/run.sh`，两个工程：主窗口 p1、`projectWindow` 开的 p2（同一个素材文件夹里的两份工程文件，23 段、6 条字）。

| 步骤 | p1 | p2 |
| --- | --- | --- |
| 往 p2 的窗口按空格 | 停着 | 在播（播放头 0.953） |
| 在 p2 里加一条文字 | 字 6 条、撤销栈空 | 字 7 条、撤销栈有一步 |
| 沿 p2 窗口的响应链发 `undo:` | 没变、撤销栈空 | 字回到 6 条、撤销栈空 |
| 在 p2 里关吸附 | 跟着关了 | 关 |
| 点 p2 窗口的关闭按钮 | 开着的只剩 p1 | 关掉、收拾干净 |

第一次跑撞出一个真问题：`undo:` 有人接、p2 的撤销栈却一动不动 —— 窗口的撤销管理器不是工程的。原因是先放内容后挂 delegate，窗口头一回被问时还没有 delegate、
自己建了一个之后就记住了。改成先挂 delegate 再放内容后过了，守卫按行号钉着（[开着的工程](../architecture/open-projects.md) 第三节）。

## AI 的老流程（装好的测试版，`scripts/gui-smoke/mcp-client/client.py`）

测试版没开时小程序把它拉起来（结果最前面带「SrtFlow was not running…」那句）。一个会话、一个工程：

| 调用 | 结果 |
| --- | --- |
| `set_view background`、`open_folder`（拷到 scratchpad 的素材A） | 通 |
| `new_project smoke-slice1` → `open_project` 同一份 | 建在 `素材A/SrtFlow/Projects/`，开回来 0 段 |
| `add_clips` 两段（4 秒 + 3 秒） | V1 上 0–4、4–7 秒 |
| `set_text` → `undo` | 字没了，两段素材还在（一步撤销、撤到主窗口的撤销栈里） |
| `look times=[1]` | 认出第一段（冰面、雪）、画面上是谁说得对 |
| `export_video 720p` → `get_job` | 2 秒做完，1280×720、24 帧，响度 −29.3 LUFS |
| `save_project`、`get_status` | 通 |

## 没验到的

- 工程窗口还没有生产入口（AI 按 `project` 开工程是第 ② 刀），真机上「两个工程窗口里按 ⌘Z、编辑菜单的撤销标题跟着键窗口变、在 B 窗口里录屏」
  等第 ② 刀出测试版时一起走（[开着的工程](../architecture/open-projects.md) 第八节的人工回归）。
- 冒烟里准备第二份工程时 `copy-project.sh` 把整个「下载」文件夹拷了过来、写满了磁盘，已删掉、修好（PR #227，
  [案例](../bugfixes/2026-10-17-copy-project-copied-all-of-downloads.md)）。
