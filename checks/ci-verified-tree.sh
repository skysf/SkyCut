#!/usr/bin/env bash
# 扫描守卫：合并之后 main 上那一轮「这棵树已经验过就不再跑检查」只在真的验过时才走。
#
# 走错一次 = main 上有一棵没人测过的树（scripts/ci-verified-tree.sh、.github/workflows/checks.yml，
# docs/build/build-and-packaging.md「CI」一节）。这里钉三件事：
#   一、判断本身：在临时仓库里造一个真的合并提交，PATH 上放一个假的 gh（两次接口调用都从写好的 JSON 里答，用系统的 jq），
#       每个用例只改一个事实：不是 push、不是合并提交、没有记号、记号过期、接口出错、别的头提交、fork、别的 workflow、
#       不是 pull_request、没跑完、红了、取消了、别的仓库、太旧、开关关了 —— 全部 false；只有全对上才 true。
#   二、workflow 的接线：判断那一步紧跟在「只改了文档」那一步后面、写法一字不差；跑检查的每一步都带
#       `steps.verified.outputs.verified != 'true'`（判断出岔子 = 照常全跑），没有一步写成 `== 'true'`；
#       缓存那几步是「没验过，或者第 1 组」；编 App 那一步不看它（验过的轮里第 1 组照样编、照样存缓存）。
#   三、记号只在 PR 的那一轮、汇总 job 的最后（全部分组和官网检查都过了之后）才留，名字带着这一轮检出的树，
#       留不下不许让 check-all 变红；token 有 actions: read。
#
# 用法：checks/ci-verified-tree.sh [workflow 路径 [判断脚本路径]]   # 两个路径只给反向验证用
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORKFLOW="${1:-.github/workflows/checks.yml}"
SCRIPT="${2:-${ROOT}/scripts/ci-verified-tree.sh}"
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}
for need in "${WORKFLOW}" "${SCRIPT}"; do
  if [ ! -f "${need}" ]; then
    echo "✗ 找不到 ${need}" >&2
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "✗ ci-verified-tree：这条守卫要用 jq 扮 gh 的 --jq，PATH 上没有（macOS 15 起系统自带 /usr/bin/jq）" >&2
  exit 1
fi

# ---- 一、判断本身 ----
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
REPO="${WORK}/repo"
BIN="${WORK}/bin"
mkdir -p "${REPO}" "${BIN}"
git_in() {
  git -C "${REPO}" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false "$@" >/dev/null
}
git_in init -q -b main
echo base >"${REPO}/a.txt"
git_in add -A
git_in commit -q -m base
git_in checkout -q -b topic
echo change >"${REPO}/b.txt"
git_in add -A
git_in commit -q -m topic
git_in checkout -q main
git_in merge -q --no-ff -m merge-topic topic
TREE="$(git -C "${REPO}" rev-parse 'HEAD^{tree}')"
PR_HEAD="$(git -C "${REPO}" rev-parse 'HEAD^2')"

# 假的 gh：`gh api <地址> --jq <表达式>`。artifact 列表读 $FAKE_DIR/artifacts.json；某一轮的记录读
# $FAKE_DIR/run-<id>.<第几次问>.json，没有就读 run-<id>.json（用来演「第二次问才 completed」）。
cat >"${BIN}/gh" <<'FAKE'
#!/bin/bash
[ "$1" = "api" ] || exit 2
endpoint="$2"
expr=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--jq" ]; then expr="$2"; fi
  shift
done
[ -z "${FAKE_FAIL:-}" ] || exit 1
case "${endpoint}" in
  */actions/artifacts\?name=verified-tree-*)
    asked="${endpoint#*name=}"
    echo "${asked%%&*}" >>"${FAKE_DIR}/asked-names"
    file="${FAKE_DIR}/artifacts.json"
    ;;
  */actions/runs/*)
    id="${endpoint##*/}"
    n="$(cat "${FAKE_DIR}/calls-${id}" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "${n}" >"${FAKE_DIR}/calls-${id}"
    file="${FAKE_DIR}/run-${id}.${n}.json"
    [ -f "${file}" ] || file="${FAKE_DIR}/run-${id}.json"
    ;;
  *) exit 2 ;;
esac
[ -f "${file}" ] || exit 1
jq -r "${expr}" "${file}"
FAKE
chmod +x "${BIN}/gh"
ln -s "$(command -v jq)" "${BIN}/jq"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(date -u -v-30H +%Y-%m-%dT%H:%M:%SZ)"
artifacts() { # 头提交 仓库 id 头仓库 id 过期没有
  printf '{"artifacts":[{"name":"verified-tree-%s","expired":%s,"workflow_run":{"id":77,"head_sha":"%s","repository_id":%s,"head_repository_id":%s}}]}\n' \
    "${TREE}" "$4" "$1" "$2" "$3" >"${FAKE_DIR}/artifacts.json"
}
run_record() { # 文件名 workflow 事件 状态 结论 头提交 仓库 头仓库 建出来的时间
  printf '{"path":"%s","event":"%s","status":"%s","conclusion":%s,"head_sha":"%s","repository":{"full_name":"%s"},"head_repository":{"full_name":"%s"},"created_at":"%s"}\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >"${FAKE_DIR}/$1"
}
GOOD_PATH=".github/workflows/checks.yml"
fresh() { # 全部对得上的一套
  FAKE_DIR="$(mktemp -d "${WORK}/fake.XXXXXX")"
  artifacts "${PR_HEAD}" 1 1 false
  run_record run-77.json "${GOOD_PATH}" pull_request completed '"success"' "${PR_HEAD}" o/r o/r "${NOW}"
}
CASES=0
expect() { # 用例名 应该打印什么 [环境变量…]
  local name="$1" want="$2" got
  shift 2
  CASES=$((CASES + 1))
  got="$(cd "${REPO}" && env PATH="${BIN}:/usr/bin:/bin" FAKE_DIR="${FAKE_DIR}" GITHUB_EVENT_NAME=push \
    GITHUB_REPOSITORY=o/r GITHUB_STEP_SUMMARY= VERIFIED_TREE_WAIT_SECONDS=2 VERIFIED_TREE_POLL_SECONDS=1 "$@" /bin/bash "${SCRIPT}" 2>"${FAKE_DIR}/stderr")"
  if [ "${got}" != "${want}" ]; then
    fail "scripts/ci-verified-tree.sh：「${name}」打印了 ${got}，应该是 ${want}（$(tr '\n' ' ' <"${FAKE_DIR}/stderr")）"
  fi
}

fresh; expect "全部对得上" true
if [ "$(cat "${FAKE_DIR}/asked-names")" != "verified-tree-${TREE}" ]; then
  fail "scripts/ci-verified-tree.sh 找的不是 HEAD 这棵树的记号（verified-tree-${TREE}），问的是：$(tr '\n' ' ' <"${FAKE_DIR}/asked-names")"
fi
fresh; expect "PR 上的那一轮" false GITHUB_EVENT_NAME=pull_request
fresh; expect "开关关了" false VERIFIED_TREE_SWITCH=off
fresh; expect "GITHUB_REPOSITORY 没设" false GITHUB_REPOSITORY=
fresh; echo '{"artifacts":[]}' >"${FAKE_DIR}/artifacts.json"; expect "没有记号" false
fresh; artifacts "${PR_HEAD}" 1 1 true; expect "记号过期了" false
fresh; expect "列 artifact 的接口出错" false FAKE_FAIL=1
fresh; rm "${FAKE_DIR}/run-77.json"; expect "读那一轮的接口出错" false
fresh; artifacts 0000000000000000000000000000000000000000 1 1 false; expect "记号是别的头提交留的" false
fresh; artifacts "${PR_HEAD}" 1 2 false; expect "记号是 fork 来的" false
fresh; run_record run-77.json .github/workflows/other.yml pull_request completed '"success"' "${PR_HEAD}" o/r o/r "${NOW}"; expect "别的 workflow 留的同名记号" false
fresh; run_record run-77.json "${GOOD_PATH}" push completed '"success"' "${PR_HEAD}" o/r o/r "${NOW}"; expect "那一轮不是 pull_request" false
fresh; run_record run-77.json "${GOOD_PATH}" pull_request completed '"failure"' "${PR_HEAD}" o/r o/r "${NOW}"; expect "那一轮红了" false
fresh; run_record run-77.json "${GOOD_PATH}" pull_request completed '"cancelled"' "${PR_HEAD}" o/r o/r "${NOW}"; expect "那一轮被取消了" false
fresh; run_record run-77.json "${GOOD_PATH}" pull_request in_progress null "${PR_HEAD}" o/r o/r "${NOW}"; expect "那一轮一直没跑完" false
fresh; run_record run-77.json "${GOOD_PATH}" pull_request in_progress '"success"' "${PR_HEAD}" o/r o/r "${NOW}"; expect "结论是 success 但状态不是 completed" false
fresh; run_record run-77.1.json "${GOOD_PATH}" pull_request in_progress null "${PR_HEAD}" o/r o/r "${NOW}"; expect "第二次问才 completed" true
fresh; run_record run-77.json "${GOOD_PATH}" pull_request completed '"success"' 1111111111111111111111111111111111111111 o/r o/r "${NOW}"; expect "那一轮的记录是别的头提交" false
fresh; run_record run-77.json "${GOOD_PATH}" pull_request completed '"success"' "${PR_HEAD}" x/y o/r "${NOW}"; expect "那一轮是别的仓库的" false
fresh; run_record run-77.json "${GOOD_PATH}" pull_request completed '"success"' "${PR_HEAD}" o/r x/y "${NOW}"; expect "那一轮的头在别的仓库" false
fresh; run_record run-77.json "${GOOD_PATH}" pull_request completed '"success"' "${PR_HEAD}" o/r o/r "${OLD}"; expect "那一轮是 30 小时前的" false
fresh; git_in checkout -q topic; expect "HEAD 不是合并提交" false; git_in checkout -q main
if [ "${CASES}" -lt 22 ]; then
  fail "判断的用例只跑了 ${CASES} 个（应该 22 个以上）：少了就是这条守卫自己没跑全"
fi

# ---- 二、workflow 的接线 ----
# 分组 job 的每一步一行：「序号␟id␟if␟run␟uses」（␟ 是 \037；不用 TAB，空栏会被并掉）。
read -r -d '' STEP_PROG <<'AWK' || true
$0 ~ "^  " job ":" { injob = 1; next }
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
STEPS="$(awk -v job=shard "${STEP_PROG}" "${WORKFLOW}")"
if [ -z "${STEPS}" ]; then
  fail "${WORKFLOW} 里没读到分组 job（shard:）的步骤：写法变了就改这条守卫（扫空 = 假绿）"
fi

NOT_VERIFIED="steps.verified.outputs.verified != 'true'"
OR_SHARD_ONE="(steps.verified.outputs.verified != 'true' || matrix.shard == 1)"
CHANGES_AT="" VERIFIED_AT="" CHECK_STEPS=0 CACHE_STEPS=0 BUILD_STEPS=0
while IFS="$(printf '\037')" read -r index id cond run uses; do
  [ -n "${index}" ] || continue
  step="${run} ${uses}"
  if [ "${id}" = "changes" ]; then CHANGES_AT="${index}"; continue; fi
  if [ "${id}" = "verified" ]; then
    VERIFIED_AT="${index}"
    if [ "${run}" != 'echo "verified=$(scripts/ci-verified-tree.sh)" >> "$GITHUB_OUTPUT"' ]; then
      fail "判断那一步（id: verified）应该是 echo \"verified=\$(scripts/ci-verified-tree.sh)\" >> \"\$GITHUB_OUTPUT\"，现在是：${run}"
    fi
    if [ -n "${cond}" ]; then
      fail "判断那一步（id: verified）不许带 if：它被跳过时输出是空的，下面照常全跑没错，可验过的那种轮就永远走不到了（${cond}）"
    fi
    continue
  fi
  if [ "${cond}" != "${cond#*"verified == 'true'"}" ]; then
    fail "第 ${index} 步的 if 写成了 verified == 'true'：一律写成「${NOT_VERIFIED}」，判断出岔子才会照常全跑（${cond}）"
  fi
  kind=""
  for marker in 'scripts/check-all.sh' 'scripts/check-preview-perf.sh' 'scripts/check-guards.sh' 'actions/upload-artifact'; do
    if [ "${step}" != "${step#*"${marker}"}" ]; then kind="check"; fi
  done
  for marker in 'scripts/ci-stable-mtimes.py' 'actions/cache' 'scripts/vendor-ffmpeg.sh'; do
    if [ "${step}" != "${step#*"${marker}"}" ]; then kind="cache"; fi
  done
  if [ "${run}" != "${run#swift build}" ]; then kind="build"; fi
  [ -n "${kind}" ] || continue
  if [ -z "${VERIFIED_AT}" ]; then
    fail "第 ${index} 步（${step}）排在判断那一步（id: verified）前面：它读不到结论"
  fi
  case "${kind}" in
    check)
      CHECK_STEPS=$((CHECK_STEPS + 1))
      if [ "${cond}" = "${cond#*"${NOT_VERIFIED}"}" ] || [ "${cond}" != "${cond#*"|| matrix.shard == 1"}" ]; then
        fail "第 ${index} 步（${step}）是跑检查的：if 要带「${NOT_VERIFIED}」、不带「|| matrix.shard == 1」（${cond}）"
      fi
      ;;
    cache)
      CACHE_STEPS=$((CACHE_STEPS + 1))
      if [ "${cond}" = "${cond#*"${OR_SHARD_ONE}"}" ]; then
        fail "第 ${index} 步（${step}）是备缓存的：if 要带「${OR_SHARD_ONE}」，验过的轮里只有第 1 组做（${cond}）"
      fi
      ;;
    build)
      BUILD_STEPS=$((BUILD_STEPS + 1))
      if [ "${cond}" != "${cond#*verified}" ]; then
        fail "第 ${index} 步（编 App）的 if 不许看 verified：验过的轮里第 1 组照样要编，不然存下来的缓存是上一个提交的（${cond}）"
      fi
      ;;
  esac
done <<<"${STEPS}"
if [ -z "${VERIFIED_AT}" ]; then
  fail "${WORKFLOW} 的分组 job 里没有 id: verified 那一步（scripts/ci-verified-tree.sh）"
elif [ -z "${CHANGES_AT}" ] || [ "${VERIFIED_AT}" -ne $((CHANGES_AT + 1)) ]; then
  fail "id: verified 那一步要紧跟在 id: changes 后面（现在：changes 第 ${CHANGES_AT:-?} 步，verified 第 ${VERIFIED_AT} 步）"
fi
if [ "${CHECK_STEPS}" -lt 4 ] || [ "${CACHE_STEPS}" -lt 5 ] || [ "${BUILD_STEPS}" -ne 1 ]; then
  fail "${WORKFLOW} 里认出跑检查的 ${CHECK_STEPS} 步（应该 ≥ 4：快速通道、check-all、性能 ratchet、上传）、备缓存的 ${CACHE_STEPS} 步（应该 ≥ 5：修改时间、取、存、ffmpeg 两步）、编 App ${BUILD_STEPS} 步（应该 1）：少了就是这条守卫没跟上写法"
fi
TOKEN_ENV="$({ grep -cF 'GH_TOKEN: ${{ github.token }}' "${WORKFLOW}" || true; })"
if [ "${TOKEN_ENV}" != "1" ]; then
  fail "${WORKFLOW} 里判断那一步没有 GH_TOKEN: \${{ github.token }}（应该正好一处，现在 ${TOKEN_ENV} 处）：gh 没有 token，永远查不到"
fi
ACTIONS_READ="$(awk '/^permissions:/ { inside = 1; next } /^[a-z]/ { inside = 0 } inside && /^  actions: read[[:space:]]*$/ { print "yes" }' "${WORKFLOW}")"
if [ "${ACTIONS_READ}" != "yes" ]; then
  fail "${WORKFLOW} 顶层的 permissions 里没有 actions: read：读不到 artifact 和运行记录，永远查不到"
fi

# ---- 三、记号 ----
SUMMARY="$(awk '/^  check-all:/ { inside = 1; next } /^  [a-z-]+:/ { inside = 0 } inside { print }' "${WORKFLOW}")"
GATE_LINE="$({ grep -nF 'test "${{ needs.shard.result }}" = "success"' <<<"${SUMMARY}" || true; } | head -1 | cut -d: -f1)"
NAME_LINE="$({ grep -nF 'name: verified-tree-${{ steps.tree.outputs.tree }}' <<<"${SUMMARY}" || true; } | head -1 | cut -d: -f1)"
TREE_LINE="$({ grep -nF "tree=\"\$(git rev-parse 'HEAD^{tree}')\"" <<<"${SUMMARY}" || true; } | head -1 | cut -d: -f1)"
if [ -z "${GATE_LINE}" ] || [ -z "${NAME_LINE}" ] || [ -z "${TREE_LINE}" ]; then
  fail "${WORKFLOW} 的汇总 job check-all 里要有：分组全过的那一行、算树的那一行（git rev-parse 'HEAD^{tree}'）、名字是 verified-tree-\${{ steps.tree.outputs.tree }} 的上传"
elif [ "${TREE_LINE}" -lt "${GATE_LINE}" ] || [ "${NAME_LINE}" -lt "${TREE_LINE}" ]; then
  fail "记号要留在汇总 job 的最后：先是分组全过那一行（第 ${GATE_LINE} 行），再算树（第 ${TREE_LINE} 行），再上传（第 ${NAME_LINE} 行）。排在前面 = 红的那一轮也留记号"
fi
MARKER_STEPS="$(awk -v job=check-all "${STEP_PROG}" "${WORKFLOW}" | awk -F '\037' '$2 == "tree" || $5 ~ /actions\/upload-artifact/ { print $3 }')"
MARKER_COUNT="$({ grep -c . <<<"${MARKER_STEPS}" || true; })"
MARKER_PR_ONLY="$({ grep -cxF "github.event_name == 'pull_request'" <<<"${MARKER_STEPS}" || true; })"
if [ "${MARKER_COUNT}" != "2" ] || [ "${MARKER_PR_ONLY}" != "2" ]; then
  fail "留记号的两步（id: tree 和上传）的 if 都应该正好是 github.event_name == 'pull_request'（main 上那一轮不留：它自己可能就是没跑检查的那种）"
fi
for want in 'retention-days: 1' 'overwrite: true'; do
  if [ "$({ grep -cF "${want}" <<<"${SUMMARY}" || true; })" != "1" ]; then
    fail "${WORKFLOW} 的汇总 job 里上传记号那一步要有「${want}」（只留一天；重跑时同名的要能盖掉）"
  fi
done
if [ "$({ grep -cF 'continue-on-error: true' <<<"${SUMMARY}" || true; })" != "2" ]; then
  fail "留记号的两步都要 continue-on-error: true：留不下记号只是 main 上多跑一轮，不许让必需的 check-all 变红"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ ci-verified-tree：main 上只有树和 PR 那轮绿的 CI 测的一模一样才不跑检查（${CASES} 个用例），跑检查的步骤都看判断的结论，记号只在 PR 全绿之后留"
