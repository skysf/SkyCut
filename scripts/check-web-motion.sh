#!/usr/bin/env bash
# The web-motion renderer (docs/architecture/web-motion-renderer.md): builds the helper skycut-web-motion, compiles
# SkyCut's side of it (the render API, the helper runner, the memory watch, the teardown) with the checks in
# checks/WebMotion/, and renders normal and hostile pages through them:
#   - the page clock takeover itself (production script in a WKWebView: timers, rAF, Date, seeded randomness, CSS);
#   - normal pages pass the six page checks, two renders are pixel-identical, the movie is tagged premultiplied;
#   - alpha: known values in the decoded movie, fast and public paths agree, a broken fast path switches by itself;
#   - hostile pages: endless loops (frame, load), page error, kept state, no motion.frame, a huge canvas;
#   - nothing reaches outside: a local TCP + UDP listener sees no connection or datagram, no file is read, no permission;
#   - memory: a hog is killed at its budget, injected "out of memory" kills, the backstops stop a helper with no limits;
#   - this program (standing in for SkyCut) keeps its main thread beating throughout.
# Needs a logged-in macOS session (WebKit), as on CI's runners and the user's Mac; no window opens.
#
# Usage: scripts/check-local.sh web-motion
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta terminals need an explicit arm64 (docs/build/build-and-packaging.md).
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --product skycut-web-motion (the helper and its kit), --target SrtFlowCore"
# SwiftPM prints compile errors on stdout: quiet on success, the full output on failure.
BUILD_OUT="$(swift build ${ARCH_FLAG} --product skycut-web-motion 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/webmotioncheck"
trap 'rm -rf "$(dirname "${OUT}")"' EXIT

echo "==> compile the check"
xcrun swiftc \
  -target "${TRIPLE}" \
  -wmo \
  -I "${BUILD_DIR}/Modules" \
  -o "${OUT}" \
  Sources/SrtFlow/WebMotion/WebMotionRenderer.swift \
  Sources/SrtFlow/WebMotion/WebMotionCacheFiles.swift \
  Sources/SrtFlow/WebMotion/WebMotionHelperProcess.swift \
  Sources/SrtFlow/WebMotion/WebMotionMemoryWatch.swift \
  Sources/SrtFlow/WebMotion/WebMotionProcessTeardown.swift \
  Sources/SrtFlow/Quarantine.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/AppTheme.swift \
  Sources/SrtFlow/AppThemePalette.swift \
  Sources/SrtFlow/AppThemeAppearance.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlowWebMotion/PageClock.swift \
  Sources/SrtFlowWebMotion/PageProcessTracker.swift \
  checks/WebMotion/*.swift \
  "${BUILD_DIR}"/SrtFlowCore.build/*.o \
  "${BUILD_DIR}"/SrtFlowWebMotionKit.build/*.o

echo "==> run (bounded: a hang is a failure after 600 s, not a stuck check)"
SRTFLOW_WEB_MOTION_HELPER="${BUILD_DIR}/skycut-web-motion" perl -e 'alarm shift; exec @ARGV' 600 "${OUT}"
