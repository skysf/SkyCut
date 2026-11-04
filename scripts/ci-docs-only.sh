#!/usr/bin/env bash
# CI 用：这一次改动是不是「只改了文档」。是就打印 true，别的情况（包括算不出来）一律打印 false。
#
# 只改文档的 PR / 合并，CI 不编 App、不跑自检，第 1 组只跑一遍扫描守卫（scripts/check-guards.sh，文档索引
# docs-index-drift 就在里面）就收工；原来要把 5 台 runner 占满两轮（PR 一轮、合并后 main 一轮），各约 10 分钟。
# 2026-10 下旬到 11-04 合的 60 个 PR 里有 10 个只改了文档。
#
# 「文档」是一份严格的白名单：docs/ 下的文件，根目录的 AGENTS.md、README.md、SrtFlow-Requirements.md。
# 查过（2026-11-04）：自检里读这几样内容的只有扫描守卫 docs-index-drift，编译、跑二进制的检查一样都不读。
# 白名单外的任何一个文件（代码、脚本、检查、CI、资源、Package.swift……）、一个文件都没改、git 算不出来、
# 路径被 git 加了引号（非 ASCII 文件名）都按「不是」：宁可多跑一轮，不许漏跑。
# 改名按「删掉旧的 + 加上新的」算（--no-renames）：把 Sources/ 下的文件挪进 docs/，旧路径照样算改了代码。
#
# 用法（在仓库根目录跑）：
#   scripts/ci-docs-only.sh                                    # 比 HEAD 和它的第一个父提交
#   printf '%s\n' docs/a.md AGENTS.md | scripts/ci-docs-only.sh -   # 从标准输入读改了哪些路径（自检用）
#
# 比 HEAD^1：PR 上检出的是 GitHub 造的合并提交（第一个父提交是 main 的最新提交），合并进 main 之后检出的是
# `gh pr merge --merge` 的合并提交（第一个父提交是合并之前的 main）—— 两种都正好是「这个 PR 带来的改动」。
set -uo pipefail

if [ "${1:-}" = "-" ]; then
  CHANGED="$(cat)"
elif ! CHANGED="$(git diff --no-renames --name-only HEAD^1 HEAD 2>/dev/null)"; then
  echo false
  exit 0
fi

if [ -z "${CHANGED}" ]; then
  echo false
  exit 0
fi

# 白名单外的路径有几条（全在白名单里时 grep -c 打印 0、退出码 1，所以兜 || true）。
OUTSIDE="$(grep -cvE '^(docs/.+|AGENTS\.md|README\.md|SrtFlow-Requirements\.md)$' <<<"${CHANGED}" || true)"
if [ "${OUTSIDE}" = "0" ]; then
  echo true
else
  echo false
fi
