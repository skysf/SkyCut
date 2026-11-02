# 2026-11-02 helper 更新清单不等于客户端已发现新工具

## 症状

安装版有 55 个工具，旧会话只暴露 50 个，`export_video` 参数也停在旧版。原升级提示声称清单已经刷新，
让调用方误以为继续对话即可得到新能力。

## 根因

工具定义编在 helper，helper 随客户端会话存活。App 升级不会替换已运行的 helper 或模型上下文。
已有同步逻辑能让 helper 在工具调用后采用 App 的完整定义并发送通知，但不能保证客户端重新发现。
原提示、旧架构说明把 helper 采用、通知发出和客户端采用混为一谈；既有回归只验证新增工具名，没单独钉住已有工具的 schema。

## 修复

- 升级结果明确只确认 helper 已采用当前定义，客户端可能仍缓存；缺工具 / 参数时重连并创建新会话。
- `get_status.mcp_catalog` 返回实际清单数量和指纹，提供对照依据；不复制第二份工具清单。
- 真 helper 回归同时验证已有 `export_video` 的新参数枚举与参数转发。
- 恢复流程和人工验收写入 [MCP 功能发现](../architecture/mcp-discovery.md)。

## 验证

本机正在运行 App `0.18.56-local.20261102.2247.g0207d5f`；全新已安装 helper 进程和本轮 Codex
包装层均为 55 项。已安装 helper 的 `export_video` 包含 `preset`、`encoder`、`resolution`、`quality`。
没有发现本轮包装层按 50 项截断。历史旧会话没有保留完整客户端传输日志，不能倒推是通知未送达还是客户端未采用。

真实客户端：Codex CLI 0.166.0，沿用本机默认 GPT-6.1-Sol / max；连接独立
`.skystudiosmoke` App 和回环假账号，只暴露空工程 / 合成夹具，不发送用户现有工程或生产 Key。

| 路径 | 客户端实际请求 / 看到的内容 |
| --- | --- |
| 新 helper + 新 Codex 会话 | `tools/list` 一次，55 项；模型确认五个新增工具及导出全部 9 个参数 |
| 历史 `2fa04cb` helper + 当前 App | 初次 50 项；`get_status` 后收到一次 `list_changed`；Codex **没有再次请求**清单，模型仍报 50 项、导出 6 个参数 |
| 退出该 CLI、使用当前 helper，resume 同一测试对话 | 握手后重新 `tools/list`，55 项；模型拿到新定义，历史对话保留 |
| 同一历史 helper 进程、显式重新 `tools/list` | 从 50 变成 55，导出 schema 更新；新增 `set_texts` 实际改独立工程成功，`inspect_video` 任务完成，审阅导出完成 |

旧 helper 的实际导出传了 `preset=quick_review`、`encoder=hardware`、`quality=small`、`resolution=480p`；
`get_job` 返回 VideoToolbox / AAC128 / 480p 的真实任务设置。文字夹具的检查任务完成但
`coverage_complete=false`，不据此声称所有检查通过；完整音频场景留给自然语言验收。
此证据定位了本机 CLI 的客户端缓存边界；原用户会话没有传输日志，不声称复原了它的每一步。

- `scripts/check-mcp.sh`：3,081 项通过。临时恢复旧刷新提示，新增守卫实际变红（1 / 3,081）；恢复后全套复验。
- 首次沙箱编译因系统 Swift cache 不可写失败，不计通过；在允许访问编译缓存的环境重跑成功。
- `scripts/check-all.sh`：81 项通过、1 项既有看门狗回调计数失败（0 vs 1）；其代码未改，整套结束后单独复跑 26/26 通过。
  不把首轮称作全绿。`scripts/check-guards.sh` 全部通过；远端 `check-all` 必须绿后合并。

## 教训 / 防回归

服务端清单、helper 采用、客户端重新请求和模型实际调用是不同证据。必须逐层验证；
恢复步骤不能依赖 AI 有一个当前会话并不存在的“重新加载工具”能力。
