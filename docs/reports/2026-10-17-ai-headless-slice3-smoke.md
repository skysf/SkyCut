# AI 多开第 ③ 刀（后台工程、AI 在剪的工程列表、fal 确认码）的冒烟（测试版 0.18.41）

> 2026-10-17，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 第 ③ 刀合进 main 之后（PR #234 后台工程，#235 侧边栏「AI 在剪的工程」+
> 用户在 AI 正剪着的工程上新建 / 打开开到新窗口，#236 fal 超额度改确认码；main 270e29a）。长期约束在 [开着的工程](../architecture/open-projects.md)
> 第五节之二、[AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 46 条、[fal.ai 生成](../architecture/fal-generation.md) 第五节。

## 测试版

- 从 main 270e29a 打：`VERSION=0.18.41 scripts/build-app.sh` + `scripts/build-beta-app.sh`（干净的 worktree）。验包：0.18.41 / arm64 /
  `codesign --verify --deep --strict` 过 / 证书 leaf 76d27565…（和 `packaging/signing-identity.sha1` 一致）/ 打包日志里没有 ad-hoc 的退路 /
  小程序 `SRTFLOW_MCP_NO_LAUNCH=1` 喂 initialize 能答、不拉起 App / 包里的中文表有「AI Projects」。装之前把上一轮冒烟起的测试版退掉，原地 `rm -rf` + `ditto`。
- **这一轮屏幕一直锁着**：界面（侧边栏的列表、窗口摆在哪）没法截图核对，下面「没验到的」列着。

## 后台工程（`scripts/gui-smoke/mcp-client/client.py`，一个会话）

素材同第 ② 刀（scratchpad 里的 Trip、Wedding 两个文件夹）。

| 调用 | 结果 |
| --- | --- |
| `set_view background` → `open_folder Trip` → `new_project Headless trip` | 回 `project: p2`、`shown_in: background (no window)` |
| `add_clips` 两段、`set_text` | 落在 p2（结果带 `project: p2`） |
| `get_status` | p2 `shown_in: background (no window)`、`view: background`、`yours: true` |
| `look time=1` | 后台工程照样看得到画面（拼图里是第一段和那行字，`on_screen` 列出两样） |
| `export_video project=p2 720p` → `get_job` | 2 秒做完，1280×720、24 帧、响度 −18.7 LUFS（后台工程不靠播放器也导得出） |
| `set_view visible project=p2` | `get_status` 里变成 `own window` |
| `undo project=p2` → `get_timeline` | 撤掉的是在后台时加的那行字（挂上窗口之后撤销历史还在：工程自己的撤销管理器） |
| `set_view background project=p2` | 又变回 `background (no window)`、工程还开着 |
| `open_folder Wedding` → `open_project` p2 的文件 | `already_open: true`、回 p2（同一个文件只开一份） |
| `new_project Second` → `add_clips vows.mp4`（不带 project） | p3 也在后台；不带 project 的落在 p3（最后打开的） |
| `close_project p2` | 后台工程也关得掉：存好（`saved_to`），`your_open_projects: [p3]` |

## fal 超额度的确认码（真 App + 真小程序 + 本机的假 fal，`scripts/gui-smoke/fal/`）

测试版装着用户真的 fal Key，冒烟不在它上面花钱；确认码这一路用调试版组装的独立测试 App（`com.srtflow.SrtFlow.falsmoke`）+ 假 fal 跑（#236 合并前在分支上跑的）：

- 场景二 `approval.py`（每日上限 0.30）：**17 项通过、1 项没验到**。超额度（视频 $0.40）当场回 `needs_confirmation` + 码、问题里有估价和上限、没起任务、
  没发请求、没记账；瞎编的码不认且说原因；等答复时再问回同一张；带码再调才起任务、做完、记账 $0.40；同一张码不能用两次；没登记单价的模型每次都要码、
  带码之后请求发出去、`cancel_job` 让 fal 也取消（detached PUT）；额度用完之后 $0.027 的图也要码。没验到：按横幅上的停止（System Events 看不见测试 App 的窗口）。
- 场景一 `generate.py`（额度内的五种生成、放上时间线、配旁白、克隆、账、Key 头）：全部通过。

## 撞出的问题

没有新的问题。中途一度以为「摘下窗口之后窗口还在屏幕上」：系统的窗口列表（`CGWindowListCopyWindowInfo`）在 p2 摘回后台、又关掉之后仍然报着那个窗口
`onscreen`。用一个最小的 AppKit 探针对照：窗口 `close()`（连先 `orderOut` 的也一样）之后 AppKit 报 `isVisible = false`，CG 仍报在屏幕上 ——
是**屏幕锁着时 CG 的「屏幕上的窗口」不更新**，不是窗口没关。锁屏时别拿它判断窗口在不在。

## 没验到的（屏幕锁着、本机的界面自动化没授权）

- 主窗口侧边栏「AI 在剪的工程」的样子（宽档的一行、图标档的一个图标和右键菜单）、上面的停止 / 打开窗口 / 关掉。
- 用户关掉 AI 在剪的工程的窗口 → 转到后台；AI 正剪着主窗口的工程时用户 ⌘N / ⌘O → 开到新窗口。
- 后台模式开工程真的一个窗口都不开、`set_view visible` 摆到前面一次。

以上都在 [开着的工程](../architecture/open-projects.md) 第八节的人工回归清单里，发版前在真机上走一遍。
