# 2026-11-04 清理脚本自检删除活动冒烟 App 的 MCP socket

## 症状

全量检查与独立后台 MCP 验收同时运行时，测试 App 进程仍在、Unix socket 描述符仍开着，
但 socket 路径已消失，新 helper 报 SkyCut 未运行。真实用户 App 与付费服务未受这条清理路径影响。
当时另有一次工具调用超时，单凭路径消失不足以解释已连接请求的全部等待，需独立复测。

## 根因

`SmokeClientChecks.test_cleanup_preserves_unrelated_process` 为验证旧 PID 不会杀错进程，调用实际
`run.sh stop`，仅替换了 `security`、`defaults` 和 `pkill`。`SKYSTUDIO_SMOKE_DIR` 隔离的是夹具目录，
`SUPPORT` 仍指向本机 `.skystudiosmoke` 目录；未替换的 `rm` 删除了活动测试 App 的 provider 文件与 socket。

## 修复

清理脚本自检也隔离 `rm`：只允许删除本测试的两份 PID 文件，记录并阻断共享支持目录路径。
用临时目录中真实 Unix socket 验证外部文件仍存在，不能靠“测试 App 通常没启动”获得假安全。
不修改用户 HOME，不放宽生产清理器的归属检查。

## 验证

专项 8 项通过；在保留独立夹具外层边界的隔离副本中撤掉自有路径保护，Unix socket 哨兵检查
明确变红（1 / 8 失败），没有触碰真实支持目录。重跑后台 MCP 与全量结果记入
[实施报告](../reports/2026-11-04-official-film-client.md)。超时运行明确保留为失败；
只有独立重跑并检查服务端准入、原请求与完整工具结果之后才报告通过。

## 教训 / 防回归

测试被测清理器时，进程、钥匙串、偏好与文件删除都必须受夹具边界约束。
只替换部分命令仍可能污染同机验收。长期规则见
[GUI 冒烟流程](../testing/gui-smoke-testing.md)「云端媒体的端到端冒烟」。
