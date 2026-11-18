#!/usr/bin/env bash
# Scan guard: the web-motion renderer's wiring (docs/architecture/web-motion-renderer.md). What scripts/check-web-motion.sh
# cannot see because it builds the pieces itself:
#   1. Package.swift ships the helper product skycut-web-motion (target SrtFlowWebMotion); the App links only the kit.
#   2. build-app.sh copies the helper into Contents/Helpers before signing; sign-app.sh refuses to sign without it and
#      signs it before the outer bundle (a nested binary signed after the outer one breaks the outer signature).
#   3. Pages are only ever rendered in the helper: no WKWebView in SkyCut's own web-motion code.
#   4. Every page goes through the lock: one place loads HTML (baseURL nil), the helper loads only locked HTML, every
#      configuration comes from Lockdown, which blocks every URL, keeps no data, opens no window, and switches off and
#      reads back the WebKit features that leaked past CSP and content rules (WebRTC, link preconnect).
#   5. The page clock waits for document.fonts.ready only while fonts are loading (after a refused navigation it never
#      settles: the render hung until its load limit).
#   6. The clock takeover was written for SkyCut: the probe tool's names (derived from OpenFilm) appear nowhere in Sources.
#   7. scripts/check-web-motion.sh runs in check-all (CI).
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}
count() { { grep -cF -- "$1" "$2" || true; }; }
line_of() { { grep -nF -- "$1" "$2" || true; } | awk -F: 'NR == 1 { print $1 }'; }

HELPER_DIR="Sources/SrtFlowWebMotion"
APP_DIR="Sources/SrtFlow/WebMotion"

echo "==> 1. Package.swift ships the helper"
if [ "$(count '.executable(name: "skycut-web-motion", targets: ["SrtFlowWebMotion"])' Package.swift)" -ne 1 ]; then
  fail "Package.swift has no product skycut-web-motion built from SrtFlowWebMotion"
fi

echo "==> 2. Packaging: copied into Contents/Helpers before signing, signed before the outer bundle"
COPY="$(line_of 'cp "$BUILD_DIR/skycut-web-motion" "$APP/Contents/Helpers/skycut-web-motion"' scripts/build-app.sh)"
SIGN_CALL="$(line_of 'scripts/signing/sign-app.sh "$APP"' scripts/build-app.sh)"
if [ -z "${COPY}" ] || [ -z "${SIGN_CALL}" ] || [ "${COPY}" -gt "${SIGN_CALL}" ]; then
  fail "scripts/build-app.sh must copy skycut-web-motion into Contents/Helpers before it calls sign-app.sh"
fi
SIGN="scripts/signing/sign-app.sh"
SIGN_HELPER="$(line_of 'codesign --force "$@" --timestamp=none "${APP}/Contents/Helpers/skycut-web-motion"' "${SIGN}")"
SIGN_OUTER="$(line_of 'codesign --force "$@" --timestamp=none "${APP}"' "${SIGN}")"
if [ -z "${SIGN_HELPER}" ] || [ -z "${SIGN_OUTER}" ] || [ "${SIGN_HELPER}" -gt "${SIGN_OUTER}" ]; then
  fail "${SIGN} must sign Contents/Helpers/skycut-web-motion before the outer bundle"
fi
if [ "$(count 'for helper in ffmpeg skycut-mcp skycut-web-motion; do' "${SIGN}")" -ne 1 ]; then
  fail "${SIGN} must refuse to sign an app without Contents/Helpers/skycut-web-motion"
fi

echo "==> 3. Pages render only in the helper"
IN_APP="$({ grep -rln 'WKWebView' "${APP_DIR}" || true; })"
if [ -n "${IN_APP}" ]; then
  fail "SkyCut's own web-motion code creates web views (pages must only run in the helper): ${IN_APP}"
fi

echo "==> 4. Every page goes through the lock"
LOADERS="$({ grep -rlF 'loadHTMLString(' "${HELPER_DIR}" || true; })"
if [ "${LOADERS}" != "${HELPER_DIR}/PageWorker.swift" ] || [ "$(count 'loadHTMLString(html, baseURL: nil)' "${HELPER_DIR}/PageWorker.swift")" -ne 1 ]; then
  fail "only PageWorker may load HTML, once, with baseURL nil (no file URL, no origin); found: ${LOADERS:-none}"
fi
RUN="${HELPER_DIR}/HelperRun.swift"
PAGE_LOADS="$({ grep -ohE '(page|worker)\.load\(' "${HELPER_DIR}"/*.swift || true; } | wc -l | tr -d ' ')"
if [ "$(count 'WebMotionPageHTML.locked(' "${RUN}")" -ne 2 ] || [ "${PAGE_LOADS}" -ne 2 ] \
  || [ "$({ grep -cE '(page|worker)\.load\(' "${RUN}" || true; })" -ne 2 ]; then
  fail "the helper must load exactly two pages (calibration, the page), both through WebMotionPageHTML.locked(…) in ${RUN}"
fi
CONFIGS="$({ grep -rlF 'WKWebViewConfiguration()' "${HELPER_DIR}" || true; })"
if [ "${CONFIGS}" != "${HELPER_DIR}/Lockdown.swift" ]; then
  fail "every web view configuration must come from Lockdown.configuration; WKWebViewConfiguration() found in: ${CONFIGS:-none}"
fi
LOCK="${HELPER_DIR}/Lockdown.swift"
for needle in '"url-filter":".*"},"action":{"type":"block"}' 'configuration.websiteDataStore = .nonPersistent()' \
  'for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }' \
  '"PeerConnectionEnabled", "LinkPreconnect", "LinkDNSPrefetchEnabled", "WebTransportEnabled",' \
  'if get(preferences, getSelector, feature) { throw LockdownError.stillOn(key) }' \
  'try switchOff(switchedOffFeatures, in: configuration.preferences)' \
  'decisionHandler(.deny)'; do
  if [ "$(count "${needle}" "${LOCK}")" -ne 1 ]; then
    fail "${LOCK} lost a lock: ${needle}"
  fi
done

echo "==> 5. document.fonts.ready only while fonts are loading"
CLOCK="${HELPER_DIR}/PageClock.swift"
if [ "$(count "if (document.fonts && document.fonts.status !== 'loaded') await document.fonts.ready;" "${CLOCK}")" -ne 1 ] \
  || [ "$({ grep -rhoF 'await document.fonts.ready' "${HELPER_DIR}" || true; } | wc -l | tr -d ' ')" -ne 1 ]; then
  fail "${CLOCK} must wait for document.fonts.ready only while document.fonts.status is not 'loaded'"
fi

echo "==> 6. The clock takeover was written for SkyCut"
PROBE_NAMES="$({ grep -rlE 'CLOCK_SHIM|FILM_CLOCK' Sources || true; })"
if [ -n "${PROBE_NAMES}" ]; then
  fail "the probe tool's clock (derived from OpenFilm) must not be copied or adapted: ${PROBE_NAMES}"
fi

echo "==> 7. The renderer checks run in check-all"
if [ "$(count 'scripts/check-web-motion.sh' scripts/check-all.sh)" -ne 1 ]; then
  fail "scripts/check-all.sh must run scripts/check-web-motion.sh (CI only runs what check-all lists)"
fi

echo "==> 8. Process discovery finishes before terminal output and live watch retries precede sampling"
if ! python3 - <<'PYTHON'
from pathlib import Path
run = Path("Sources/SrtFlowWebMotion/HelperRun.swift").read_text()
report = Path("Sources/SrtFlowWebMotion/HelperReport.swift").read_text()
parent = Path("Sources/SrtFlow/WebMotion/WebMotionHelperProcess.swift").read_text()
assert "self?.created.flatMap { $0.processIdentifiers }" in run, "discovery must read the live retained pages"
assert "report.beforeFinish = { [processTracker] in processTracker.finish() }" in run, "discovery must have a before-result finalizer"
finish = report[report.index("func finish("):]
assert finish.index("beforeFinish?()") < finish.index("emit(WebMotionEvent(kind: .result"), "final discovery must precede the terminal event"
watch = parent[parent.index("timer.setEventHandler"):]
assert watch.index("pinReported(using: watch.identityReader)") < watch.index("WebMotionMemoryWatch.footprint"), "identity retry must precede live memory sampling"
assert "await finishWatch(timer)" in parent, "watch handlers must drain before the final snapshot"
PYTHON
then
  fail "web-motion process discovery/identity lifecycle wiring drifted"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ web-motion-wiring: helper packaged and signed in order, pages only in the helper, every page locked"
