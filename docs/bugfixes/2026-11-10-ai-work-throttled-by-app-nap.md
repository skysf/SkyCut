# 2026-11-10 SkyCut 不在前台时 AI 的活被 App Nap 降速，机器一忙就超时

## 症状

声音功能的免费冒烟（[报告](../reports/2026-11-10-voice-free-smoke.md)，随 PR #368 合进来；看见的问题第 1 条）：同一台机器上别的会话在编译（load average 22–28）时，
测试 App 在后台（AI 用后台模式、窗口被别的 App 盖着）跑 AI 的活慢得离谱：

- 主线程在 `get_job` 拼一个字典这种小事上一卡 1–5 秒（`~/Library/Logs/SrtFlow/main-thread-stalls.log`，栈在 `AIJobs.json`）；
- 5 秒的一批本机转写在 `finishing` 停了 190 秒以上（`voice_library.py` 等满 180 秒判超时）；
- 报价失败退本机的 Kokoro 合成超过 90 秒，MCP 调用超时。

同样的脚本 load 11–14 时 11–25 秒跑完。`ps -o pri` 看测试 App：一次旁白任务里 40 个采样有 37 个是 4。

## 根因

macOS 的 App Nap：App 不在前台、窗口看不见（藏起来、被盖住）时，系统把它放进后台档（调度优先级 4）、合并计时器、限 IO。SkyCut 只在录屏时用
`ProcessInfo.beginActivity` 申请不降速（`ScreenRecordingCoordinator`：「录制期间持活动断言，否则 App Nap 会拖垮时长」），AI 的工具调用和 AI 起的任务都没有。
用户在别的 App 里干活、让 AI 在后台剪，正是这种情形。机器闲的时候优先级低也轮得到、看不出来；一忙就饿死，转写、本机读稿、问 Sky Studio 的那几下都排不上。

为什么不总是看得见：窗口露在屏幕上时 App Nap 不管（冒烟里刚起的测试 App 的主窗口露着，优先级 46–63）；忙的那几段（解码、转写）也会被系统的服务顺手抬上去。
最吃亏的是**等**的那一段 —— 等 Sky Studio 回结局、等队列 —— App 只是隔几秒问一次，正好被当成可以睡的。

## 修复

- 新的 `AIKeepAwake`（`Sources/SrtFlow/AIKeepAwake.swift`）：一份一份地领（`Lease`），还有没还的就持有**一个**
  `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)`，最后一份还掉就 `endActivity`。`.userInitiatedAllowingIdleSystemSleep`
  不降速、不合并计时器，但不拦系统空闲睡眠：AI 的活不该替用户决定 Mac 什么时候睡（录屏那份另外拦睡眠、要低延迟，不走这里）。
  `release()` 只算第一次；忘了还的，最后一个引用放掉时也还（兜底）。
- 谁领：AI 的一次工具调用 —— `AIToolRouter.handle` 一开头领、紧跟 `defer` 还（从收到到回答，含排队）；AI 起的每个长任务 —— `AIJobs.start` 领、
  第一次 `finish` 还（导出、转写、配旁白、生成、upscale、声音库的任务……都经这里）。
- 长期约束写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 59 条：新写的长任务必须走 `AIJobs.start` / `finish`，`beginActivity` /
  `endActivity` 只在 `AIKeepAwake` 和录屏。

## 验证

- 扫描守卫 `checks/ai-keep-awake.sh`：活动断言只在 `AIKeepAwake` 和录屏开关（各一处）；`AIKeepAwake.shared.hold()` 只在路由和 `AIJobs.start`；
  路由领了下一行就是 `defer { awake.release() }`；`finish`（只认第一次的那一支）还。
- `scripts/check-voice-recovery.sh` 的 `KeepAwakeChecks`（真 App 对象）：两份同时领只开一次、第一份还两次只算一次、最后一份还掉才关、领了丢掉也还；
  真起一个 `AIJobs` 任务领一份、结束两次只还一次；真走一次 `AIToolRouter.handle`（`skycut_guide`）开过一次断言、回答之后还掉；
  `StopChecks` 里配旁白的任务跑着时领着、停下和恢复之后都还了；全部声音检查跑完一份都不剩（撤掉 `finish` 那一还时剩 54 份）。
- 反向验证（每一处临时改回去、跑、再恢复）：

  | 临时改成 | 红了什么 |
  | --- | --- |
  | `finish` 不还 | 扫描守卫；`KeepAwakeChecks`「结束还一次」「工具调用之前没有在干的活」、`StopChecks` 两条「还了」、最后「一份都不剩」（剩 54 份） |
  | 路由不领 | 扫描守卫两条；`KeepAwakeChecks`「工具调用开过一次」（开了 0 次） |
  | 路由领了、删掉 `defer` 那一行 | 扫描守卫（只跑了它：丢掉的那一份靠兜底还，行为检查数不出来；可那样不保证这一份活到回答，所以要扫描钉住） |
  | `AIJobs.start` 不领 | 扫描守卫两条；`KeepAwakeChecks`、`StopChecks`「跑着的任务领着」 |
  | `release()` 每次都还 | `KeepAwakeChecks`「同一份还两次只算一次」 |
  | 别的文件里开一个活动断言 | 扫描守卫 |

- 真机（这台 M1、load 3–5，独立的测试身份和假 Sky Studio；测试 App 用 `open -j` 隐藏着开，就是「看不见」的情形；一单旁白在假服务那边排着队 30 秒，
  这 30 秒里不发任何 MCP 调用，每 0.25 秒 `ps -o pri` 一次）：

  | | 等的 30 秒里的优先级 | 30 秒里问了 Sky Studio 几次 | 做完之后 |
  | --- | --- | --- | --- |
  | 修之前 | 115 个采样全是 4 | 14 | — |
  | 修之后 | 114 个是 28、1 个是 46，一个 4 都没有 | 14 | 关掉工程 2.6 秒后回到 4（断言还了） |

  窗口露在屏幕上时修前修后都不降速（App Nap 不管看得见的 App），所以冒烟里主窗口露着的那几轮看不出差别；轻负载下 2 秒一次的问询也没被拖慢 ——
  机器一忙、优先级 4 的才饿死（冒烟里的超时）。

## 教训 / 防回归

- 系统替用户省电的那些机制（App Nap、计时器合并）只看「这个 App 是不是在为用户干活」：AI 替用户干的活，App 自己要说出来。录屏早就这么做了，
  AI 接进来的时候没人把同一条规矩搬过去。新加一种后台跑的活（不经 `AIJobs` 的），先想它要不要领一份。
- 量 App Nap 要让 App 真看不见（`open -j`、⌘H 或被盖住）、要量**等**的那一段；看 `ps -o pri` 是不是 4，别只看总时长 —— 闲的机器上降了速也跑得完。
- 领和还成对靠两层：扫描钉住在哪领、在哪还（`defer` 删了行为检查是看不出来的），行为检查数得出开了几次、还了几次、剩了几份。
