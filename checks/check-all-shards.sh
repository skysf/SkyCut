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
# 2. Every run_check command appears exactly once: a check moved between shards must not run twice or be left behind.
#
# 3. No check script drops out of CI. Each scripts/check-*.sh is named by a run_check line, or by a step of the workflow's
#    shard job (the graphical steps, the docs-only fast path), or is on NOT_IN_CI below with its reason. Each executable
#    target named *Checks in Package.swift and each checks/*/*Checks.py is named by a run_check line. Why: rebalancing
#    moves lines between shards (2026-11-20, docs/build/build-and-packaging.md "CI"), and rule 1 only covered checks/*.sh.
#
# 4. Checks that need the full App sit in APP_SHARDS. "Full App" means the plain `swift build` line (no --target /
#    --product) and scripts that link SrtFlow.product/Objects.LinkFileList or build --product SrtFlow. Every shard
#    restores the same full-App build cache (checks/ci-build-cache-key.sh), so any shard could run them; shards 1-3
#    build the App anyway, while in shard 4 or 5 a single one adds an App build of one to four minutes.
#    (Until 2026-11-20 they all had to sit in shard 1, which grew to 27-28 minutes while the others took 8-11.)
#
# 5. The workflow's graphical steps, the playback start benchmark and the preview perf ratchet, each run exactly once
#    and only in the shard whose dedicated "Build app" step (exactly one plain `swift build`) builds the App before them.
#    Elsewhere the benchmark would build the App inside its six-minute timeout. That shard holds the lightest load in
#    check-all.sh, so re-running a timing flake costs about 13 minutes, not the longest shard.
#
# 6. Every actions/upload-artifact step in the workflow, in any job, has continue-on-error: true. Uploads are diagnostics;
#    on 2026-11-17 an artifact service timeout turned a shard whose checks had all passed red
#    (docs/bugfixes/2026-11-20-ci-artifact-upload-fails-green-shard.md).
#
# 用法：checks/check-all-shards.sh [check-all.sh 的路径 [workflow 路径]]
#       路径只给反向验证用（拿一份改过的副本来试）；不给就读 scripts/check-all.sh 和 .github/workflows/checks.yml。
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK_ALL="${1:-scripts/check-all.sh}"
WORKFLOW="${2:-.github/workflows/checks.yml}"
APP_SHARDS="1 2 3"
# Deliberately not run by CI (each also listed under 「不在 check-all.sh 里的」 in AGENTS.md).
NOT_IN_CI="
scripts/check-local.sh                  local entry point: the scan guards plus the checks it is given
scripts/check-filter-preview-attach.sh  graphical session, counts pixels of a real window
scripts/check-cover-preview-attach.sh   graphical session, counts pixels of a real window
scripts/check-instant-tooltip-panel.sh  graphical session, a real NSPanel
scripts/check-theme-switch.sh           graphical session, real windows switching themes
scripts/check-workbench-toolbar.sh      graphical session, toolbar pixels
scripts/check-keychain.sh               the real system keychain, never on CI
"
US="$(printf '\037')"
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}

for need in "${CHECK_ALL}" "${WORKFLOW}"; do
  if [ ! -f "${need}" ]; then
    echo "✗ 找不到 ${need}" >&2
    exit 1
  fi
done

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

# The shard job's steps, one per line: index␟if␟run (the first line of run).
STEPS="$(awk '
  /^  shard:/ { injob = 1; next }
  /^  [a-z-]+:/ { if (injob) { flush(); injob = 0 } }
  injob && /^      - / { flush(); n++; cur = n; sub(/^      - /, "        ") }
  injob && cur {
    line = $0
    if (line ~ /^        if:/) { sub(/^        if:[[:space:]]*/, "", line); cond = line }
    else if (line ~ /^        run:/) { sub(/^        run:[[:space:]]*/, "", line); run = line }
  }
  END { if (injob) flush() }
  function flush() {
    if (cur) print cur "\037" cond "\037" run
    cur = 0; cond = ""; run = ""
  }
' "${WORKFLOW}")"
if [ -z "${STEPS}" ]; then
  fail "${WORKFLOW} 里没读到分组 job（shard:）的步骤：写法变了就改这条守卫（扫空 = 假绿）"
fi

# Prints yes when a word of some run_check command is exactly $1 (`checks/x.sh` and `bash checks/x.sh` both count).
in_check_all() {
  awk -F '\037' -v path="$1" '{ n = split($2, w, " "); for (i = 1; i <= n; i++) if (w[i] == path) { print "yes"; exit } }' <<<"${ROWS}"
}

# ---- 一、checks/ 顶层的每一条守卫都在清单里 ----
GUARDS=0
for guard in checks/*.sh; do
  [ -f "${guard}" ] || continue
  GUARDS=$((GUARDS + 1))
  if [ "$(in_check_all "${guard}")" != "yes" ]; then
    fail "${guard} 不在 ${CHECK_ALL} 里：CI 只跑 check-all 列着的检查，它在 CI 上一次都不会跑（本地 check-guards 照样是绿的）。照 check-all.sh 开头的分组规矩加一行 run_check"
  fi
done
if [ "${GUARDS}" -eq 0 ]; then
  fail "checks/ 下一条守卫都没找到：目录搬了就改这条守卫（扫空 = 假绿）"
fi

# ---- 2. Each command exactly once ----
DUPLICATES="$(cut -d "$(printf '\037')" -f2 <<<"${ROWS}" | LC_ALL=C sort | uniq -d)"
if [ -n "${DUPLICATES}" ]; then
  while IFS= read -r command; do
    fail "「${command}」runs more than once in ${CHECK_ALL}: keep exactly one run_check line for it (moving a check between shards means cutting it from the old shard)"
  done <<<"${DUPLICATES}"
fi

# ---- 3. No check script drops out of CI ----
SCRIPTS=0
for script in scripts/check-*.sh; do
  [ -f "${script}" ] || continue
  SCRIPTS=$((SCRIPTS + 1))
  [ "$(in_check_all "${script}")" = "yes" ] && continue
  awk -F '\037' -v path="${script}" 'index($3, path) { found = 1 } END { exit !found }' <<<"${STEPS}" && continue
  awk -v path="${script}" '$1 == path { found = 1 } END { exit !found }' <<<"${NOT_IN_CI}" && continue
  fail "${script} runs nowhere on CI: no run_check line in ${CHECK_ALL} and no step of the shard job in ${WORKFLOW} names it. Add a run_check line to the emptiest shard, or, if it needs a graphical session or the real keychain, add it to NOT_IN_CI in this guard and to 「不在 check-all.sh 里的」 in AGENTS.md"
done
while read -r listed _; do
  [ -n "${listed}" ] || continue
  if [ ! -f "${listed}" ]; then
    fail "NOT_IN_CI in this guard lists ${listed}, which doesn't exist: remove the line"
  elif [ "$(in_check_all "${listed}")" = "yes" ]; then
    fail "NOT_IN_CI in this guard lists ${listed}, but ${CHECK_ALL} runs it: remove the line"
  fi
done <<<"${NOT_IN_CI}"
TARGETS="$(grep -oE 'name: "[A-Za-z0-9]+Checks"' Package.swift | sed -E 's/name: "(.*)"/\1/' || true)"
for entry in ${TARGETS} checks/*/*Checks.py; do
  [ -n "${entry}" ] || continue
  case "${entry}" in *'*'*) continue ;; esac
  if [ "$(in_check_all "${entry}")" != "yes" ]; then
    fail "${entry} runs nowhere on CI: add a run_check line for it to ${CHECK_ALL} (swift run --arch arm64 <target> / python3 <file>)"
  fi
done
if [ "${SCRIPTS}" -eq 0 ] || [ -z "${TARGETS}" ]; then
  fail "found ${SCRIPTS} scripts/check-*.sh and executable targets「${TARGETS}」: if the layout changed, change this guard (an empty scan passes everything)"
fi

# ---- 4. Full-App checks only in APP_SHARDS ----
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

FULL_APP=0
PER_SHARD=""
while IFS="$(printf '\037')" read -r shard command; do
  [ -n "${command}" ] || continue
  [ "$(needs_full_app "${command}")" = "1" ] || continue
  FULL_APP=$((FULL_APP + 1))
  PER_SHARD="${PER_SHARD} ${shard}"
  case " ${APP_SHARDS} " in
    *" ${shard} "*) ;;
    *) fail "「${command}」needs the full App, but sits in shard ${shard}: put it in one of shards ${APP_SHARDS}, which build the App anyway (here it adds an App build of one to four minutes to this shard)" ;;
  esac
done <<<"${ROWS}"
if [ "${FULL_APP}" -eq 0 ]; then
  fail "no check in ${CHECK_ALL} was recognized as needing the full App (at least the plain swift build line should be): if the layout changed, change this guard (an empty scan passes everything)"
fi

# ---- 5. The graphical steps run after the dedicated App build, in its shard ----
shard_of() { # the N of `matrix.shard == N` in an if, empty when the step runs in every shard
  sed -nE 's/.*matrix\.shard == ([0-9]+).*/\1/p' <<<"$1" | head -1
}
BUILD_AT="" BUILD_SHARD="" BUILDS=0
while IFS="$(printf '\037')" read -r index cond run; do
  [ -n "${index}" ] || continue
  case "${run}" in
    "swift build"*)
      case " ${run} " in *" --target "* | *" --product "*) continue ;; esac
      BUILDS=$((BUILDS + 1)); BUILD_AT="${index}"; BUILD_SHARD="$(shard_of "${cond}")" ;;
  esac
done <<<"${STEPS}"
if [ "${BUILDS}" -ne 1 ] || [ -z "${BUILD_SHARD}" ]; then
  fail "${WORKFLOW}'s shard job needs exactly one dedicated full App build step (run: swift build --arch arm64, no --target / --product) limited to one shard with matrix.shard == N (found ${BUILDS}, shard「${BUILD_SHARD}」)"
fi
for gui in scripts/check-playback-start.sh scripts/check-preview-perf.sh; do
  matches="$(awk -F '\037' -v path="${gui}" 'index($3, path) && $3 !~ /--self-test/ { print $1 "\037" $2 }' <<<"${STEPS}")"
  if [ "$({ grep -c . <<<"${matches}" || true; })" != "1" ]; then
    fail "${WORKFLOW}'s shard job must run ${gui} in exactly one step (found $({ grep -c . <<<"${matches}" || true; })): it runs before every merge and nowhere else"
    continue
  fi
  at="${matches%%"${US}"*}"
  cond="${matches#*"${US}"}"
  if [ -z "${BUILD_AT}" ] || [ "$(shard_of "${cond}")" != "${BUILD_SHARD}" ] || [ "${at}" -le "${BUILD_AT}" ]; then
    fail "${gui} (step ${at}) must run in the shard of the dedicated App build (shard ${BUILD_SHARD:-?}, step ${BUILD_AT:-?}) and after it: elsewhere it builds the App inside its own time limit (if: ${cond})"
  fi
done

# ---- 6. An upload never decides a result ----
# Every upload-artifact step of every job: job␟name␟continue-on-error.
UPLOADS="$(awk '
  /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ { flush(); job = $1; sub(/:$/, "", job); next }
  /^      - / { flush(); cur = 1; line = $0; sub(/^      - /, "        ", line); $0 = line }
  cur && /^        uses:/ { uses = $2 }
  cur && /^        name:/ { name = $0; sub(/^        name:[[:space:]]*/, "", name) }
  cur && /^        continue-on-error:/ { coe = $2 }
  END { flush() }
  function flush() {
    if (cur && uses ~ /^actions\/upload-artifact@/) print job "\037" name "\037" coe
    cur = 0; uses = ""; name = ""; coe = ""
  }
' "${WORKFLOW}")"
UPLOAD_COUNT=0
while IFS="${US}" read -r job name coe; do
  [ -n "${job}" ] || continue
  UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
  if [ "${coe}" != "true" ]; then
    fail "the upload「${name:-unnamed}」in job ${job} of ${WORKFLOW} needs continue-on-error: true: an upload is a diagnostic, and an artifact service timeout must not turn a run whose checks passed red"
  fi
done <<<"${UPLOADS}"
if [ "${UPLOAD_COUNT}" -eq 0 ]; then
  fail "no actions/upload-artifact step found in ${WORKFLOW}: if the layout changed, change this guard (an empty scan passes everything)"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
SHARD_COUNTS="$(tr ' ' '\n' <<<"${PER_SHARD}" | grep . | LC_ALL=C sort | uniq -c | awk '{ printf "%sshard %s: %s", sep, $2, $1; sep = ", " }')"
echo "✓ check-all-shards：checks/ 下 ${GUARDS} 条守卫都在 check-all 里; every command once; all ${SCRIPTS} scripts/check-*.sh run on CI or are listed as local-only; ${FULL_APP} full-App checks in shards ${APP_SHARDS} (${SHARD_COUNTS}); graphical steps once each, after the App build in shard ${BUILD_SHARD}; ${UPLOAD_COUNT} uploads can't fail a run"
