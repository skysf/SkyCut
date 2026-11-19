#!/usr/bin/env bash
# 扫描守卫：CI 的 .build 缓存怎么存、怎么取。
#
# 一、key 和 restore-keys 都带检出目录（github.workspace）。.build 里的模块缓存（ModuleCache 下的 .pcm）记着编它时检出目录的
#    绝对路径；2026-10-18 仓库从 SrtFlow 改名 SkyCut 之后，key 只看 Package.swift，旧目录编的缓存照样恢复回来，五组全部编不过
#    （docs/bugfixes/2026-10-18-ci-build-cache-breaks-after-repo-rename.md）。
# 二、缓存真能省下编译（docs/bugfixes/2026-11-04-ci-build-cache-never-saved-a-compile.md）。以前五组共用一个只看 Package.swift
#    的 key：谁先跑完谁存（存下的是只编了核心库的那一组），命中之后再也不存，checkout 出来的修改时间又每次都是新的，SwiftPM
#    把恢复回来的 .build 全当过期 —— 整个 App 每次冷编。现在钉着：
#    - 编译和恢复之前先跑 scripts/ci-stable-mtimes.py（修改时间按内容设），工具链那一步给出指纹（id: toolchain）；
#    - 取用 actions/cache/restore、存用 actions/cache/save，不用会自己存的 actions/cache (exactly one step each);
#    - saved on main only (github.event_name == 'push') and only after a successful build (success()).
# 3. One cache for every shard (since 2026-11-20, docs/build/build-and-packaging.md "CI"): the complete App build, so a
#    check that links the full App can run in any shard after an incremental build.
#    - The key carries the checkout, the toolchain fingerprint, `-app-` and this commit, never matrix.shard; the save
#      step uses the same key. The first restore key is the key without the commit (the newest App build); any further
#      one is a fallback prefix for the same checkout and toolchain (the old -shard1- cache, for the switch).
#    - Only the shard with the dedicated full App build step (plain `swift build`, no --target / --product) saves, in the
#      step right after it, limited to that shard: a shard that built only the core library must never win the key
#      (the 2026-11-04 bug), and saving early survives a newer merge cancelling the rest of the run.
#
# 用法：checks/ci-build-cache-key.sh [workflow 路径]   # 路径只给反向验证用，默认 .github/workflows/checks.yml
set -euo pipefail
cd "$(dirname "$0")/.."

WORKFLOW="${1:-.github/workflows/checks.yml}"
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}
if [ ! -f "${WORKFLOW}" ]; then
  echo "✗ 找不到 ${WORKFLOW}" >&2
  exit 1
fi

# 分组 job 的每一步一行，各栏用 \037 隔开（TAB 算 IFS 里的空白，空栏会被并掉）：
# 序号 id uses if run path key restore-keys
read -r -d '' STEP_PROG <<'AWK' || true
/^  shard:/ { injob = 1; next }
/^  [a-z-]+:/ { if (injob) { flush(); injob = 0 } }
injob && /^      - / { flush(); n++; cur = n; sub(/^      - /, "        ") }
injob && cur && rblock {
  # A block scalar (restore-keys: |): one key per more-indented line, joined with \036.
  if ($0 ~ /^            [^ ]/) { k = $0; sub(/^[[:space:]]+/, "", k); rkeys = (rkeys == "" ? k : rkeys "\036" k); next }
  rblock = 0
}
injob && cur {
  line = $0
  if (line ~ /^        id:/) { sub(/^        id:[[:space:]]*/, "", line); id = line }
  else if (line ~ /^        uses:/) { sub(/^        uses:[[:space:]]*/, "", line); uses = line }
  else if (line ~ /^        if:/) { sub(/^        if:[[:space:]]*/, "", line); cond = line }
  else if (line ~ /^        run:/) { sub(/^        run:[[:space:]]*/, "", line); run = line }
  else if (line ~ /^          path:/) { sub(/^          path:[[:space:]]*/, "", line); path = line }
  else if (line ~ /^          key:/) { sub(/^          key:[[:space:]]*/, "", line); key = line }
  else if (line ~ /^          restore-keys:/) { sub(/^          restore-keys:[[:space:]]*/, "", line); if (line == "|" || line == "|-") { rblock = 1; rkeys = "" } else rkeys = line }
  else if (line ~ /^          echo "id=/) { toolchain_out = 1 }
}
END { if (injob) flush() }
function flush() {
  if (cur) print cur "\037" id "\037" uses "\037" cond "\037" run "\037" path "\037" key "\037" rkeys "\037" toolchain_out
  cur = 0; id = ""; uses = ""; cond = ""; run = ""; path = ""; key = ""; rkeys = ""; rblock = 0; toolchain_out = 0
}
AWK
STEPS="$(awk "${STEP_PROG}" "${WORKFLOW}")"
if [ -z "${STEPS}" ]; then
  fail "${WORKFLOW} 里没读到分组 job（shard:）的步骤：写法变了就改这条守卫（扫空 = 假绿）"
fi

TOOLCHAIN_AT="" MTIMES_AT="" BUILD_AT="" APP_BUILD_AT="" APP_BUILD_IF="" APP_BUILDS=0
RESTORE_AT="" RESTORE_KEY="" RESTORE_KEYS="" SAVE_AT="" SAVE_KEY="" SAVE_IF="" RESTORES=0 SAVES=0
while IFS="$(printf '\037')" read -r index id uses cond run path key rkeys toolchain_out; do
  [ -n "${index}" ] || continue
  if [ "${id}" = "toolchain" ] && [ "${toolchain_out}" = "1" ]; then TOOLCHAIN_AT="${index}"; fi
  if [ "${run}" = "python3 scripts/ci-stable-mtimes.py" ]; then MTIMES_AT="${index}"; fi
  if [ -z "${BUILD_AT}" ] && [ "${run}" != "${run#swift build}" ]; then BUILD_AT="${index}"; fi
  if [ "${run}" != "${run#swift build}" ]; then
    case " ${run} " in
      *" --target "* | *" --product "*) ;;
      *) APP_BUILDS=$((APP_BUILDS + 1)); APP_BUILD_AT="${index}"; APP_BUILD_IF="${cond}" ;;
    esac
  fi
  [ "${path}" = ".build" ] || continue
  case "${uses}" in
    actions/cache/restore@*) RESTORES=$((RESTORES + 1)); RESTORE_AT="${index}"; RESTORE_KEY="${key}"; RESTORE_KEYS="${rkeys}" ;;
    actions/cache/save@*) SAVES=$((SAVES + 1)); SAVE_AT="${index}"; SAVE_KEY="${key}"; SAVE_IF="${cond}" ;;
    *) fail "第 ${index} 步用 ${uses} 缓存 .build：要分成 actions/cache/restore 和 actions/cache/save（合在一起的那个在 PR 上也会存、命中了就不再存）" ;;
  esac
done <<<"${STEPS}"

SHA_SUFFIX='-${{ github.sha }}'
WORKSPACE_PART='${{ github.workspace }}'
TOOLCHAIN_PART='${{ steps.toolchain.outputs.id }}'
if [ "${RESTORES}" -ne 1 ] || [ "${SAVES}" -ne 1 ]; then
  fail "${WORKFLOW} 的分组 job 里要正好有取（actions/cache/restore）和存（actions/cache/save）.build 各一步（取：${RESTORES} 步，存：${SAVES} 步）"
else
  for part in "${WORKSPACE_PART}" "${TOOLCHAIN_PART}" '-app-'; do
    if [ "${RESTORE_KEY}" = "${RESTORE_KEY#*"${part}"}" ]; then
      fail ".build 缓存的 key 不带 ${part}：${RESTORE_KEY}"
    fi
  done
  if [ "${RESTORE_KEY}" != "${RESTORE_KEY#*matrix.shard}" ]; then
    fail "the .build cache key must not depend on matrix.shard: every shard restores the one full-App cache (${RESTORE_KEY})"
  fi
  if [ "${RESTORE_KEY}" = "${RESTORE_KEY%"${SHA_SUFFIX}"}" ]; then
    fail ".build 缓存的 key 要以 ${SHA_SUFFIX} 结尾（每次提交存一份新的，缓存存了就不能改）：${RESTORE_KEY}"
  fi
  if [ "${SAVE_KEY}" != "${RESTORE_KEY}" ]; then
    fail "存和取 .build 的 key 不一样：PR 永远找不到 main 存的那一份（取：${RESTORE_KEY}；存：${SAVE_KEY}）"
  fi
  FIRST_KEY="${RESTORE_KEYS%%$(printf '\036')*}"
  if [ "${FIRST_KEY}" != "${RESTORE_KEY%"${SHA_SUFFIX}"}-" ]; then
    fail "the first restore key must be the key without \${{ github.sha }} (the newest full-App cache of this checkout and toolchain): ${FIRST_KEY}"
  fi
  while IFS= read -r fallback; do
    [ -n "${fallback}" ] || continue
    if [ "${fallback}" = "${fallback#*"${WORKSPACE_PART}"}" ] || [ "${fallback}" = "${fallback#*"${TOOLCHAIN_PART}"}" ] \
      || [ "${fallback}" = "${fallback%-}" ]; then
      fail "every restore key must be a prefix ending in - that carries the checkout and the toolchain fingerprint: ${fallback}"
    fi
  done <<<"$(tr '\036' '\n' <<<"${RESTORE_KEYS}")"
  for part in "github.event_name == 'push'" 'success()' 'matrix.shard == '; do
    if [ "${SAVE_IF}" = "${SAVE_IF#*"${part}"}" ]; then
      fail "存 .build 的那一步的 if 不带「${part}」：只在 main 上、编译成功之后、在编完整 App 的那一组存（${SAVE_IF}）"
    fi
  done
  if [ "${SAVE_IF}" != "${SAVE_IF#*||}" ]; then
    fail "the save step's if must not contain ||: it is limited to main, success and one shard (${SAVE_IF})"
  fi
fi
APP_SHARD="$(sed -nE 's/.*matrix\.shard == ([0-9]+).*/\1/p' <<<"${APP_BUILD_IF}" | head -1)"
SAVE_SHARD="$(sed -nE 's/.*matrix\.shard == ([0-9]+).*/\1/p' <<<"${SAVE_IF}" | head -1)"
if [ "${APP_BUILDS}" -ne 1 ] || [ -z "${APP_SHARD}" ]; then
  fail "the shard job needs exactly one dedicated full App build step (swift build, no --target / --product) limited to one shard (found ${APP_BUILDS})"
elif [ -n "${SAVE_AT}" ] && { [ "${SAVE_AT}" -ne $((APP_BUILD_AT + 1)) ] || [ "${SAVE_SHARD}" != "${APP_SHARD}" ]; }; then
  fail "save the .build cache in the step right after the full App build (step ${APP_BUILD_AT}, shard ${APP_SHARD}); it is step ${SAVE_AT} in shard ${SAVE_SHARD:-every}: only a complete App build may be saved, and before a later merge can cancel the run"
fi
if [ -z "${TOOLCHAIN_AT}" ] || { [ -n "${RESTORE_AT}" ] && [ "${TOOLCHAIN_AT}" -gt "${RESTORE_AT}" ]; }; then
  fail "取 .build 之前要有 id: toolchain 那一步把工具链指纹写进 GITHUB_OUTPUT —— key 里的 steps.toolchain.outputs.id 就是它"
fi
if [ -z "${MTIMES_AT}" ]; then
  fail "${WORKFLOW} 里没有 python3 scripts/ci-stable-mtimes.py 那一步：checkout 出来的修改时间每次都是新的，恢复回来的 .build 全部作废"
else
  for later in "${RESTORE_AT}" "${BUILD_AT}"; do
    if [ -n "${later}" ] && [ "${MTIMES_AT}" -gt "${later}" ]; then
      fail "python3 scripts/ci-stable-mtimes.py（第 ${MTIMES_AT} 步）要排在恢复 .build 和第一次 swift build（第 ${later} 步）之前"
    fi
  done
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ ci-build-cache-key: one full-App .build cache for every shard (key: checkout, toolchain, app, commit), saved on main by shard ${APP_SHARD} right after its App build, file times set from content before compiling"
