#!/usr/bin/env bash
# 本地改完代码、推之前跑的那一步：全部扫描守卫 + 和这次改动直接相关的几项检查，一项一项跑。
#
# 2026-11-04 用户定：本地不再全跑 scripts/check-all.sh（满载十几到三十分钟，笔记本烫）。完整的那一遍交给 CI ——
# 每个 PR 上 5 台 runner 全跑、绿了才合，步骤一样不少，只是不在笔记本上重复跑。本地这一步是为了早点发现问题、
# 少等一轮 CI：扫描守卫秒级、不编译（搬代码 / 改名之后漏掉的接线最常在这里红），再加上你改的那块的检查。
#
# 一律用原生 arm64 的 /bin/bash 跑（同 CI 和 check-all.sh）：在 Rosetta 下又慢又烫，见 scripts/native-arch.sh。
#
# 用法：
#   scripts/check-local.sh timeline-snap project-file   # 扫描守卫 + scripts/check-timeline-snap.sh + scripts/check-project-file.sh
#   scripts/check-local.sh checks/foo.sh core           # 也可以写路径；core = swift run SrtFlowCoreChecks（改了核心库时）
#   scripts/check-local.sh                              # 只跑扫描守卫
# 名字先找 scripts/check-<名字>.sh，再找 checks/<名字>.sh。哪一项红了都照样跑完，最后退出码非 0。
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."

FAILED=""
run_one() {
  local label="$1" started
  shift
  echo ""
  echo "━━━ ${label} ━━━"
  started="$(date +%s)"
  if "$@"; then
    echo "✓ ${label}（$(($(date +%s) - started))s）"
  else
    echo "✗ ${label} 失败（$(($(date +%s) - started))s）" >&2
    FAILED="${FAILED} ${label}"
  fi
}

run_one "扫描守卫（scripts/check-guards.sh）" /bin/bash scripts/check-guards.sh
for name in "$@"; do
  if [ "${name}" = "core" ]; then
    run_one "SrtFlowCoreChecks" swift run --arch arm64 SrtFlowCoreChecks
  elif [ -f "${name}" ]; then
    if [ "${name%.py}" != "${name}" ]; then
      run_one "${name}" python3 "${name}"
    else
      run_one "${name}" /bin/bash "${name}"
    fi
  elif [ -f "scripts/check-${name}.sh" ]; then
    run_one "scripts/check-${name}.sh" /bin/bash "scripts/check-${name}.sh"
  elif [ -f "checks/${name}.sh" ]; then
    run_one "checks/${name}.sh" /bin/bash "checks/${name}.sh"
  else
    echo "✗ 找不到检查「${name}」：试过 scripts/check-${name}.sh、checks/${name}.sh" >&2
    FAILED="${FAILED} ${name}"
  fi
done

echo ""
if [ -n "${FAILED}" ]; then
  echo "✗ check-local：红了的有${FAILED}" >&2
  exit 1
fi
echo "✓ check-local：扫描守卫和点名的 $# 项都绿（完整的一遍在 CI 上跑）"
