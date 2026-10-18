#!/usr/bin/env bash
# CI 的 .build 缓存只许在同一个检出目录里恢复。
#
# 为什么：.build 里的模块缓存（ModuleCache 下的 .pcm）记着编它时检出目录的绝对路径
# （/Users/runner/work/<仓库名>/<仓库名>）。2026-10-18 仓库从 SrtFlow 改名 SkyCut 之后，检出目录变了，
# 缓存的 key 只看 Package.swift，旧目录编的缓存照样恢复回来，五组全部编不过：
#   precompiled file '…/SkyCut/SkyCut/.build/…/SwiftShims-….pcm' was compiled with module cache path
#   '/Users/runner/work/SrtFlow/SrtFlow/.build/…', but the path is currently '/Users/runner/work/SkyCut/SkyCut/.build/…'
# （docs/bugfixes/2026-10-18-ci-build-cache-breaks-after-repo-rename.md）。
#
# 钉着：.github/workflows/checks.yml 里缓存 .build 的那一步，key 和 restore-keys 都带 ${{ github.workspace }}。
set -euo pipefail
cd "$(dirname "$0")/.."

WORKFLOW=".github/workflows/checks.yml"
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}

# 缓存 .build 的那一步：从 `path: .build` 那一行起，到下一个 `- name:` 为止。
BLOCK="$(awk '
  /^[[:space:]]*path:[[:space:]]*\.build[[:space:]]*$/ { inside = 1 }
  inside && /^[[:space:]]*- name:/ { inside = 0 }
  inside { print }
' "${WORKFLOW}")"
if [ -z "${BLOCK}" ]; then
  fail "${WORKFLOW} 里找不到缓存 .build 的那一步（path: .build）：搬了位置就改这条守卫"
fi
KEY="$({ grep -E '^[[:space:]]*key:' <<<"${BLOCK}" || true; } | head -1)"
RESTORE="$({ grep -E '^[[:space:]]*restore-keys:' <<<"${BLOCK}" || true; } | head -1)"
if [ "$({ grep -c 'github.workspace' <<<"${KEY}" || true; })" -ne 1 ]; then
  fail "${WORKFLOW} 缓存 .build 的 key 不带 \${{ github.workspace }}：仓库改名 / 换检出目录后会恢复旧目录编的缓存（${KEY}）"
fi
if [ -n "${RESTORE}" ] && [ "$({ grep -c 'github.workspace' <<<"${RESTORE}" || true; })" -ne 1 ]; then
  fail "${WORKFLOW} 缓存 .build 的 restore-keys 不带 \${{ github.workspace }}：前缀照样匹配到旧目录的缓存（${RESTORE}）"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ ci-build-cache-key：.build 缓存的 key 和 restore-keys 都带检出目录"
