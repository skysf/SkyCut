#!/usr/bin/env bash
# 收费迁移第 7 刀：生产不再包含 fal 自带 Key、设置、模型表与网络路径。
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "✗ $1" >&2; exit 1; }
[ ! -d Sources/SrtFlow/Fal ] || fail '旧 Fal 目录不应存在；共用部分在 CloudMedia'
found="$(grep -R -nE 'Fal(Client|KeyStore|KeyCache|Settings|Models|Inputs|Outputs)|queue\.fal\.run|SRTFLOW_FAL_QUEUE_BASE|case fal$' Sources || true)"
[ -z "$found" ] || fail "生产中仍有旧 fal 路径：$found"
for item in CloudJobPhase CloudPhaseText CloudTasksButton CloudTasksActivity CloudTaskRows CloudTaskSummary CloudTransfer DailySpend; do
  [ -f "Sources/SrtFlow/CloudMedia/$item.swift" ] || fail "缺少仍在生产使用的共用组件：$item"
done
grep -qF 'CloudTasksButton(project: project).equatable()' Sources/SrtFlow/VideoEditView.swift || fail '云端任务入口必须知道自己在哪个工程窗口'
if grep -qE 'CloudStatusRows|CloudTaskRows' Sources/SrtFlow/AIActivityBanner.swift; then
  fail '云端任务不得再逐行挤占预览区'
fi
grep -qF '.popover(isPresented:' Sources/SrtFlow/CloudMedia/CloudTasksButton.swift || fail '任务入口没有打开锚定浮层'
# 2026-10-31 用户定：任务浮层暂不放取消，停止 / cancel_job 的真实取消路径仍保留。
grep -qF 'guard run.issue == nil else { return }' Sources/SrtFlow/SkyStudio/SkyStudioGenerationActivity.swift || fail '生成失败 / 未知扣费提示不能随任务结束消失'
grep -qF 'if stop != .nothingCharged { status.issue = message }' Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift || fail '明确未扣费的取消不能误留警示'
grep -qF 'if status == .failed || creditsUnconfirmed {' Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift || fail '不得仅按请求已发出就把取消当作未知扣费'
grep -qE 'object.merge\(job.liveDetail\(\)\)' Sources/SrtFlow/AIJobs.swift || fail '任务实时明细未接到 get_job'
grep -qE 'AIJobs.shared.cancel\(stoppingWith: projectID\)' Sources/SrtFlow/AIRound.swift || fail '停止必须按工程取消任务'
[ -f scripts/gui-smoke/mcpclient.py ] || fail '共享 MCP 冒烟客户端丢了'
[ ! -d scripts/gui-smoke/fal ] && [ ! -d scripts/fal-models ] && [ ! -d checks/Fal ] || fail '旧 fal 夹具 / 快照 / 刷新脚本未清理'
# 工程卡片属于现行任务入口；统一总检查经本项把工程 / MCP 接线一起守住。
# shellcheck source=checks/cloud-task-projects.sh
source checks/cloud-task-projects.sh
echo '✓ no-legacy-generation：只保留现行云端路径与共用媒体组件'
