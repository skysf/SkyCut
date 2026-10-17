# AI 多开第 ④ 刀（排队与版本名）的冒烟（测试版 0.18.42）

> 2026-10-17，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 第 ④ 刀合进 main 之后（PR #237 导出 / 转写 / 翻译排队，
> #239 版本名；main 7971da7）。长期约束在 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 7 条（排队、`queue_position`）、
> 第 46 条（同一个文件夹出几个版本）。这一刀合完，方案的四刀都做完了。

## 测试版

- 从 #239 合并前的分支头 9917529 打：它已经合进了当时的 main，和合并后的 main 7971da7 是同一棵树（`git diff 9917529 7971da7` 为空）。
  `VERSION=0.18.42 scripts/build-app.sh` + `scripts/build-beta-app.sh`（干净的 worktree）。验包：0.18.42 / arm64 / `codesign --verify --deep --strict` 过 /
  证书 leaf 76d27565…（和 `packaging/signing-identity.sha1` 一致）/ 打包日志里没有 ad-hoc 的退路 / 小程序 `SRTFLOW_MCP_NO_LAUNCH=1` 喂 initialize 能答。
  装之前把上一轮冒烟起的测试版退掉，原地 `rm -rf` + `ditto`。
- 屏幕仍然锁着；这一刀要看的都在工具结果和磁盘上。

## 一个会话、一个文件夹、两个版本（`scripts/gui-smoke/mcp-client/client.py`，26 步）

素材：scratchpad 里的 Trip 文件夹（beach.mp4、C0001.MP4，各 6 秒 1280×720）；跑之前清掉前几轮留下的 `SrtFlow/` 文件夹，名字才不会被旧文件占住。

| 调用 | 结果 |
| --- | --- |
| `set_view background` → `open_folder Trip` → `new_project "Trip cut"` | p2，`Trip cut.srtflowproj`，后台 |
| `add_clips` 8 段（48 秒） | 落在 p2 |
| 再 `new_project "Trip cut"`（不给 `version`） | 拒：「you already have p2 Trip cut open in this folder. Pass version …: \<name\> - \<version\>」，什么都没建 |
| `new_project "Trip cut" version=vertical` | p3，`Trip cut - vertical.srtflowproj` |
| `add_clips C0001.MP4`（不带 `project`） | 落在 p3（最后打开的） |
| 连着四个 `export_video`：p2；p3；p2 `version=30s`；p3 `version=vertical` | export-1 `running`；export-2 / 3 / 4 `queued`，`queue_position` 1 / 2 / 3。结果里的 `path`：`Trip cut.mp4`、`Trip cut - vertical.mp4`、`Trip cut - 30s.mp4`、`Trip cut - vertical 2.mp4`（工程名里已经带着 vertical，不叠成「vertical - vertical」；那个名字 export-2 占着，加编号） |
| `get_job` export-2 / export-4 | `queued`，位置 1 / 3 |
| `cancel_job export-2` | `cancelled`：「Cancelled while waiting in line; nothing was started.」 |
| `get_job export-4` | 位置变成 2 |
| 等 export-1 / 3 / 4 | 一个接一个做完：4 秒、9 秒、10 秒（从调用起算，含排队），都是 1280×720、24 帧、−18.7 LUFS |
| 磁盘上 | `Trip cut.mp4`（48 秒）、`Trip cut - 30s.mp4`（48 秒）、`Trip cut - vertical 2.mp4`（6 秒）；**没有** `Trip cut - vertical.mp4`（取消的那个没开始、没写文件） |
| `generate_subtitles` p2、p3（`language=en-US`） | subtitles-5 `running`，subtitles-6 `queued` 位置 1，5 结束之后 6 才开始；两条都报「No speech was recognized」（素材是测试音、没有人声）—— 要看的是排队，排队对 |
| `get_status` | p1 在主窗口（不是这个会话的）、p2 / p3 都是 `background (no window)`、`yours: true` |

## 注意到的一处（不改）

排在前面的 export-2 取消之后，export-4 仍叫 `Trip cut - vertical 2.mp4`。名字在调用那一刻定下、写进了 `export_video` 的结果，AI 手里的路径就是最后的路径；
排队中途改名反倒会让那个路径失效。正常用法里同一个工程同一个版本不会导两次。

## 没验到的

- 导出面板和 AI 排着的导出交替（面板起的不进队，AI 在导时面板的按钮是灰的、面板在导时 AI 的排着）：要点界面，屏幕锁着；
  这次补进 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第八节的人工回归清单。
- 翻译那条道：要先有原文字幕和装好的语言包，这一轮的素材没有人声、没跑。三条道是同一个 `AIWorkQueue`，四个入口都经它由
  `checks/ai-work-queue-wiring.sh` 钉着。
- 前几刀留下的界面项（侧边栏「AI 在剪的工程」、横幅上的停止、窗口摆在哪）照旧在 [开着的工程](../architecture/open-projects.md) 第八节和
  [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第八节的人工回归清单里，发版前在真机上走一遍。
