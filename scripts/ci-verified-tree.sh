#!/usr/bin/env bash
# CI 用（合并之后 main 上那一轮）：这次检出的这棵树，是不是已经被这个 PR 最后那轮绿的 CI 原样验过。
# 是就打印 true；别的情况一律打印 false（照常全跑），原因写到 stderr 和这一轮的摘要里。
#
# 为什么：每合一个改代码的 PR，main 上要再跑一轮完整的，占满 5 台 macOS runner 约 7.5 分钟。合出来的树和 PR 最后一次
# 绿的那一轮测的树一模一样时（2026-08 到 11 月 358 次合并里 308 次），这一轮没有新东西可验。树不一样（PR 没跟上最新的
# main 就合了）照旧完整跑。docs/build/build-and-packaging.md「CI」一节。
#
# 记号：PR 那一轮全绿之后，汇总 job check-all 留一个叫 verified-tree-<树的 sha> 的 artifact（树 = 那一轮检出的
# GitHub 替它合的那个提交的树）。这里拿 HEAD 的树去找同名的 artifact，但**认的不是 artifact，是 GitHub 对上传它的
# 那一轮的记录**，下面每一条都要对上，对不上一条就是 false：
#   - HEAD 是两个父提交的合并提交（`gh pr merge --merge` 合出来的；squash / rebase 合的不认）；
#   - artifact 没过期，上传它的那一轮的头提交 = HEAD 的第二个父提交（这个 PR 的头），不是 fork 来的；
#   - 那一轮的 workflow 文件是 .github/workflows/checks.yml、事件是 pull_request、状态 completed、结论 success
#     （重跑过的看最后一次）、仓库是本仓库、建出来不到 24 小时。
# 查不到、接口出错、gh 不在、不是 push、仓库变量 CI_VERIFIED_TREE 设成了 off：一律 false。宁可多跑一轮，不许漏跑。
# 别的 workflow、红了的那一轮、别的 PR 留下的同名 artifact 都过不了上面的核对（checks/ci-verified-tree.sh 逐条钉着）。
#
# 用法（在仓库根目录跑，PATH 上有 gh，环境里有 GH_TOKEN）：
#   scripts/ci-verified-tree.sh
# 只给自检用的环境变量：VERIFIED_TREE_WORKFLOW（默认 .github/workflows/checks.yml）、
#   VERIFIED_TREE_MAX_AGE_HOURS（默认 24）、VERIFIED_TREE_WAIT_SECONDS（默认 30）、VERIFIED_TREE_POLL_SECONDS（默认 5）。
set -uo pipefail

WORKFLOW="${VERIFIED_TREE_WORKFLOW:-.github/workflows/checks.yml}"
MAX_AGE_HOURS="${VERIFIED_TREE_MAX_AGE_HOURS:-24}"
WAIT_SECONDS="${VERIFIED_TREE_WAIT_SECONDS:-30}"
POLL_SECONDS="${VERIFIED_TREE_POLL_SECONDS:-5}"

note() {
  echo "ci-verified-tree: $*" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
    echo "ci-verified-tree: $*" >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
  fi
}
no() {
  note "$* -> run everything"
  echo false
  exit 0
}

[ "${GITHUB_EVENT_NAME:-}" = "push" ] || no "event is ${GITHUB_EVENT_NAME:-unset}, not push"
[ "${VERIFIED_TREE_SWITCH:-}" != "off" ] || no "switched off (repository variable CI_VERIFIED_TREE)"
REPO="${GITHUB_REPOSITORY:-}"
[ -n "${REPO}" ] || no "GITHUB_REPOSITORY is not set"
command -v gh >/dev/null 2>&1 || no "gh is not on PATH"
TREE="$(git rev-parse --verify -q 'HEAD^{tree}')" || no "cannot read the tree of HEAD"
PR_HEAD="$(git rev-parse --verify -q 'HEAD^2')" || no "HEAD is not a merge commit (no second parent)"
if git rev-parse --verify -q 'HEAD^3' >/dev/null; then no "HEAD has more than two parents"; fi

# 同名的 artifact，一行一个：上传它的那一轮的 id、头提交、仓库 id、头仓库 id。
ARTIFACTS="$(gh api "repos/${REPO}/actions/artifacts?name=verified-tree-${TREE}&per_page=100" \
  --jq '.artifacts[] | select(.expired == false and .workflow_run != null) | [.workflow_run.id, .workflow_run.head_sha, .workflow_run.repository_id, .workflow_run.head_repository_id] | @tsv' 2>/dev/null)" \
  || no "listing artifacts failed"
[ -n "${ARTIFACTS}" ] || no "no marker for tree ${TREE}"

run_facts() {
  # workflow 文件、事件、状态、结论、头提交、仓库、头仓库、建出来多少个整小时
  gh api "repos/${REPO}/actions/runs/$1" \
    --jq '[.path, .event, .status, (.conclusion // "-"), .head_sha, .repository.full_name, (.head_repository.full_name // "-"), ((now - (.created_at | fromdateiso8601)) / 3600 | floor | tostring)] | @tsv' 2>/dev/null
}

REASON="no marker left by a green ${WORKFLOW} run for ${PR_HEAD}"
while IFS="$(printf '\t')" read -r run_id run_head repo_id head_repo_id; do
  [ -n "${run_id}" ] || continue
  if [ "${run_head}" != "${PR_HEAD}" ]; then REASON="marker from run ${run_id} is for head ${run_head}, merged head is ${PR_HEAD}"; continue; fi
  if [ "${repo_id}" != "${head_repo_id}" ]; then REASON="marker from run ${run_id} comes from a fork"; continue; fi
  waited=0
  while :; do
    FACTS="$(run_facts "${run_id}")" || { REASON="reading run ${run_id} failed"; FACTS=""; break; }
    IFS="$(printf '\t')" read -r path event status conclusion head_sha repo head_repo age <<<"${FACTS}"
    # 必需的检查一绿就能合，GitHub 把那一轮的记录收成 completed 可能晚一两秒：等一小会儿。
    if [ "${status}" = "completed" ] || [ "${waited}" -ge "${WAIT_SECONDS}" ]; then break; fi
    sleep "${POLL_SECONDS}"
    waited=$((waited + POLL_SECONDS))
  done
  [ -n "${FACTS}" ] || continue
  if [ "${path}" != "${WORKFLOW}" ]; then REASON="run ${run_id} is ${path}, not ${WORKFLOW}"; continue; fi
  if [ "${event}" != "pull_request" ]; then REASON="run ${run_id} was triggered by ${event}"; continue; fi
  if [ "${status}" != "completed" ]; then REASON="run ${run_id} is still ${status}"; continue; fi
  if [ "${conclusion}" != "success" ]; then REASON="run ${run_id} ended ${conclusion}"; continue; fi
  if [ "${head_sha}" != "${PR_HEAD}" ]; then REASON="run ${run_id} head is ${head_sha}"; continue; fi
  if [ "${repo}" != "${REPO}" ] || [ "${head_repo}" != "${REPO}" ]; then REASON="run ${run_id} belongs to ${repo} / ${head_repo}"; continue; fi
  case "${age}" in '' | *[!0-9]*) REASON="run ${run_id} has no readable age"; continue ;; esac
  if [ "${age}" -ge "${MAX_AGE_HOURS}" ]; then REASON="run ${run_id} is ${age} h old (limit ${MAX_AGE_HOURS})"; continue; fi
  note "tree ${TREE} was verified by run ${run_id} (${WORKFLOW}, pull_request, success, head ${PR_HEAD}, ${age} h old): checks skipped"
  echo true
  exit 0
done <<<"${ARTIFACTS}"
no "${REASON}"
