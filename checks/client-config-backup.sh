#!/usr/bin/env bash
# 连接 AI 客户端时改配置文件，第一次改之前的备份只经 AIClientConfigWrite 写（一建出来就和原文件同样的权限）：
# 以前 AIClientSetup 另写一个新文件当备份，600 的原文件备份成谁都能读的 644
#（docs/bugfixes/2026-10-27-client-config-backup-world-readable.md）。行为在 checks/MCP/ConfigBackupChecks.swift（scripts/check-mcp.sh）。
# 秒级扫描，不编译。
set -euo pipefail
cd "$(dirname "$0")/.."

WRITERS="$(grep -rlF 'skycut-backup' Sources | LC_ALL=C sort | tr '\n' ' ' || true)"
if [ "${WRITERS}" != "Sources/SrtFlow/AIClientConfigWrite.swift " ]; then
  echo "✗ 只有 Sources/SrtFlow/AIClientConfigWrite.swift 许写 .skycut-backup，现在是：${WRITERS:-（没有）}" >&2
  exit 1
fi
if [ "$(grep -cF 'try AIClientConfigWrite.rewrite(path, transform)' Sources/SrtFlow/AIClientSetup.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/AIClientSetup.swift 改客户端配置没经 AIClientConfigWrite.rewrite：备份的权限又会变宽" >&2
  exit 1
fi
echo "✓ client-config-backup：客户端配置的备份只经 AIClientConfigWrite 写（权限和原文件一样）"
