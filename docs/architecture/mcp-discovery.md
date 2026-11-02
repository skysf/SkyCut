# MCP 功能发现与升级后的重连

清单只有 `MCPToolName` 一份。判断能不能用新能力，要分别检查 App、helper、客户端交给模型的工具定义；
`tools/list` 成功或发出 `list_changed`，都不能单独证明模型已经拿到新工具和参数。

## 三层核对

1. **App**：`get_status` 的 `app_version`、`mcp_catalog.tool_count` / `fingerprint` 是正在运行的 App 的实际值。
   指纹覆盖整份定义，包括已有工具的参数。不能把工具数相同当成 schema 一样。
2. **helper**：客户端配置的 `command` 应指向正在使用的那份 `SkyCut.app/Contents/Helpers/skycut-mcp`。
   新进程第一次列的是编进去的清单，不启动 App。首次工具调用后，App 指纹不同时，带同步逻辑的 helper
   向 App 取完整清单并原样替换，包括已有工具的 schema；之后的 `tools/list` 才是它采用的新清单。
   同步逻辑加入之前的 helper 必须退出重启。
3. **客户端 / 包装层**：检查模型实际可调用的名字及参数，特别是 `export_video.preset` / `encoder` /
   `resolution` / `quality`。检查是否配置了 `enabled_tools` / `disabled_tools`，以及是否连到别的 App 副本。
   `codex mcp list` 只显示服务器配置，不能证明当前会话拿到了完整 schema。

App 升级后，helper 在一次已有工具调用（可用 `get_status`）后采用新清单，并给旧协议客户端发送
`notifications/tools/list_changed`。新协议的 TTL 也是缓存建议。是否重新请求、是否把结果重新交给模型，
由客户端决定。总说明只在握手 / discover 时给出；helper 的采用动作不会替换旧上下文里的说明。

## 可执行的恢复步骤

- 先保存工作。确认客户端的 SkyCut 连接指向当前 App；若显示“连着另一份”，在该 App 的
  设置 → 连接 AI 中重新连接对应客户端。
- Codex CLI：结束运行中的 CLI，重新启动并创建新会话；用 `/mcp` 核对连接。诊断可用一次全新的
  `codex exec`，不要把继续同一轮对话当成刷新。本机 CLI 0.166.0 也实测支持：退出旧进程，
  确认 command 指向当前 helper，再 `codex exec resume <session-id>`，同一历史对话会重新发现当前定义。
- 桌面客户端：在 MCP 设置里重启 SkyCut 服务器 / 连接，再创建新会话。客户端没有重启连接按钮时，
  完全退出并重新启动客户端。IDE 扩展对应 Restart extension。
- 在新会话实际确认需要的工具名和参数，再在独立工程中调用。只说“重新列一下”、只重开 SkyCut，
  或只等一分钟，均不能保证客户端清掉旧定义。

依据：[官方 MCP 配置与重启说明](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)说明各客户端的重启入口和
过滤配置；[官方插件说明](https://developers.openai.com/api/docs/guides/agents-api/tools/plugins)明确旧插件会话不会重新加载工具。
插件说明的结论不自动推广为每个 stdio 客户端的实现；本机实际结果另记在验证报告中。
本机 CLI 的 50 → 55 项、通知未引发重读、退出后 resume 成功的逐层证据见
[本次案例](../bugfixes/2026-11-02-mcp-catalog-refresh-reporting.md)。

## 回归口径

自动化：`scripts/check-mcp.sh` 的 `CatalogSyncChecks` 真起 helper，核对新工具、已有工具的新参数枚举、
调用参数原样转发、通知只发一次，以及指纹相同不取清单。假 App / 主动重新 `tools/list` 只证明 helper 合同。

真实客户端验收必须另留证据：

- [ ] 新会话实际暴露的工具名和 schema 与实际清单相符；能调用新增工具和导出覆盖参数。
- [ ] 升级前的 helper 在同一进程内采用新清单；记录客户端是否再次 `tools/list`，不要替它推断。
- [ ] 若旧客户端缓存未更新，执行上述退出重启 + 新会话后实调成功。
- [ ] 用自然语言选工具，记录实际调用、参数、任务结局；不能只填预期答案。
- [ ] 编辑用独立工程，始终带 `project`，对用户现有工程做前后哈希核对。
