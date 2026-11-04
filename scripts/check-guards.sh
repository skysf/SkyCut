#!/usr/bin/env bash
# 跑全部秒级的扫描守卫（checks/*.sh），一个都不漏：推之前、搬代码 / 改名之后先跑它。
#
# 为什么要有这个入口（docs/bugfixes/2026-10-01-pr132-first-ci-run-guard-in-moved-insert.md）：扫描守卫按文件名找接线，
# 把代码搬进新文件之后，守卫还指着旧文件就红 —— 本地凭记忆挑着跑几条守卫，漏掉的那一条只在 CI 上红（2026-09-25 PR #71、
# 2026-09-29 PR #84、2026-10-01 PR #132 三次都是这样）。全部跑一遍只要几十秒，不编译、不碰 .build，可以和编自检的脚本并行。
# `scripts/check-all.sh` 照样逐条跑它们；这里只是本地推之前的快入口。这里是按通配符找的，check-all 是按清单跑的：
# checks/ 下新加的守卫没进 check-all，这里照样绿、CI 却一次都不跑（2026-11-04 查出四条，
# docs/bugfixes/2026-11-04-scan-guards-never-ran-in-ci.md）—— 所以 checks/check-all-shards.sh 钉着两边对得上。
#
# 自检脚本里编译之前的那一段扫描也算（2026-10-18 起：`scripts/check-mcp.sh --scans-only`）—— 它们 source 进来的
# checks/MCP/*-wiring.sh 不在 checks/ 顶层，以前只在 CI 上跑得到（docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md）。
#
# 一律用原生 arm64 的 /bin/bash 跑（2026-11-04 起）：和 CI、check-all.sh 用同一个解析器（3.2，陷阱 5、6 都是 bash 5 放过、
# 3.2 解析错）；PATH 上的 bash 在用户的 M1 上还是 Intel 版 Homebrew 的、只有 x86_64，每条守卫连同它起的几千个 grep / awk
# 都走 Rosetta —— 全部守卫 6–7 分钟，原生 /bin/bash 89 秒（docs/build/build-and-packaging.md「本地怎么跑检查」）。
#
# 用法：scripts/check-guards.sh（推之前一般跑 scripts/check-local.sh，它先跑这一个）
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."

FAILED=()
for guard in checks/*.sh "scripts/check-mcp.sh --scans-only"; do
  # shellcheck disable=SC2086
  if output="$(/bin/bash ${guard} 2>&1)"; then
    printf '  ✓ %s\n' "${guard}"
  else
    printf '  ✗ %s\n' "${guard}"
    printf '%s\n' "${output}" | grep -E '✗' | head -n 5 | sed 's/^/      /'
    FAILED+=("${guard}")
  fi
done
if [ "${#FAILED[@]}" -ne 0 ]; then
  echo "✗ check-guards：${#FAILED[@]} 条扫描守卫红了：${FAILED[*]}" >&2
  exit 1
fi
echo "✓ check-guards：全部扫描守卫绿"
