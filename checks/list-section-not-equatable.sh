#!/usr/bin/env bash
# 扫描守卫：body 里有 `Section` 的视图，构造处不许套 `.equatable()`。
#
# 由来（docs/bugfixes/2026-10-18-ai-projects-sidebar-rows-never-shown.md）：主窗口侧边栏的「AI 在剪的工程」写成
# `AIProjectsSidebarSection(...).equatable()` 挂在 List 里。List 按视图的结构拆行，`.equatable()` 包出来的
# EquatableView 只算**一行**：里面的 Section 只画出标题（「AI Projects」），工程那几行一行都没有 —— 后台工程在界面上
# 看不见、停不了、关不掉。探针（同一个 List、三种行）实测：去掉 `.equatable()` 三组都对，套上三组都只剩标题。
# 原来的接线守卫还按字面钉着带 `.equatable()` 的那一句，把错的写法钉成了对的。
#
# 要省重算：输入只放值类型（SwiftUI 自己按值比）；真要 `.equatable()`，就别让这个视图产出 Section / 多行。
#
# 用法：checks/list-section-not-equatable.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件往往还没 add，会被静默跳过。用文件系统枚举（下面两遍同样）。
COUNT="$(find Sources -name '*.swift' -type f | grep -c '\.swift$' || true)"
if [ "${COUNT}" -eq 0 ]; then
  echo "✗ 一个 Swift 文件都没扫到 —— 扫空 = 假绿，看看 Sources 是不是改名了" >&2
  exit 1
fi

# 第一遍：哪些 `struct X: … View` 的定义里写了 `Section {` / `Section(`（注释不算）。所有文件一个 awk 扫完。
NAMES="$(find Sources -name '*.swift' -type f -print0 | LC_ALL=C sort -z | xargs -0 awk '
  FNR == 1 { inside = 0; opened = 0 }
  { code = $0; sub(/\/\/.*/, "", code) }
  !inside && match(code, /^[[:space:]]*((private|fileprivate|internal|public)[[:space:]]+)?struct[[:space:]]+[A-Za-z0-9_]+[^{]*View/) {
    name = code
    sub(/^[[:space:]]*((private|fileprivate|internal|public)[[:space:]]+)?struct[[:space:]]+/, "", name)
    sub(/[^A-Za-z0-9_].*$/, "", name)
    inside = 1; depth = 0; seen = 0; opened = 0
  }
  inside {
    if (code ~ /(^|[^A-Za-z0-9_.])Section[[:space:]]*[({]/) seen = 1
    n = gsub(/\{/, "{", code); m = gsub(/\}/, "}", code)
    depth += n - m
    if (n > 0) opened = 1
    if (opened && depth <= 0) { if (seen) print name; inside = 0; opened = 0 }
  }
' | LC_ALL=C sort -u)"

# 扫空 = 假绿：侧边栏那一节一定在里面。
if ! grep -qx 'AIProjectsSidebarSection' <<<"${NAMES}"; then
  echo "✗ 没认出 AIProjectsSidebarSection 是带 Section 的视图 —— 守卫的认法坏了（或者它被改名 / 搬走了，同步这里）" >&2
  exit 1
fi

# 第二遍：这些视图的构造处，同一行或紧跟的几行（多行参数、尾随的修饰器）里出现 `.equatable()` 就红。
NAME_LIST="$(tr '\n' ' ' <<<"${NAMES}")"
HITS="$(find Sources -name '*.swift' -type f -print0 | LC_ALL=C sort -z | xargs -0 awk -v names="${NAME_LIST}" '
  BEGIN { count = split(names, list, " ") }
  FNR == 1 { pending = 0 }
  { code = $0; sub(/\/\/.*/, "", code) }
  {
    for (i = 1; i <= count; i++) {
      name = list[i]
      if (name == "") continue
      if (code ~ ("(^|[^A-Za-z0-9_])" name "\\(") && code !~ ("struct[[:space:]]+" name)) {
        if (code ~ /\.equatable\(\)/) { print name " " FILENAME ":" FNR; pending = 0 }
        else { pending = 6; at = FNR; who = name }
        next
      }
    }
  }
  pending > 0 {
    if (code ~ /^[[:space:]]*\.equatable\(\)/ || code ~ /\)[[:space:]]*\.equatable\(\)/) { print who " " FILENAME ":" at; pending = 0; next }
    if (code ~ /^[[:space:]]*$/) { pending = 0; next }
    pending--
  }
')"

FAILED=0
if [ -n "${HITS}" ]; then
  while IFS= read -r hit; do
    echo "✗ ${hit%% *} 的 body 里有 Section，构造处却套了 .equatable()（List 里整节只算一行、只剩标题）：${hit#* }"
  done <<<"${HITS}"
  FAILED=1
fi

if [ "${FAILED}" = "0" ]; then
  echo "✓ list-section-not-equatable：带 Section 的视图（$(tr '\n' ' ' <<<"${NAMES}")）构造处都没套 .equatable()"
fi
exit "${FAILED}"
