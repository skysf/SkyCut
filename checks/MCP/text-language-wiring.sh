#!/usr/bin/env bash
# A section of scripts/check-mcp.sh (sourced by it, not run alone): text the AI reads or translates. User text files decode only
# through SrtFlowCore's TextDecoding (docs/architecture/text-file-encoding.md), and translate_subtitles judges the source language
# from the text before trusting what the project recorded. Moved out of scripts/check-mcp.sh unchanged (2026-11-17: it passed the
# 600-line limit, docs/architecture/coding-standards.md).

echo "==> 用户文本文件的编码只走 TextDecoding"
# .utf16 几乎什么都解得出来，排在 GBK 前面 GBK 就永远轮不到（docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md）。
# 规则只许在 SrtFlowCore 的 TextDecoding 一处（docs/architecture/text-file-encoding.md）。
STRAY_UTF16="$(grep -rn 'encoding: \.utf16)' Sources | grep -v 'Sources/SrtFlowCore/TextDecoding.swift' || true)"
if [ -n "${STRAY_UTF16}" ]; then
  echo "✗ 这些地方自己在按 UTF-16 解码用户文件（改用 TextDecoding.decode）：" >&2
  echo "${STRAY_UTF16}" >&2
  exit 1
fi
echo "   ✓ 只有 TextDecoding 按 UTF-16 解码"

echo "==> 翻译：原文语言先按字判断，判不出来才用工程里记的"
# 反过来的话，AI 把原文改写成中文之后，系统照旧按「英文→韩文」去翻
#（docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md）。
SUBTITLE_TOOLS="Sources/SrtFlow/AISubtitleTools.swift"
SOURCE_BODY="$(awk '/private static func translationSource\(/,/^    \}/' "${SUBTITLE_TOOLS}")"
DETECT_AT="$(grep -n 'AITextLanguage\.dominant' <<<"${SOURCE_BODY}" | head -1 | cut -d: -f1 || true)"
STORED_AT="$(grep -n 'subtitleCompanion?\.sourceLanguage' <<<"${SOURCE_BODY}" | head -1 | cut -d: -f1 || true)"
if [ -z "${DETECT_AT}" ] || [ -z "${STORED_AT}" ] || [ "${DETECT_AT}" -gt "${STORED_AT}" ]; then
  echo "✗ ${SUBTITLE_TOOLS} 的 translationSource 没有先按字判断原文语言（判断在第 ${DETECT_AT:-?} 行、旧记录在第 ${STORED_AT:-?} 行）" >&2
  exit 1
fi
if [ "$(grep -c 'let source = try translationSource(args, project)' "${SUBTITLE_TOOLS}" || true)" -ne 1 ]; then
  echo "✗ translate_subtitles 没走 translationSource：原文语言又会信旧记录" >&2
  exit 1
fi
echo "   ✓ 先判断（第 ${DETECT_AT} 行）、再退回旧记录（第 ${STORED_AT} 行）"
