#!/usr/bin/env bash
# 冒烟命令的日志包装：记录输出并原样交出退出码，不把最后一行 echo 的成功当成测试成功。
set -euo pipefail
if [ "$#" -lt 2 ]; then
  echo "Usage: run-logged.sh LOG COMMAND [ARG ...]" >&2
  exit 2
fi
SMOKE_LOG="$1"
shift
SMOKE_EXIT=0
"$@" >"${SMOKE_LOG}" 2>&1 || SMOKE_EXIT=$?
printf 'Smoke log: %s (exit=%s)\n' "${SMOKE_LOG}" "${SMOKE_EXIT}"
exit "${SMOKE_EXIT}"
