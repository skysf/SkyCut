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
#    - 取用 actions/cache/restore、存用 actions/cache/save，不用会自己存的 actions/cache；
#    - 两边的 key 一字不差，带工具链指纹、组号、这次的提交；restore-keys 正好是 key 去掉提交；
#    - 只在 main 上（github.event_name == 'push'）、整组绿了（success()）才存。
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
injob && cur {
  line = $0
  if (line ~ /^        id:/) { sub(/^        id:[[:space:]]*/, "", line); id = line }
  else if (line ~ /^        uses:/) { sub(/^        uses:[[:space:]]*/, "", line); uses = line }
  else if (line ~ /^        if:/) { sub(/^        if:[[:space:]]*/, "", line); cond = line }
  else if (line ~ /^        run:/) { sub(/^        run:[[:space:]]*/, "", line); run = line }
  else if (line ~ /^          path:/) { sub(/^          path:[[:space:]]*/, "", line); path = line }
  else if (line ~ /^          key:/) { sub(/^          key:[[:space:]]*/, "", line); key = line }
  else if (line ~ /^          restore-keys:/) { sub(/^          restore-keys:[[:space:]]*/, "", line); rkeys = line }
  else if (line ~ /^          echo "id=/) { toolchain_out = 1 }
}
END { if (injob) flush() }
function flush() {
  if (cur) print cur "\037" id "\037" uses "\037" cond "\037" run "\037" path "\037" key "\037" rkeys "\037" toolchain_out
  cur = 0; id = ""; uses = ""; cond = ""; run = ""; path = ""; key = ""; rkeys = ""; toolchain_out = 0
}
AWK
STEPS="$(awk "${STEP_PROG}" "${WORKFLOW}")"
if [ -z "${STEPS}" ]; then
  fail "${WORKFLOW} 里没读到分组 job（shard:）的步骤：写法变了就改这条守卫（扫空 = 假绿）"
fi

TOOLCHAIN_AT="" MTIMES_AT="" BUILD_AT="" RESTORE_AT="" RESTORE_KEY="" RESTORE_KEYS="" SAVE_AT="" SAVE_KEY="" SAVE_IF=""
while IFS="$(printf '\037')" read -r index id uses cond run path key rkeys toolchain_out; do
  [ -n "${index}" ] || continue
  if [ "${id}" = "toolchain" ] && [ "${toolchain_out}" = "1" ]; then TOOLCHAIN_AT="${index}"; fi
  if [ "${run}" = "python3 scripts/ci-stable-mtimes.py" ]; then MTIMES_AT="${index}"; fi
  if [ -z "${BUILD_AT}" ] && [ "${run}" != "${run#swift build}" ]; then BUILD_AT="${index}"; fi
  [ "${path}" = ".build" ] || continue
  case "${uses}" in
    actions/cache/restore@*) RESTORE_AT="${index}"; RESTORE_KEY="${key}"; RESTORE_KEYS="${rkeys}" ;;
    actions/cache/save@*) SAVE_AT="${index}"; SAVE_KEY="${key}"; SAVE_IF="${cond}" ;;
    *) fail "第 ${index} 步用 ${uses} 缓存 .build：要分成 actions/cache/restore 和 actions/cache/save（合在一起的那个在 PR 上也会存、命中了就不再存）" ;;
  esac
done <<<"${STEPS}"

SHA_SUFFIX='-${{ github.sha }}'
if [ -z "${RESTORE_AT}" ] || [ -z "${SAVE_AT}" ]; then
  fail "${WORKFLOW} 的分组 job 里要正好有取（actions/cache/restore）和存（actions/cache/save）.build 各一步（取：${RESTORE_AT:-没有}，存：${SAVE_AT:-没有}）"
else
  for part in '${{ github.workspace }}' '${{ steps.toolchain.outputs.id }}' '${{ matrix.shard }}'; do
    if [ "${RESTORE_KEY}" = "${RESTORE_KEY#*"${part}"}" ]; then
      fail ".build 缓存的 key 不带 ${part}：${RESTORE_KEY}"
    fi
  done
  if [ "${RESTORE_KEY}" = "${RESTORE_KEY%"${SHA_SUFFIX}"}" ]; then
    fail ".build 缓存的 key 要以 ${SHA_SUFFIX} 结尾（每次提交存一份新的，缓存存了就不能改）：${RESTORE_KEY}"
  fi
  if [ "${SAVE_KEY}" != "${RESTORE_KEY}" ]; then
    fail "存和取 .build 的 key 不一样：PR 永远找不到 main 存的那一份（取：${RESTORE_KEY}；存：${SAVE_KEY}）"
  fi
  if [ "${RESTORE_KEYS}" != "${RESTORE_KEY%"${SHA_SUFFIX}"}-" ]; then
    fail "restore-keys 应该正好是 key 去掉 \${{ github.sha }}（同一组、同一工具链最新的那份）：${RESTORE_KEYS}"
  fi
  for part in "github.event_name == 'push'" 'success()'; do
    if [ "${SAVE_IF}" = "${SAVE_IF#*"${part}"}" ]; then
      fail "存 .build 的那一步的 if 不带「${part}」：只在 main 上、整组绿了才存（${SAVE_IF}）"
    fi
  done
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
echo "✓ ci-build-cache-key：.build 缓存的 key 带检出目录、工具链、组号和提交，取和存同一个 key、只在 main 上绿了才存，修改时间按内容设在编译之前"
