#!/usr/bin/env bash
# 生成任务必须知道工程归属；卡片和 MCP 共用分组，类型不能从翻译后的文字猜。
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "✗ cloud-task-projects：$1" >&2; exit 1; }
BASE=Sources/SrtFlow/CloudMedia
for file in CloudTaskGrouping CloudTaskReport CloudTaskStatusSnapshot CloudTaskProjectCard CloudTaskRow CloudTasksPopover; do
  [ -f "${BASE}/${file}.swift" ] || fail "缺少 ${file}.swift"
done
for file in Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift \
            Sources/SrtFlow/AIUpscaleTool.swift Sources/SrtFlow/Upscale/UpscalePanel.swift; do
  grep -qF 'owner: CloudTasksActivity.owner(of: project)' "${file}" || fail "${file} 起任务时没固定工程归属"
done
grep -qF 'let owner: CloudTaskOwner' Sources/SrtFlow/SkyStudio/SkyStudioMediaStatus.swift || fail '生成状态没有不可变的工程归属'
grep -qF 'let mediaKind: CloudTaskMediaKind' Sources/SrtFlow/SkyStudio/SkyStudioMediaStatus.swift || fail '生成状态没有类型化的媒体种类'
grep -qF 'grouping.group(for: project.documentGeneration)' "${BASE}/CloudTasksButton.swift" || fail '工具栏的本工程数量没按工程代号取'
grep -qF 'activity.summary.activeCount' "${BASE}/CloudTasksButton.swift" || fail '总数必须只算进行中的任务'
grep -qF '$0.owner.generation == group.id' "${BASE}/CloudTaskProjectCard.swift" || fail '卡片里没按工程过滤任务'
grep -qF 'guard let current = CloudTasksActivity.project(for: group.owner)' "${BASE}/CloudTaskProjectCard.swift" || fail '打开工程之前没重新核对原工程'
grep -qF 'OpenProjects.shared.focus(current)' "${BASE}/CloudTaskProjectCard.swift" || fail '打开后台工程没复用现有窗口入口'
grep -qF '$0.documentGeneration == owner.generation' "${BASE}/CloudTasksActivity.swift" || fail '工程打开按钮不能只按短 id 找'
grep -qF 'mediaKind.systemImage' "${BASE}/CloudTaskRow.swift" || fail '任务缺少媒体类型图标'
if grep -nE 'Button\("Cancel"\)|run\.cancel\(|job\.cancel\(' "${BASE}/CloudTaskRows.swift" "${BASE}/CloudTaskRow.swift"; then
  fail '用户选定的任务浮层暂不放取消按钮'
fi
grep -qF 'CloudTaskStatusSnapshot.read()' Sources/SrtFlow/AIProjectTools.swift || fail 'get_status 没读取任务详情快照'
grep -qF '"cloud_tasks": cloudTasks.json()' Sources/SrtFlow/AIProjectTools.swift || fail 'get_status 没回全局工程任务详情'
grep -qF 'cloudTasks.summary(for: project.documentGeneration)' Sources/SrtFlow/AIProjectSessions.swift || fail '工程清单没回自己的任务汇总'
grep -qF 'and cloud_tasks grouped by project:' Sources/SrtFlowMCPKit/MCPProjectTools.swift || fail 'get_status 的说明没告诉 AI 怎么查工程任务'
for file in Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift; do
  grep -qF 'status.aiJobID = job.id' "${file}" || fail "${file} 没给状态绑定 get_job 的真实任务号"
done
grep -qF 'job.aiJobID = aiJob.id' Sources/SrtFlow/AIUpscaleTool.swift || fail 'AI upscale 的状态没绑定真实任务号'
echo '✓ cloud-task-projects：工程归属、类型图标、分组卡片、原工程开窗与 MCP 只读详情接线完整'
