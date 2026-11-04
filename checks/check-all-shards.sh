#!/usr/bin/env bash
# 扫描守卫：scripts/check-all.sh 的检查清单和分组。
#
# 一、checks/ 顶层的每一条扫描守卫都要在 check-all.sh 里跑（某一行 run_check 的命令里点名它）。
#    为什么：scripts/check-guards.sh 按通配符跑 checks/*.sh，推之前本地看到的是全绿；可 CI 只跑 check-all.sh
#    里列着的那些。2026-11-04 查出 sky-studio-wiring、cloud-task-projects、region-framing-wiring、
#    voiceover-sync-wiring 四条从加上那天起就没进过 check-all —— CI 一次都没跑过它们，sky-studio-wiring 的
#    文件头和文档还写着「进 check-all 第 1 组」（docs/bugfixes/2026-11-04-scan-guards-never-ran-in-ci.md）。
#    要故意不进 CI 的检查（要图形会话、要真钥匙串）写成 scripts/check-*.sh，不放 checks/ 顶层。
#
# 二、第 1 组只放「完整 App」那一摊，「完整 App」那一摊也只放第 1 组。「完整 App」指两样：「App 编得过」那一项
#    （不带 --target / --product 的 swift build），和要链接完整 App 目标文件的检查（脚本里有
#    SrtFlow.product/Objects.LinkFileList 或 --product SrtFlow）。
#    为什么：CI 上只有第 1 组那台先冷编完整 App（2026-11 约 2 分 10 秒到 2 分 45 秒），检查跑完还要起这个 App 跑
#    3 分钟的性能 ratchet，是最慢的一组。要链接完整 App 的检查放到别的组，那台就得为它再冷编一遍整个 App；
#    扫描守卫、纯值检查放进第 1 组，就是往最慢的那组上加。2026-11-04 第 1 组跑了 10 分 46 秒、别的组 3 分半到 5 分半，
#    两样都有（docs/build/build-and-packaging.md「CI」一节）。
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

# 每条 run_check 一行：「组号␟命令」（␟ 是 \037；命令是去掉开头的 `run_check "名字"` 之后剩下的）。行首不是
# run_check 的（注释掉的、函数定义）不算；组号是它上面最近的一行 `shard N`，上面一行都没有就是 1（同 check-all.sh
# 的 CURRENT_SHARD=1）。不用 TAB 分隔：TAB 算 IFS 里的空白，空的一栏会被并掉、后面几栏整体错位。
ROWS="$(awk '
  BEGIN { shard = 1 }
  /^shard [0-9]+$/ { shard = $2; next }
  /^run_check "/ { sub(/^run_check "[^"]*"[[:space:]]*/, ""); print shard "\037" $0 }
' "${CHECK_ALL}")"
if [ -z "${ROWS}" ]; then
  fail "${CHECK_ALL} 里一条 run_check 都没读到：写法变了就改这条守卫（扫空 = 假绿）"
fi

# ---- 一、checks/ 顶层的每一条守卫都在清单里 ----
GUARDS=0
for guard in checks/*.sh; do
  [ -f "${guard}" ] || continue
  GUARDS=$((GUARDS + 1))
  # 按词比：命令里有一个字段正好是这个路径（`checks/x.sh`、`bash checks/x.sh` 都算）。
  listed="$(awk -F '\037' -v path="${guard}" '{ n = split($2, w, " "); for (i = 1; i <= n; i++) if (w[i] == path) { print "yes"; exit } }' <<<"${ROWS}")"
  if [ "${listed}" != "yes" ]; then
    fail "${guard} 不在 ${CHECK_ALL} 里：CI 只跑 check-all 列着的检查，它在 CI 上一次都不会跑（本地 check-guards 照样是绿的）。照 check-all.sh 开头的分组规矩加一行 run_check"
  fi
done
if [ "${GUARDS}" -eq 0 ]; then
  fail "checks/ 下一条守卫都没找到：目录搬了就改这条守卫（扫空 = 假绿）"
fi

# ---- 二、「完整 App」那一摊和第 1 组互相对得上 ----
# 这一条算不算「完整 App」：1 = 是，0 = 不是。
needs_full_app() {
  local command="$1" word uses
  # shellcheck disable=SC2086
  set -- ${command}
  if [ "${1:-}" = "swift" ] && [ "${2:-}" = "build" ]; then
    case " ${command} " in
      *" --target "* | *" --product "*) ;;
      *) echo 1; return ;;
    esac
  fi
  for word in ${command}; do
    case "${word}" in
      *.sh | *.py) ;;
      *) continue ;;
    esac
    # 只看不是注释的行（这条守卫自己的注释里就写着这两个词）；--product 要和 swift build 在同一行才算。
    if [ -f "${word}" ]; then
      uses="$(grep -vE '^[[:space:]]*#' "${word}" \
        | grep -cE 'Objects\.LinkFileList|swift build[^#]*--product SrtFlow([^A-Za-z0-9_-]|$)' || true)"
      if [ "${uses:-0}" -gt 0 ]; then
        echo 1
        return
      fi
    fi
    break
  done
  echo 0
}

APP_IN_SHARD_1=0
while IFS="$(printf '\037')" read -r shard command; do
  [ -n "${command}" ] || continue
  app="$(needs_full_app "${command}")"
  if [ "${shard}" = "1" ] && [ "${app}" = "1" ]; then
    APP_IN_SHARD_1=$((APP_IN_SHARD_1 + 1))
  elif [ "${shard}" = "1" ]; then
    fail "第 1 组只放「完整 App」那一摊，「${command}」不要完整 App：放进第 2–5 组里最空的那组（第 1 组要背冷编 App 和性能 ratchet，是最慢的一组）"
  elif [ "${app}" = "1" ]; then
    fail "「${command}」要完整 App（编它或链接它的目标文件），只能放第 1 组：放在第 ${shard} 组，那台 runner 要为它再冷编一遍整个 App"
  fi
done <<<"${ROWS}"
if [ "${APP_IN_SHARD_1}" -eq 0 ]; then
  fail "第 1 组里一条「完整 App」的检查都没认出来（至少该有「App 编得过」那一项）：写法变了就改这条守卫（扫空 = 假绿）"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ check-all-shards：checks/ 下 ${GUARDS} 条守卫都在 check-all 里；第 1 组正好是 ${APP_IN_SHARD_1} 项要完整 App 的检查，别的组一项都没有"
