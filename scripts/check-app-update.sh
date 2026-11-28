#!/bin/bash
# SkyCut's updater (docs/architecture/app-updates.md): the feed's strict parsing, version order, who updates, the state
# machine, the retry record, what a restart waits for, and the menu check's window and menu item (pure), then the real
# flow against scratch folders: a loopback HTTP server (python3's http.server on 127.0.0.1, never the network) serving a
# feed and a DMG, real read-only images (hdiutil, -nobrowse at scratch mount points), the pipeline with kept downloads,
# staging with ad-hoc signed fixture bundles, the install at quit, a loop of atomic swaps killed at random instants (the
# app is never missing or half-written), what a launch reads and cleans, and the relaunch shell (with a recorder for
# /usr/bin/open). Every request's headers are recorded: nothing beyond the allow-list below (no identifier). Launches no
# App; never touches the real /Applications, the Trash, Application Support or a running SkyCut. Needs codesign, hdiutil
# and python3 (CI's macOS runners have them).
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
WORK="$(mktemp -d "${TMPDIR:-/tmp/}srtflow-update.XXXXXX")"
# The physical path (/private/var/…): `mount` lists mount points that way, and the cleanup below matches on it.
WORK="$(cd "${WORK}" && pwd -P)"
SERVER_PID=""
cleanup() {
  case "${WORK}" in */srtflow-update.*) ;; *) return ;; esac
  if [ -n "${SERVER_PID}" ]; then kill "${SERVER_PID}" 2>/dev/null || true; fi
  # Images a failed run left attached under the scratch folder; the fixture bundles unregistered (never opened, so
  # normally never registered); then the folder.
  mount | awk -v root="${WORK}" 'index($0, " on " root) { print $1 }' | while read -r device; do
    /usr/bin/hdiutil detach -quiet -force "${device}" || true
  done
  find "${WORK}" -type d -name '*.app' -prune 2>/dev/null | while read -r bundle; do unregister_test_app "${bundle}"; done
  chmod -R u+rwX "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
test_app_exit_signals

echo "==> build"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -wmo \
  Sources/SrtFlow/AppUpdate/AppUpdateVersion.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateFeed.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateRecords.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateRetry.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateEligibility.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateState.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateCheckFlow.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateStatusReport.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateBusy.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateFiles.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateLaunchFiles.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateHTTP.swift \
  Sources/SrtFlow/AppUpdate/AppUpdatePipeline.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateVerifier.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateStager.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateInstaller.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateRelaunch.swift \
  Sources/SrtFlow/MoveToApplicationsOffer.swift \
  Sources/SrtFlow/AppBundleSignature.swift \
  Sources/SrtFlow/Quarantine.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  checks/AppUpdate/main.swift \
  checks/AppUpdate/Fixture.swift \
  checks/AppUpdate/FeedChecks.swift \
  checks/AppUpdate/EligibilityChecks.swift \
  checks/AppUpdate/StateChecks.swift \
  checks/AppUpdate/CheckWindowChecks.swift \
  checks/AppUpdate/StatusReportChecks.swift \
  checks/AppUpdate/FlowChecks.swift \
  checks/AppUpdate/PipelineChecks.swift \
  checks/AppUpdate/InstallChecks.swift \
  checks/AppUpdate/LaunchChecks.swift \
  checks/AppUpdate/FilesChecks.swift \
  -o "${WORK}/check-app-update"

echo "==> loopback server"
mkdir -p "${WORK}/www"
# Every request's headers go to requests.log (one JSON line each): after the run, nothing beyond the allow-list below.
python3 -u - "${WORK}/www" "${WORK}/requests.log" > "${WORK}/server.port" 2> "${WORK}/server.log" <<'PYTHON' &
import http.server
import json
import os
import socketserver
import sys
import threading

os.chdir(sys.argv[1])
LOG = open(sys.argv[2], "a", buffering=1)
LOCK = threading.Lock()


class Recording(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def parse_request(self):
        parsed = super().parse_request()
        if parsed:
            with LOCK:
                LOG.write(json.dumps({"path": self.path, "headers": list(self.headers.items())}) + "\n")
        return parsed


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


with Server(("127.0.0.1", 0), Recording) as server:
    print(server.server_address[1], flush=True)
    server.serve_forever()
PYTHON
SERVER_PID=$!
PORT=""
for _ in $(seq 1 100); do
  PORT="$(head -1 "${WORK}/server.port" 2>/dev/null || true)"
  [ -n "${PORT}" ] && break
  sleep 0.1
done
if [ -z "${PORT}" ]; then
  echo "FAIL: the loopback server did not start"
  cat "${WORK}/server.log" || true
  exit 1
fi

FAILED=0
"${WORK}/check-app-update" "${WORK}/scratch" "http://127.0.0.1:${PORT}/" "${WORK}/www" || FAILED=1

# What every request carried (the server's record): standard headers only, `User-Agent: SkyCut`, `Accept: */*`, no cookie,
# no key, no machine id or other identifier, and no query string (docs/architecture/app-updates.md "Checking"). `Priority`
# is URLSession's own on newer systems. An empty record is a failure too: then nothing was checked.
echo "==> request headers"
python3 - "${WORK}/requests.log" <<'PYTHON' || FAILED=1
import json
import sys

ALLOWED = {"host", "user-agent", "accept", "accept-language", "accept-encoding", "connection", "cache-control", "priority"}
FIXED = {"user-agent": "SkyCut", "cache-control": "no-cache", "accept": "*/*"}
problems, requests = [], 0
for line in open(sys.argv[1], encoding="utf-8"):
    request = json.loads(line)
    requests += 1
    if "?" in request["path"]:
        problems.append(f"{request['path']}: a query string in the request")
    for name, value in request["headers"]:
        key = name.lower()
        if key not in ALLOWED:
            problems.append(f"{request['path']}: a header beyond the allow-list: {name}")
        elif key in FIXED and value != FIXED[key]:
            problems.append(f"{request['path']}: {name}: {value!r}, not {FIXED[key]!r}")
if requests < 10:
    problems.append(f"only {requests} requests recorded: the header check saw too little")
for problem in problems:
    print(f"FAIL: {problem}")
if problems:
    sys.exit(1)
print(f"request headers: {requests} requests, nothing beyond the allow-list")
PYTHON

# The release's feed writer (scripts/write-update-feed.sh) on fixture values: it writes only what SkyCut's parser reads back.
echo "==> the feed writer"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  Sources/SrtFlow/AppUpdate/AppUpdateVersion.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateFeed.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateRecords.swift \
  scripts/update-feed/FeedWriter.swift \
  -o "${WORK}/feed-writer"
NOTES="${WORK}/notes.json"
printf '%s' '{"zh-Hans": ["一", "二", "三"], "en": ["One", "Two", "Three"], "es": ["Uno", "Dos", "Tres"]}' > "${NOTES}"
SHA="$(printf 'ab%.0s' $(seq 1 32))"
DMG_URL="https://downloads.skylu.ai/skycut/SkyCut-0.19.0-abababababab-arm64.dmg"
writes() { # writes <label> <expect: yes|no> <feed-writer arguments after the output file…>
  local label="$1" expect="$2" out="${WORK}/feed-$RANDOM.json"
  shift 2
  if "${WORK}/feed-writer" "${out}" "$@" >/dev/null 2>&1; then
    if [ "${expect}" = no ]; then echo "FAIL: feed writer: ${label}: written, should be refused"; FAILED=1; fi
  else
    if [ "${expect}" = yes ]; then echo "FAIL: feed writer: ${label}: refused, should be written"; FAILED=1; fi
    if [ -e "${out}" ]; then echo "FAIL: feed writer: ${label}: a refused feed left a file"; FAILED=1; fi
  fi
}
writes "a release's feed" yes 0.19.0 1 15.0 "${DMG_URL}" 42431367 "${SHA}" "${NOTES}"
writes "the DMG on another host" no 0.19.0 1 15.0 "https://skylu.ai/download/skycut.dmg" 42431367 "${SHA}" "${NOTES}"
writes "the redirect instead of the object" no 0.19.0 1 15.0 "https://skylu.ai/download/skycut" 42431367 "${SHA}" "${NOTES}"
writes "a development version" no 0.19.0-local.1 1 15.0 "${DMG_URL}" 42431367 "${SHA}" "${NOTES}"
writes "an uppercase SHA-256" no 0.19.0 1 15.0 "${DMG_URL}" 42431367 "$(printf '%s' "${SHA}" | tr a-f A-F)" "${NOTES}"
writes "a zero size" no 0.19.0 1 15.0 "${DMG_URL}" 0 "${SHA}" "${NOTES}"
printf '%s' '{"zh-Hans": ["一"], "en": ["One"]}' > "${WORK}/notes-two.json"
writes "notes without Spanish" no 0.19.0 1 15.0 "${DMG_URL}" 42431367 "${SHA}" "${WORK}/notes-two.json"
printf '%s' '{"zh-Hans": [""], "en": ["One"], "es": ["Uno"]}' > "${WORK}/notes-empty.json"
writes "an empty note" no 0.19.0 1 15.0 "${DMG_URL}" 42431367 "${SHA}" "${WORK}/notes-empty.json"
LOCAL_DMG="http://127.0.0.1:8123/SkyCut-0.19.0-arm64.dmg"
writes "a loopback DMG for a test feed on that origin" yes 0.19.0 1 15.0 "${LOCAL_DMG}" 42431367 "${SHA}" "${NOTES}" "http://127.0.0.1:8123/skycut.json"
writes "a loopback DMG in a release feed" no 0.19.0 1 15.0 "${LOCAL_DMG}" 42431367 "${SHA}" "${NOTES}"
writes "a test feed address SkyCut refuses" no 0.19.0 1 15.0 "${LOCAL_DMG}" 42431367 "${SHA}" "${NOTES}" "http://example.com/skycut.json"

# The wrapper itself on a scratch image (docs/bugfixes/2026-11-27-feed-writer-apostrophe-never-parsed.md). Gatekeeper
# refuses an image that isn't notarized, so a wrapper run ends there, before the mount. Relative arguments given from
# another folder must reach that point (the wrapper cds to the repository), and its work folder must be gone. The mount
# and its cleanup (scripts/update-feed/mount.sh) then run on their own and fail right after the attach, in a folder reached
# through a link the way TMPDIR's /var is (`mount` prints the resolved path): nothing may stay attached.
echo "==> the feed writer's wrapper"
REPO="$(pwd)"
FIXTURE="${WORK}/wrapper/fixture.dmg"
mkdir -p "${WORK}/wrapper/elsewhere" "${WORK}/wrapper/tmp"
ln -s "${WORK}/wrapper/tmp" "${WORK}/wrapper/tmp-link"
/usr/bin/hdiutil create -quiet -size 2m -fs HFS+ -volname FeedWrapper "${FIXTURE}"
cp "${NOTES}" "${WORK}/wrapper/notes.json"
WRAPPER_OUTPUT="$(cd "${WORK}/wrapper/elsewhere" && TMPDIR="${WORK}/wrapper/tmp/" /bin/bash "${REPO}/scripts/write-update-feed.sh" \
  --test-feed http://127.0.0.1:8123/skycut.json ../fixture.dmg http://127.0.0.1:8123/fixture.dmg ../notes.json feed.json 2>&1 || true)"
case "${WRAPPER_OUTPUT}" in
  *"Gatekeeper doesn't accept ${WORK}/wrapper/elsewhere/../fixture.dmg as notarized Developer ID"*) ;;
  *) echo "FAIL: feed writer wrapper: relative arguments from another folder: ${WRAPPER_OUTPUT}"; FAILED=1 ;;
esac
cat > "${WORK}/wrapper/fails-after-mount.sh" <<'SH'
set -euo pipefail
. scripts/update-feed/mount.sh
feed_mount_init
trap feed_cleanup EXIT
feed_attach "$1"
if feed_mounted; then echo "mounted"; fi
exit 1
SH
MOUNT_OUTPUT="$(TMPDIR="${WORK}/wrapper/tmp-link/" /bin/bash "${WORK}/wrapper/fails-after-mount.sh" "${FIXTURE}" 2>&1 || true)"
if [ "${MOUNT_OUTPUT}" != "mounted" ]; then
  echo "FAIL: feed writer wrapper: the mount was not made, or feed_mounted missed it: ${MOUNT_OUTPUT}"; FAILED=1
fi
if [ "$(/usr/bin/hdiutil info | grep -cF "${FIXTURE}" || true)" != "0" ]; then
  echo "FAIL: feed writer wrapper: a run that failed after the mount left the DMG attached"; FAILED=1
fi
if [ -n "$(ls -A "${WORK}/wrapper/tmp")" ]; then
  echo "FAIL: feed writer wrapper: a work folder stayed: $(ls -A "${WORK}/wrapper/tmp")"; FAILED=1
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "app-update: FAILED"
  exit 1
fi
echo "app-update: all passed"
