#!/usr/bin/env bash
# 扫描守卫：CI 的「只改了文档」快速通道只在真的只改了文档时才走，走的时候照样有结论。
#
# 快速通道（.github/workflows/checks.yml + scripts/ci-docs-only.sh，docs/build/build-and-packaging.md「CI」一节）
# 省掉的是编 App 和全部自检，所以判错一次就是一次没测过的合并。这里钉三件事：
#   一、判断本身：白名单外的任何路径、空的改动、带引号的路径都是 false；把代码挪进 docs/ 也是 false（--no-renames）；
#       在一个临时 git 仓库里真提交一遍（合并提交、改名、根提交）。
#   二、workflow 的接线：判断那一步在最前；编 App、跑 check-all、性能 ratchet、缓存、上传每一步都带
#       `steps.changes.outputs.docs_only != 'true'`（判断出岔子 = 照常全跑）；快速通道那一步跑 scripts/check-guards.sh、
#       只在第 1 组；`on:` 里没有 paths / paths-ignore（整个 workflow 被跳过，必需的 check-all 就永远等不到结论）。
#   三、汇总 job check-all 照旧 needs 全部分组、带 !cancelled()。
#
# 用法：checks/ci-docs-only.sh [workflow 路径]   # 路径只给反向验证用，默认 .github/workflows/checks.yml
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CLASSIFIER="${ROOT}/scripts/ci-docs-only.sh"
WORKFLOW="${1:-.github/workflows/checks.yml}"
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}

# ---- 一、判断本身 ----
expect() {
  local want="$1" input="$2" got
  got="$(printf '%b' "${input}" | /bin/bash "${CLASSIFIER}" -)"
  if [ "${got}" != "${want}" ]; then
    fail "scripts/ci-docs-only.sh 对「${input}」说 ${got}，应该是 ${want}"
  fi
}
expect true 'docs/a.md\n'
expect true 'docs/a.md\nAGENTS.md\n'
expect true 'README.md\nSrtFlow-Requirements.md\n'
expect true 'docs/reports/2026-11-03-mcp-discovery-evidence.json\n'
expect false ''
expect false 'Sources/SrtFlow/VideoEditModels.swift\n'
expect false 'docs/a.md\nscripts/check-all.sh\n'
expect false '.github/workflows/checks.yml\n'
expect false 'checks/docs-index-drift.sh\n'
expect false 'Package.swift\n'
expect false 'AGENTS.md.orig\n'
expect false 'xdocs/a.md\n'
expect false 'docs\n'
expect false 'docs/\n'
expect false '"docs/\\344\\270\\255.md"\n'
expect false 'README.md\nSources/SrtFlow/Resources/en.lproj/Localizable.strings\n'

RENAMES="$({ grep -c -- '--no-renames' "${CLASSIFIER}" || true; })"
if [ "${RENAMES}" = "0" ]; then
  fail "scripts/ci-docs-only.sh 的 git diff 不带 --no-renames：把 Sources/ 下的文件挪进 docs/ 会被当成只改了文档"
fi

# 在临时仓库里真提交一遍，走不带参数的那条路（git diff HEAD^1 HEAD）。
REPO="$(mktemp -d)"
trap 'rm -rf "${REPO}"' EXIT
git_in() {
  git -C "${REPO}" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false "$@" >/dev/null
}
classify_repo() {
  (cd "${REPO}" && /bin/bash "${CLASSIFIER}")
}
git_in init -q -b main
mkdir -p "${REPO}/Sources" "${REPO}/docs"
echo 'let a = 1' >"${REPO}/Sources/a.swift"
git_in add -A
git_in commit -q -m root
if [ "$(classify_repo)" != "false" ]; then
  fail "根提交（没有 HEAD^1）应该判 false"
fi
echo '# 说明' >"${REPO}/docs/b.md"
git_in add -A
git_in commit -q -m docs
if [ "$(classify_repo)" != "true" ]; then
  fail "只加了 docs/b.md 的提交应该判 true"
fi
git_in mv Sources/a.swift docs/a.swift
git_in commit -q -m move
if [ "$(classify_repo)" != "false" ]; then
  fail "把 Sources/a.swift 挪进 docs/ 应该判 false（旧路径是代码）"
fi
git_in checkout -q -b topic
echo '更多' >>"${REPO}/docs/b.md"
git_in commit -q -am more-docs
git_in checkout -q main
echo 'let c = 3' >"${REPO}/Sources/c.swift"
git_in add -A
git_in commit -q -m code-on-main
git_in merge -q --no-ff -m merge-topic topic
if [ "$(classify_repo)" != "true" ]; then
  fail "合并提交带进来的只有文档（main 那边改的代码在第一个父提交里）应该判 true"
fi

# ---- 二、workflow 的接线 ----
if [ ! -f "${WORKFLOW}" ]; then
  echo "✗ 找不到 ${WORKFLOW}" >&2
  exit 1
fi
# 分组 job 的每一步一行：「序号␟id␟if␟run␟uses」，␟ 是 \037（单元分隔符）。不用 TAB：TAB 算 IFS 里的空白，
# 连着的两个会并成一个，没写 if 的那一步后面几栏就整体错位。
read -r -d '' STEP_PROG <<'AWK' || true
/^  shard:/ { injob = 1; next }
/^  [a-z-]+:/ { if (injob) { flush(); injob = 0 } }
injob && /^      - / { flush(); n++; cur = n; sub(/^      - /, "        ") }
injob && cur {
  line = $0
  if (line ~ /^        id:/) { sub(/^        id:[[:space:]]*/, "", line); id = line }
  else if (line ~ /^        if:/) { sub(/^        if:[[:space:]]*/, "", line); cond = line }
  else if (line ~ /^        run:/) { sub(/^        run:[[:space:]]*/, "", line); run = line }
  else if (line ~ /^        uses:/) { sub(/^        uses:[[:space:]]*/, "", line); uses = line }
}
END { if (injob) flush() }
function flush() {
  if (cur) print cur "\037" id "\037" cond "\037" run "\037" uses
  cur = 0; id = ""; cond = ""; run = ""; uses = ""
}
AWK
STEPS="$(awk "${STEP_PROG}" "${WORKFLOW}")"
if [ -z "${STEPS}" ]; then
  fail "${WORKFLOW} 里没读到分组 job（shard:）的步骤：写法变了就改这条守卫（扫空 = 假绿）"
fi

GATE="steps.changes.outputs.docs_only != 'true'"
CLASSIFY_AT=""
FAST_PATH=0
GATED=0
while IFS="$(printf '\037')" read -r index id cond run uses; do
  [ -n "${index}" ] || continue
  if [ "${id}" = "changes" ]; then
    CLASSIFY_AT="${index}"
    if [ "${run}" != 'echo "docs_only=$(scripts/ci-docs-only.sh)" >> "$GITHUB_OUTPUT"' ]; then
      fail "判断那一步（id: changes）应该是 echo \"docs_only=\$(scripts/ci-docs-only.sh)\" >> \"\$GITHUB_OUTPUT\"，现在是：${run}"
    fi
    continue
  fi
  heavy=0
  step="${run} ${uses}"
  for marker in 'scripts/check-all.sh' 'swift build' 'scripts/check-preview-perf.sh' 'scripts/vendor-ffmpeg.sh' \
    'actions/cache' 'actions/upload-artifact'; do
    if [ "${step}" != "${step#*"${marker}"}" ]; then heavy=1; fi
  done
  if [ "${run}" = "scripts/check-guards.sh" ]; then
    FAST_PATH=$((FAST_PATH + 1))
    if [ "${cond}" != "steps.changes.outputs.docs_only == 'true' && steps.verified.outputs.verified != 'true' && matrix.shard == 1" ]; then
      fail "快速通道那一步的 if 应该是「steps.changes.outputs.docs_only == 'true' && steps.verified.outputs.verified != 'true' && matrix.shard == 1」，现在是：${cond}"
    fi
  fi
  if [ "${heavy}" = "1" ]; then
    GATED=$((GATED + 1))
    if [ "${cond}" = "${cond#*"${GATE}"}" ]; then
      fail "第 ${index} 步（${run}${uses}）的 if 不带「${GATE}」：只改文档时它照跑，或者判断出岔子时它反而不跑"
    fi
    if [ -z "${CLASSIFY_AT}" ]; then
      fail "第 ${index} 步（${run}${uses}）排在判断那一步前面：它读不到 steps.changes 的结论"
    fi
  fi
done <<<"${STEPS}"
if [ -z "${CLASSIFY_AT}" ]; then
  fail "${WORKFLOW} 的分组 job 里没有 id: changes 那一步（scripts/ci-docs-only.sh）"
fi
if [ "${FAST_PATH}" -ne 1 ]; then
  fail "${WORKFLOW} 的分组 job 里应该正好有一步跑 scripts/check-guards.sh（快速通道），现在有 ${FAST_PATH} 步"
fi
if [ "${GATED}" -lt 6 ]; then
  fail "${WORKFLOW} 里只认出 ${GATED} 步重活（编 App、check-all、性能 ratchet、两个缓存、拉 ffmpeg、上传），少了就是这条守卫没跟上写法"
fi
PATH_FILTERS="$({ grep -cE '^[[:space:]]*(paths|paths-ignore):' "${WORKFLOW}" || true; })"
if [ "${PATH_FILTERS}" != "0" ]; then
  fail "${WORKFLOW} 的触发条件里有 paths / paths-ignore：整个 workflow 被跳过时，必需的 check-all 永远等不到结论"
fi

# ---- 三、汇总 job ----
SUMMARY="$(awk '/^  check-all:/ { inside = 1; next } /^  [a-z-]+:/ { inside = 0 } inside { print }' "${WORKFLOW}")"
if [ "$({ grep -cE '^[[:space:]]*needs:[[:space:]]*shard[[:space:]]*$' <<<"${SUMMARY}" || true; })" != "1" ]; then
  fail "${WORKFLOW} 的汇总 job check-all 不再 needs: shard"
fi
if [ "$({ grep -cF 'if: ${{ !cancelled() }}' <<<"${SUMMARY}" || true; })" != "1" ]; then
  fail "${WORKFLOW} 的汇总 job check-all 不带 if: \${{ !cancelled() }}：分组红了它会被跳过，被跳过的必需检查算通过"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ ci-docs-only：只有白名单里的文档才走快速通道（含改名、合并提交），重活都看判断的结论，汇总 job 照旧"
