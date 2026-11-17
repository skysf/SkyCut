#!/usr/bin/env bash
# A section of scripts/check-mcp.sh (sourced by it, not run alone): "does the picture cover the frame" has one geometry, and every
# answer the AI gets comes from it. The pure values are in checks/MCP/PictureCoverageChecks.swift and ClipCoverageChecks.swift; this
# scans the production wiring: look writes uncovered from AIPictureCoverage and lists on_screen from the same clips, get_timeline /
# edit replies / set_keyframes write fills_frame from ClipCoverage, and no AI file checks "covers the canvas" by itself again.
# Rule: docs/architecture/preview-free-transform.md; case: docs/bugfixes/2026-11-17-fills-frame-ignores-rotation-and-motion.md.

echo "==> Picture coverage: fills_frame and look's uncovered come from one geometry"
COVERAGE_FAILED=0
coverage_fail() {
  echo "✗ $1" >&2
  COVERAGE_FAILED=1
}
LOOK_FILE="Sources/SrtFlow/AILookTool.swift"
if [ "$(grep -c 'AIPictureCoverage.uncovered(state, at: frame.time)' "${LOOK_FILE}" || true)" -ne 1 ] \
   || [ "$(grep -c 'entry\["uncovered"\]' "${LOOK_FILE}" || true)" -ne 1 ]; then
  coverage_fail "${LOOK_FILE}: look's timeline frames no longer carry uncovered from AIPictureCoverage (bare corners go unreported again)"
fi
if [ "$(grep -c 'ClipCoverage.onScreen(in: state, at: time)' "${LOOK_FILE}" || true)" -ne 1 ] \
   || grep -q 'ClipVisibility.visible' "${LOOK_FILE}"; then
  coverage_fail "${LOOK_FILE}: on_screen must list the clips ClipCoverage.onScreen finds (the same ones uncovered counts)"
fi
if [ "$(grep -c 'AIPictureCoverage.fields(summary.fill)' Sources/SrtFlow/AITimelineSummary.swift || true)" -ne 1 ] \
   || grep -q '"fills_frame"' Sources/SrtFlow/AITimelineSummary.swift; then
  coverage_fail "Sources/SrtFlow/AITimelineSummary.swift: picture must write fills_frame through AIPictureCoverage.fields"
fi
if [ "$(grep -c 'let fill = ClipCoverage.fill(clip, canvas: canvas)' Sources/SrtFlow/AIFrameFit.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'fillsFrame: fill.fillsFrame' Sources/SrtFlow/AIFrameFit.swift || true)" -ne 1 ]; then
  coverage_fail "Sources/SrtFlow/AIFrameFit.swift: describe's fillsFrame must be ClipCoverage.fill (rotation and keyframes included)"
fi
if [ "$(grep -c 'result\["picture"\] = picture' Sources/SrtFlow/AITimelineTools.swift || true)" -ne 1 ]; then
  coverage_fail "Sources/SrtFlow/AITimelineTools.swift: set_keyframes no longer reports picture (motion that bares the frame goes unsaid)"
fi
# The axis-aligned test this replaced (frame.minX <= 0.5 …) must not come back in the AI layer: rotation and motion would be ignored.
STRAY_COVER="$(grep -ln 'minX <= 0.5' Sources/SrtFlow/AI*.swift || true)"
if [ -n "${STRAY_COVER}" ]; then
  coverage_fail "these AI files test 'covers the canvas' on their own (use ClipCoverage / PictureCoverage): ${STRAY_COVER}"
fi
if [ "${COVERAGE_FAILED}" -ne 0 ]; then
  exit 1
fi
echo "   ✓ look's uncovered and on_screen, picture's fills_frame and set_keyframes' picture all read ClipCoverage / PictureCoverage"
