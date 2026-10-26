#!/usr/bin/env bash
# 导出水印：加不加只有 WatermarkPolicy 说了算、只有导出器调 plan()、叠在烧字幕之后缩小之前（docs/architecture/export-watermark.md）。
# 行为（叠在哪、什么时候换、缩小之后还在那一角）在 scripts/check-export-watermark.sh。秒级扫描，不编译。
set -euo pipefail
cd "$(dirname "$0")/.."
GRAPH="Sources/SrtFlow/VideoEditExportGraph.swift"
EXPORTER="Sources/SrtFlow/VideoEditExporter.swift"

CALLERS="$(grep -rlF 'VideoEditExportGraph.plan(' Sources | LC_ALL=C sort | tr '\n' ' ' || true)"
if [ "${CALLERS}" != "${EXPORTER} " ]; then
  echo "✗ Sources 里只有 ${EXPORTER} 许调 VideoEditExportGraph.plan(（加不加水印要经 WatermarkPolicy），现在是：${CALLERS:-（没有）}" >&2
  exit 1
fi
ASKERS="$(grep -rlF 'WatermarkPolicy.mark(' Sources | LC_ALL=C sort | tr '\n' ' ' || true)"
if [ "${ASKERS}" != "${EXPORTER} " ]; then
  echo "✗ 只有 ${EXPORTER} 许问 WatermarkPolicy.mark()（别处不许自己判断加不加水印），现在是：${ASKERS:-（没有）}" >&2
  exit 1
fi
if [ "$(grep -cF 'let watermark = WatermarkPolicy.mark()' "${EXPORTER}" || true)" -ne 1 ] \
   || [ "$(grep -cF 'watermark: watermark,' "${EXPORTER}" || true)" -ne 1 ]; then
  echo "✗ ${EXPORTER} 没把 WatermarkPolicy 问到的水印传给 plan()" >&2
  exit 1
fi
BURN_AT="$(grep -n 'subtitles=filename=' "${GRAPH}" | head -1 | cut -d: -f1 || true)"
MARK_AT="$(grep -n 'try WatermarkExport.append(' "${GRAPH}" | head -1 | cut -d: -f1 || true)"
SCALE_AT="$(grep -n 'settings.resolution.cappedSize(width: width, height: height)' "${GRAPH}" | head -1 | cut -d: -f1 || true)"
MARKS="$(grep -cF 'try WatermarkExport.append(' "${GRAPH}" || true)"
if [ -z "${BURN_AT}" ] || [ -z "${MARK_AT}" ] || [ -z "${SCALE_AT}" ] || [ "${MARKS}" -ne 1 ] \
   || [ "${BURN_AT}" -gt "${MARK_AT}" ] || [ "${MARK_AT}" -gt "${SCALE_AT}" ]; then
  echo "✗ ${GRAPH} 里叠水印要正好一处、在烧字幕（第 ${BURN_AT:-?} 行）之后、缩到导出分辨率（第 ${SCALE_AT:-?} 行）之前；现在 ${MARKS} 处、在第 ${MARK_AT:-?} 行" >&2
  exit 1
fi
echo "✓ export-watermark-wiring：加不加水印只问 WatermarkPolicy、只有导出器调 plan()、叠在烧字幕之后缩小之前"
