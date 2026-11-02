#!/usr/bin/env bash
# 参数 / 媒体的动态验收在 check-voiceover-sync；这里守生产复用与唯一提交接线。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 - <<'PY'
from pathlib import Path

def read(path):
    return Path(path).read_text()

failures = []
def require(body, needle, why):
    if needle not in body:
        failures.append(why)

tool = read('Sources/SrtFlow/AIVoiceoverSyncTool.swift')
plan = read('Sources/SrtFlow/AIVoiceoverSyncPlan.swift')
batch = read('Sources/SrtFlow/AIBatchEditTools.swift')
router = read('Sources/SrtFlow/AIToolRouter.swift')
require(router, 'case .syncVoiceover: return try AIVoiceoverSyncTool(args, project).start()', '同步路由必须使用真实长任务入口')
require(router, '.addVoiceover, .syncVoiceover,', '同步必须加入工程编辑策略')
require(read('Sources/SrtFlow/AIProjectBinding.swift'), '.syncVoiceover,', '同步必须按调用方工程绑定')
require(tool, 'MediaProbeCache.measuredAudioDuration', '时间必须实测，不用旧缓存或 PCM 单次帧数')
require(tool, 'SkyStudioVoiceAudio.transcribe', '字幕复用已有本机转写')
require(plan, 'var edit: AIBatchEdit', '同步计划必须复用现有批量事务')
require(plan, 'AIClipEditPlan(', '画面复用单项片段编辑')
for kind in ['text', 'shape']:
    require(plan, f'AIOverlayEdits.{kind}(', '文字 / 形状复用单项规则')
require(plan, 'checksOverlap: false', '同时变长时只在完整候选上检查冲突')
require(plan, 'AITimelineEdits.conflict(', '最终必须检查片段冲突')
require(tool, 'try plan.validate()', '所有提交前必须全量校验')
require(tool, 'project.state == before', '异步准备后拒绝过期时间线')
require(tool, 'project.isCurrentGeneration(generation)', '异步准备后拒绝换工程')
require(tool, 'AIBatchEditTools.commit(plan.edit, project, rebuildsPreview: true, alreadySettled: true)', '只经原批量提交点，明确禁止二次联动')
require(batch, 'if alreadySettled', '已结算的候选必须走原样采用的分支')
require(batch, 'project.restoreTimeline(next)', '已结算候选复用已有快照采用，不能再磁吸 / linkage')
require(tool, 'AISession.shared.round(for: project).noteChange()', '异步提交完成必须记进这一轮')
require(tool, 'AIProjectTools.saveIfNeverSaved', '异步提交完成保留现有存盘合同')
for shared in ['VideoEditProject.extractFrame', 'project.writeFreezeImage', 'StillImageClipFactory.stillVideo', 'clip.makeFreezeClip']:
    require(tool, shared, '末帧定格复用已有实现：' + shared)
for forbidden in ['project.perform(', 'AIUndoGrouping.step(', 'scheduleRebuild(', 'SkyStudioAPI', 'SkyStudioVoiceoverRun']:
    if forbidden in tool:
        failures.append('同步入口不能另起提交 / 撤销 / 付费机制：' + forbidden)
require(read('scripts/check-all.sh'), 'scripts/check-voiceover-sync.sh', '实际 App 对象验收必须进总入口')
if failures:
    for failure in failures:
        print('✗ ' + failure)
    raise SystemExit(1)
print('   ✓ 旁白同步：实测音频、原稿对齐、共用批量事务、全量校验、不重复联动、定格复用')
PY
