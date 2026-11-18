#!/usr/bin/env bash
# A section of scripts/check-mcp.sh (sourced by it, not run alone): a canvas change keeps every clip's shape on the production path.
# The pure values are in checks/MCP/CanvasReframeChecks.swift; this only scans that perform really runs CanvasReframe and that set_canvas
# reports it. Rule: docs/architecture/preview-free-transform.md; case: docs/bugfixes/2026-11-17-canvas-change-stretches-framed-clips.md.

echo "==> Canvas change: perform keeps clips' shapes, set_canvas says what it reframed"
PERFORM_FILE="Sources/SrtFlow/VideoEditProject.swift"
PERFORM_BODY="$(awk '/^    func perform\(/{inside=1} inside{print} inside&&/^    }$/{exit}' "${PERFORM_FILE}" || true)"
if [ -z "${PERFORM_BODY}" ]; then
  echo "✗ ${PERFORM_FILE}: perform not found; this scan lost its target (renamed? update checks/MCP/canvas-wiring.sh)" >&2
  exit 1
fi
MAGNET_LINE="$(printf '%s\n' "${PERFORM_BODY}" | grep -n 'MainMagnet.settle(&next, after: before)' | head -1 | cut -d: -f1 || true)"
REFRAME_LINE="$(printf '%s\n' "${PERFORM_BODY}" | grep -n 'CanvasReframe.keepShapes(&next, after: before)' | head -1 | cut -d: -f1 || true)"
LINKAGE_LINE="$(printf '%s\n' "${PERFORM_BODY}" | grep -n 'TimelineLinkage.follow(from: before' | head -1 | cut -d: -f1 || true)"
REFRAME_COUNT="$(printf '%s\n' "${PERFORM_BODY}" | grep -c 'CanvasReframe.keepShapes(' || true)"
if [ -z "${REFRAME_LINE}" ] || [ "${REFRAME_COUNT}" -ne 1 ]; then
  echo "✗ ${PERFORM_FILE}: perform does not run CanvasReframe.keepShapes once: a canvas change stretches framed clips again" >&2
  exit 1
fi
# After the magnet: packing V1 can change the first clip, and with it an auto canvas.
if [ -z "${MAGNET_LINE}" ] || [ "${REFRAME_LINE}" -le "${MAGNET_LINE}" ]; then
  echo "✗ ${PERFORM_FILE}: CanvasReframe.keepShapes must run after MainMagnet.settle (the magnet can change an auto canvas)" >&2
  exit 1
fi
if [ -z "${LINKAGE_LINE}" ] || [ "${REFRAME_LINE}" -le "${LINKAGE_LINE}" ]; then
  echo "✗ ${PERFORM_FILE}: CanvasReframe.keepShapes must run after linkage; internal geometry changes must not suppress linked moves or deletions" >&2
  exit 1
fi
if [ "$(grep -c 'AICanvasReframe.fields(before: before, after: project.state' Sources/SrtFlow/AIOverlayTools.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/AIOverlayTools.swift: set_canvas no longer says which clips it reframed or no longer fill the frame" >&2
  exit 1
fi
echo "   ✓ perform keeps clips' shapes after the magnet; set_canvas reports reframed / no_longer_fill"

# The explicit ending must reach the same saved duration consumed by preview and export.
if ! grep -Fq 'project.perform { $0.minimumDuration = duration }' Sources/SrtFlow/AIOverlayTools.swift \
  || ! grep -Fq 'AIUndoGrouping.step(project.effectiveUndoManager) { apply() }' Sources/SrtFlow/AIOverlayTools.swift \
  || ! grep -Fq 'var duration: Double { TimelineDuration.end(self) }' Sources/SrtFlow/VideoEditModels.swift \
  || ! grep -Fq 'decodeIfPresent(Double.self, forKey: .minimumDuration)' Sources/SrtFlow/VideoEditModels.swift; then
  echo "✗ The explicit canvas ending lost its production commit, duration, or persistence path" >&2
  exit 1
fi
echo "   ✓ set_canvas retains the ending through the saved timeline duration"
