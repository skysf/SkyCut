#!/usr/bin/env bash
# 收费迁移第 7 刀：生产不再包含 fal 自带 Key、设置、模型表与网络路径。
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "✗ $1" >&2; exit 1; }
[ ! -d Sources/SrtFlow/Fal ] || fail '旧 Fal 目录不应存在；共用部分在 CloudMedia'
found="$(grep -R -nE 'Fal(Client|KeyStore|KeyCache|Settings|Models|Inputs|Outputs)|queue\.fal\.run|SRTFLOW_FAL_QUEUE_BASE|case fal$' Sources || true)"
[ -z "$found" ] || fail "生产中仍有旧 fal 路径：$found"
for item in CloudJobPhase CloudStatusRows CloudTransfer DailySpend; do
  [ -f "Sources/SrtFlow/CloudMedia/$item.swift" ] || fail "缺少仍在生产使用的共用组件：$item"
done
grep -qE 'CloudStatusRows\(\)' Sources/SrtFlow/AIActivityBanner.swift || fail '云端任务状态行没有挂在横幅中'
grep -qE 'object.merge\(job.liveDetail\(\)\)' Sources/SrtFlow/AIJobs.swift || fail '任务实时明细未接到 get_job'
grep -qE 'AIJobs.shared.cancel\(stoppingWith: projectID\)' Sources/SrtFlow/AIRound.swift || fail '停止必须按工程取消任务'
[ -f scripts/gui-smoke/mcpclient.py ] || fail '共享 MCP 冒烟客户端丢了'
[ ! -d scripts/gui-smoke/fal ] && [ ! -d scripts/fal-models ] && [ ! -d checks/Fal ] || fail '旧 fal 夹具 / 快照 / 刷新脚本未清理'
echo '✓ no-legacy-generation：只保留现行云端路径与共用媒体组件'
