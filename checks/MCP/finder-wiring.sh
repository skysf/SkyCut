#!/usr/bin/env bash
# Finder permission declarations used by open_folder from_finder. Sourced by scripts/check-mcp.sh before its scan exit.
# Moved intact to keep the MCP entry script below the repository file-size limit; no checks are skipped.

echo "==> 访达选中：Info.plist 里有控制访达的用途说明，每种界面语言都有"
# 没有 NSAppleEventsUsageDescription，macOS 不弹「想要控制访达」、直接拒绝，from_finder 永远拿不到东西（方案第 22 条）。
# InfoPlist.strings 按 Resources/*.lproj/ 现场找（加语言不用改这里）；一张都没找到就是目录搬了，当场红。
INFOPLIST_TABLES=(Sources/SrtFlow/Resources/*.lproj/InfoPlist.strings)
if [ "${#INFOPLIST_TABLES[@]}" -lt 2 ] || [ ! -f "${INFOPLIST_TABLES[0]}" ]; then
  echo "✗ Sources/SrtFlow/Resources/*.lproj/InfoPlist.strings 找到的不到两张：${INFOPLIST_TABLES[*]}" >&2
  exit 1
fi
for file in packaging/Info.plist "${INFOPLIST_TABLES[@]}"; do
  if [ "$(grep -c 'NSAppleEventsUsageDescription' "${file}" || true)" -ne 1 ]; then
    echo "✗ ${file} 里没有（或不止一条）NSAppleEventsUsageDescription：open_folder from_finder 问不了访达" >&2
    exit 1
  fi
done
echo "   ✓ Info.plist 和 ${#INFOPLIST_TABLES[@]} 张 InfoPlist.strings 都有控制访达的用途说明"

