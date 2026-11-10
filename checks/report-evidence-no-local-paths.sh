#!/usr/bin/env bash
# 扫描守卫：docs/reports/ 里的实测证据（*.json）和实测脚本自带的数据（scripts/gui-smoke/client-measure/*.json）不许带本机的绝对路径。
#
# 真客户端实测的证据 JSON 是从会话记录里抽出来的：模型的回答、终端命令、工具参数里都会写到本机的临时目录和家目录，
# 而临时目录的名字里带着用户的账户名（/private/tmp/claude-<uid>/-Users-<账户名>-…）。
# scripts/gui-smoke/client-measure/report.py 的 scrub 把它们换成 $RUN / ~；2026-11-10 基线那一份它漏了两种
# （模型把路径写短、跑完改过名的目录），是提交前手查出来的（docs/bugfixes/2026-11-10-measurement-evidence-local-paths.md）。
# 同一天还发现 PR 3 把开发时草稿目录里的两份调用表（脚本根本不用）一起拷进了仓库，里面也写着这种路径。这条守卫让漏网的进不了仓库。
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='(/private)?/(tmp|var/folders)/[^"[:space:]]+|/Users/[^"/[:space:]]+'
FAILED=0
for f in docs/reports/*.json scripts/gui-smoke/client-measure/*.json; do
  [ -e "$f" ] || continue
  hits="$( { grep -oE "$PATTERN" "$f" || true; } | sort -u)"
  if [ -n "$hits" ]; then
    echo "✗ $f 里有本机的绝对路径（换成 \$RUN 或 ~：scripts/gui-smoke/client-measure/report.py 的 scrub）：" >&2
    echo "$hits" | sed 's/^/    /' >&2
    FAILED=1
  fi
done
if [ "$FAILED" -eq 0 ]; then
  echo "✓ 实测证据和实测脚本的数据里没有本机路径"
fi
exit "$FAILED"
