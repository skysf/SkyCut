#!/usr/bin/env bash
# 扫描守卫：scripts/check-all.sh 的检查清单。
#
# 一、checks/ 顶层的每一条扫描守卫都要在 check-all.sh 里跑（某一行 run_check 的命令里点名它）。
#    为什么：scripts/check-guards.sh 按通配符跑 checks/*.sh，推之前本地看到的是全绿；可 CI 只跑 check-all.sh
#    里列着的那些。2026-11-04 查出 sky-studio-wiring、cloud-task-projects、region-framing-wiring、
#    voiceover-sync-wiring 四条从加上那天起就没进过 check-all —— CI 一次都没跑过它们，sky-studio-wiring 的
#    文件头和文档还写着「进 check-all 第 1 组」（docs/bugfixes/2026-11-04-scan-guards-never-ran-in-ci.md）。
#    要故意不进 CI 的检查（要图形会话、要真钥匙串）写成 scripts/check-*.sh，不放 checks/ 顶层。
#
# 用法：checks/check-all-shards.sh [check-all.sh 的路径]
#       路径只给反向验证用（拿一份改过的副本来试）；不给就读 scripts/check-all.sh。
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK_ALL="${1:-scripts/check-all.sh}"
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}

if [ ! -f "${CHECK_ALL}" ]; then
  echo "✗ 找不到 ${CHECK_ALL}" >&2
  exit 1
fi

# 每条 run_check 的命令部分（去掉开头的 `run_check "名字"`），一行一条。行首不是 run_check 的（注释掉的、
# 函数定义）不算。
COMMANDS="$(awk '/^run_check "/ { sub(/^run_check "[^"]*"[[:space:]]*/, ""); print }' "${CHECK_ALL}")"
if [ -z "${COMMANDS}" ]; then
  fail "${CHECK_ALL} 里一条 run_check 都没读到：写法变了就改这条守卫（扫空 = 假绿）"
fi

GUARDS=0
for guard in checks/*.sh; do
  [ -f "${guard}" ] || continue
  GUARDS=$((GUARDS + 1))
  # 按词比：命令里有一个字段正好是这个路径（`checks/x.sh`、`bash checks/x.sh` 都算）。
  listed="$(awk -v path="${guard}" '{ for (i = 1; i <= NF; i++) if ($i == path) { print "yes"; exit } }' <<<"${COMMANDS}")"
  if [ "${listed}" != "yes" ]; then
    fail "${guard} 不在 ${CHECK_ALL} 里：CI 只跑 check-all 列着的检查，它在 CI 上一次都不会跑（本地 check-guards 照样是绿的）。照 check-all.sh 开头的分组规矩加一行 run_check"
  fi
done
if [ "${GUARDS}" -eq 0 ]; then
  fail "checks/ 下一条守卫都没找到：目录搬了就改这条守卫（扫空 = 假绿）"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ check-all-shards：checks/ 下 ${GUARDS} 条守卫都在 check-all 里"
