# MCP 按需说明的实施报告（进行中）

> [MCP 按需说明方案](../plans/2026-11-09-mcp-guide.md)（2026-11-10 用户批准施工）做到哪、实测的数字、偏差和本机跑检查时遇到的事。
> 已经生效的合同写在 [MCP 说明书](../architecture/mcp-guide.md)，这里只记进度和一次性的记录（2026-11-10 审查 review-344 第 7 条：
> 进度和这类记录不放 `docs/architecture/`）。

## 进度（方案 7.1）

| PR | 状态 | 做了什么 |
| --- | --- | --- |
| 1 `feat/mcp-guide-tool` | 2026-11-10 合并（#344） | `skycut_guide`：主题表（每个工具一个同名主题，概要 = 它现在的说明原文，`fields` 从参数定义现算）、App 答、路由 Policy、`alwaysLoad`、没开通也照答、`GuideChecks`；不带 topic 回按清单顺序的平铺目录 |
| 1a `fix/mcp-guide-review-followups` | 2026-11-10 合并（#348） | 审查 review-344 第 1–4、6、7 条：fields 写全参数定义的事实、说明书不等授权、守卫按行首 / 路径认、例子 / related / 凭据的守卫、只给 section 时说清楚、进度挪到这里 |
| 2 `feat/mcp-guide-map-and-pointers` | 2026-11-10 开 PR（#351） | 按任务分组的地图（2,617 字）、rules / conventions / paid / workflows / errors 五个通用主题、总说明 2,037 → 1,115 字（目录搬进地图）、报错指路（两处，含 review-344 第 9 条：被挡住时说 `skycut_guide` 照常能用）；全清单 107,198 → 107,276（说明书的名片 383 → 429） |
| 3 `feat/mcp-cards-pilot` | 进行中 | 试点 5 个工具：名片 3,509 → 2,088 字（edit_clip 737 → 443、generate_media 978 → 442、set_text 249 → 331、add_clips 577 → 424、look 968 → 448）；54 条参数说明改到 ≤ 120 且写上范围；主题写全（迁移前的原文 + 手写几节 + 例子 + related，删掉的长话逐条有去处）；`fields` 太长按整个参数自动切成 `fields`、`fields_2`……（review-344 第 5 条，现在只有 generate_media 切成两节）；`GuidePilotChecks`；实测脚本和基线进仓库；全清单 107,276 → 104,824（−2,452，方案估 −2,100）。真客户端小测（任务 1、4、5、7，Codex 和 Claude Code 各一遍）等安排，每次开跑前问用户 |
| 4–5 | 未做 | 两批搬完：名片 ≤ 450（目标 350）、参数说明 ≤ 120（目标 80）、主题写全（先把说明原样搬进主题、再写名片） |
| 6 `chore/mcp-catalog-budget` | 未做 | 收紧上限（全清单 100,000 等，方案 4.1）、三处 110,000 并成一处、文档 |
| 7 `feat/codex-schema-size-on-connect` | 未做 | 连接 Codex 时写 `tool_input_schema_max_bytes = 8192`（先实测） |

基线实测（方案 6.1，`7a9d8c9` 打的隔离测试 App）：Claude Code 一半 2026-11-10 跑完，见 [基线实测](2026-11-10-mcp-guide-baseline.md)（证据 JSON、实测脚本 `scripts/gui-smoke/client-measure/` 随 PR 3 进了仓库）；Codex 一半 2026-11-11 跑。
任务 7 在基线里换过题（原来点名「4K」，模型按工具说明带 `user_requested_overrides` 直接做、测不出「花钱要停下问」；改成「画质尽量好」），新旧两次都留。

## 本机跑检查时遇到的事

- 2026-11-10：本机负载高时（同时有别的会话在编译，load average 到 44），`scripts/check-mcp.sh` 的 `ListenRangeChecks` 里那条 2 秒期限的文件 listen
  偶尔超时，重跑就过；和说明书无关，CI 上没出现。同一天负载 20 多时，`check-mcp.sh` 编自检二进制一步要十几分钟（平时半分钟）。
- 换分支之后 `.build` 里会留下另一条分支才有的目标文件（`SrtFlowMCPKit.build/*.o`），`check-mcp.sh` 按通配符链接它们会报「Undefined symbols」；
  删掉源文件已经不在的那几个 `.o` 再编就好。CI 每次都是干净的检出，不受影响。
