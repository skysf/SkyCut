#!/bin/bash
# Moving SkyCut from the installer disk into Applications (docs/build/build-and-packaging.md "Installing from the DMG"):
# the launch wiring (asked before anything starts, eject without -force, no administrator rights), the launch rule in every
# case, the move against scratch folders (empty, replacing, running, unwritable, failing halfway) with ad-hoc signed
# fixture bundles, the installer disk and its eject on real scratch disk images. Launches no App; never touches the real
# /Applications, the Trash or a running SkyCut. Needs codesign and hdiutil (CI's macOS runners have both).
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
WORK="$(mktemp -d "${TMPDIR:-/tmp/}srtflow-move.XXXXXX")"
cleanup() {
  # Images a failed run left attached under the scratch folder; the fixture bundles unregistered (they are never opened,
  # so normally never registered); then the folder, a locked fixture file included.
  mount | awk -v root="${WORK}" 'index($0, " on " root) { print $1 }' | while read -r device; do
    /usr/bin/hdiutil detach -quiet -force "${device}" || true
  done
  find "${WORK}" -type d -name '*.app' -prune 2>/dev/null | while read -r bundle; do unregister_test_app "${bundle}"; done
  chmod -R u+rwX "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT
test_app_exit_signals
FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }

echo "==> launch wiring"
APP_SWIFT="Sources/SrtFlow/SrtFlowApp.swift"
LAUNCH_LINE="$(grep -n 'MoveToApplicationsLaunch.offer { \[self\] in startServices() }' "${APP_SWIFT}" | cut -d: -f1 || true)"
DID_FINISH_LINE="$(grep -n 'func applicationDidFinishLaunching' "${APP_SWIFT}" | cut -d: -f1 || true)"
SERVICES_LINE="$(grep -n 'private func startServices()' "${APP_SWIFT}" | cut -d: -f1 || true)"
BRIDGE_LINE="$(grep -n 'AIBridgeServer.shared.start()' "${APP_SWIFT}" | cut -d: -f1 || true)"
if [ -z "${LAUNCH_LINE}" ] || [ -z "${DID_FINISH_LINE}" ] || [ -z "${SERVICES_LINE}" ] || [ -z "${BRIDGE_LINE}" ]; then
  fail "${APP_SWIFT}: applicationDidFinishLaunching must call MoveToApplicationsLaunch.offer { [self] in startServices() }, and startServices() start the AI channel"
elif [ "${DID_FINISH_LINE}" -ge "${LAUNCH_LINE}" ] || [ "${LAUNCH_LINE}" -ge "${SERVICES_LINE}" ] || [ "${SERVICES_LINE}" -ge "${BRIDGE_LINE}" ]; then
  fail "${APP_SWIFT}: the offer comes first in applicationDidFinishLaunching, and the AI channel starts only in startServices()"
fi
if [ "$(grep -c 'startServices()' "${APP_SWIFT}")" -ne 2 ]; then
  fail "${APP_SWIFT}: startServices() is called only by the offer (it never runs when SkyCut quits to reopen from Applications)"
fi
EJECT="Sources/SrtFlow/InstallerDisk.swift"
if [ "$(grep -c '"\$1" 2>/dev/null; do' "${EJECT}")" -ne 1 ] \
  || [ "$(grep -c 'exec /usr/bin/hdiutil detach "\$2" -quiet$' "${EJECT}")" -ne 1 ] \
  || [ "$(grep -v '^[[:space:]]*//' "${EJECT}" | grep -c 'hdiutil')" -ne 1 ]; then
  fail "${EJECT}: the eject waits for the process, then runs hdiutil detach once, without -force"
fi
NEW_FILES="Sources/SrtFlow/MoveToApplicationsOffer.swift Sources/SrtFlow/MoveToApplicationsLaunch.swift Sources/SrtFlow/MoveToApplicationsAlerts.swift Sources/SrtFlow/AppBundleMover.swift Sources/SrtFlow/AppBundleSignature.swift Sources/SrtFlow/InstallerDisk.swift"
# shellcheck disable=SC2086
if grep -nE 'AuthorizationExecuteWithPrivileges|AuthorizationCreate|SMJobBless|SMAppService|administrator privileges|/usr/bin/sudo|"sudo"' ${NEW_FILES}; then
  fail "moving to Applications never asks for administrator rights"
fi

echo "==> build"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -wmo \
  Sources/SrtFlow/MoveToApplicationsOffer.swift \
  Sources/SrtFlow/AppBundleMover.swift \
  Sources/SrtFlow/AppBundleSignature.swift \
  Sources/SrtFlow/InstallerDisk.swift \
  Sources/SrtFlow/Quarantine.swift \
  checks/MoveToApplications/main.swift \
  checks/MoveToApplications/Fixture.swift \
  checks/MoveToApplications/MoverChecks.swift \
  checks/MoveToApplications/DiskChecks.swift \
  -o "${WORK}/check-move-to-applications"
"${WORK}/check-move-to-applications" "${WORK}/scratch" || FAILED=1

if [ "${FAILED}" -ne 0 ]; then
  echo "move-to-applications: FAILED"
  exit 1
fi
echo "move-to-applications: all passed"
