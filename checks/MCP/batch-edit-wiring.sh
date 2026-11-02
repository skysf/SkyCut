#!/usr/bin/env bash
# check-mcp 的扫描一节：批量编辑确实复用单项规则，校验后只提交一次，不在循环中执行单项工具。
# 纯值与真的 UndoManager 在 BatchEditChecks.swift 验；此处钉生产接线，不能用纯值通过代替接好生产路径。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

python3 - <<'PY'
from pathlib import Path
import re

failures = []


def read(name):
    path = Path(name)
    if not path.is_file():
        raise SystemExit(f"✗ 批量编辑守卫找不到 {name}")
    return path.read_text()


def require(body, text, label, count=1):
    if body.count(text) != count:
        failures.append(label)


router = read('Sources/SrtFlow/AIToolRouter.swift')
tools = read('Sources/SrtFlow/AIBatchEditTools.swift')
plans = read('Sources/SrtFlow/AIBatchEditPlans.swift')
commit = read('Sources/SrtFlow/AIBatchEdit.swift')
clip = read('Sources/SrtFlow/AIClipTools.swift')
overlay = read('Sources/SrtFlow/AIOverlayTools.swift')
for tool in ['editClips', 'setTexts', 'setShapes']:
    if len(re.findall(r'\.' + tool + r'(?=[,:])', router)) != 2:
        failures.append(f'{tool} 必须接到路由和编辑策略')
require(router, 'let plan = try await AIBatchEditTools.planClips(args, project)', '批量片段先异步准备')
require(router, 'return try AIBatchEditTools.applyClips(plan, project)', '批量片段再同步提交')
for name in ['setTexts', 'setShapes']:
    require(router, f'return try AIBatchEditTools.{name}(args, project)', f'{name} 路由没交给批量入口')
require(tools, 'project.perform(', '批量工具只许有一个 perform 提交点')
require(tools, 'edit.commit(current: project.state, undo: project.effectiveUndoManager)', '共同提交点核对当前状态并使用工程自己的撤销管理器')
for call in ['commit(plan.batch.edit, project, rebuildsPreview: true)',
             'commit(plan.edit, project, rebuildsPreview: false)']:
    require(tools, call, '片段只更新一次预览；文字 / 形状沿用叠层刷新', count=2 if 'false' in call else 1)
require(commit, 'guard current == before else', '提交前必须拒绝过期快照')
require(commit, 'guard changed else', '整批没变不提交')
require(commit, 'AIUndoGrouping.step(undo) { perform(next) }', '同步提交只包一次撤销组')
require(tools, 'project.isCurrentGeneration(plan.generation)', '异步批量准备后必须核对工程代号')
require(tools, 'project.linkageEnabled == plan.linkage', '异步批量准备后必须核对联动开关')
require(tools, 'AIClipTools.plan(item, project, state: plan.batch.edit.next)', '批量片段复用单项准备，按候选时间线算轨道和取景')
require(plans, 'plan.applying(to: edit.next', '批量片段复用单项的候选计算')
require(clip, 'plan.applying(', '单项片段也必须走共同的候选计算')
for name in ['text', 'shape']:
    require(plans, f'AIOverlayEdits.{name}(', f'批量 {name} 必须复用共同编辑')
    require(overlay, f'AIOverlayEdits.{name}(', f'单项 {name} 必须复用共同编辑')
for forbidden in ['AIClipTools.apply(', 'AIOverlayTools.setText(', 'AIOverlayTools.setShape(', 'scheduleRebuild(']:
    if forbidden in tools:
        failures.append('批量入口不能逐项提交或另重建预览：' + forbidden)
if failures:
    for failure in failures:
        print('✗ ' + failure)
    raise SystemExit(1)
print('   ✓ 批量编辑：三条路由、单项复用、整批校验、一次同步提交与撤销，预览只走 perform 收尾')
PY
