#!/usr/bin/env bash
# CI helper (the run on main after a merge): was this exact tree already verified by the pull request's last green run?
# Prints `true` only when every condition below holds; anything else (not a push, not a two-parent merge commit, no marker,
# API error, marker too old, the run that left the marker is not a green run of this repository's checks workflow for this
# pull request head) prints `false`: run everything as before. The reason goes to stderr.
#
# The marker is an artifact named `verified-tree-<tree sha>` that the summary job uploads at the end of a green pull_request
# run. The tree is the one that run checked out (GitHub's test merge of the pull request into its base).
# What is trusted is not the artifact but GitHub's own record of the run that uploaded it:
#   workflow file, event, status, conclusion, head commit, repository, age.
#
# Usage (repository root, `gh` on PATH, GH_TOKEN set):
#   scripts/ci-verified-tree.sh
# Environment for tests only: VERIFIED_TREE_WORKFLOW (default .github/workflows/checks.yml),
#   VERIFIED_TREE_MAX_AGE_HOURS (default 24), VERIFIED_TREE_WAIT_SECONDS (default 30).
set -uo pipefail

WORKFLOW="${VERIFIED_TREE_WORKFLOW:-.github/workflows/checks.yml}"
MAX_AGE_HOURS="${VERIFIED_TREE_MAX_AGE_HOURS:-24}"
WAIT_SECONDS="${VERIFIED_TREE_WAIT_SECONDS:-30}"

no() {
  echo "ci-verified-tree: $* -> run everything" >&2
  echo false
  exit 0
}

[ "${GITHUB_EVENT_NAME:-}" = "push" ] || no "event is ${GITHUB_EVENT_NAME:-unset}, not push"
REPO="${GITHUB_REPOSITORY:-}"
[ -n "${REPO}" ] || no "GITHUB_REPOSITORY is not set"
command -v gh >/dev/null 2>&1 || no "gh is not on PATH"
TREE="$(git rev-parse --verify -q 'HEAD^{tree}')" || no "cannot read the tree of HEAD"
PR_HEAD="$(git rev-parse --verify -q 'HEAD^2')" || no "HEAD is not a merge commit (no second parent)"
if git rev-parse --verify -q 'HEAD^3' >/dev/null; then no "HEAD has more than two parents"; fi

# Artifacts with the marker name. One line per artifact: run id, head sha, repository id, head repository id.
ARTIFACTS="$(gh api "repos/${REPO}/actions/artifacts?name=verified-tree-${TREE}&per_page=100" \
  --jq '.artifacts[] | select(.expired == false and .workflow_run != null) | [.workflow_run.id, .workflow_run.head_sha, .workflow_run.repository_id, .workflow_run.head_repository_id] | @tsv' 2>/dev/null)" \
  || no "listing artifacts failed"
[ -n "${ARTIFACTS}" ] || no "no marker for tree ${TREE}"

run_facts() {
  # path, event, status, conclusion, head sha, repository, head repository, age in whole hours
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
    # The merge can land a moment before GitHub closes the run record: wait a little for `completed`.
    if [ "${status}" = "completed" ] || [ "${waited}" -ge "${WAIT_SECONDS}" ]; then break; fi
    sleep 5
    waited=$((waited + 5))
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
  echo "ci-verified-tree: tree ${TREE} was verified by run ${run_id} (${WORKFLOW}, pull_request, success, head ${PR_HEAD}, ${age} h old, waited ${waited} s)" >&2
  echo true
  exit 0
done <<<"${ARTIFACTS}"
no "${REASON}"
