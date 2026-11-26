#!/bin/bash
# Moving SkyCut from the installer disk into Applications (docs/build/build-and-packaging.md "Installing from the DMG"):
# the launch wiring (asked before anything starts, the flow's decisions performed as decided, the AI helper's launches
# marked, Connect AI refused from the disk, eject without -force, no administrator rights), the launch rule and the flow's
# decisions in every case, the alerts' buttons, the move against scratch folders (empty, replacing, running before or
# during the copy, unwritable, failing halfway) with ad-hoc signed fixture bundles, the running probe on real processes,
# the installer disk and its eject on real scratch disk images. Launches no App; never touches the real
# /Applications, the Trash or a running SkyCut. Needs codesign and hdiutil (CI's macOS runners have both).
set -euo pipefail
. "$(dirname "$0")/native-arch.sh"
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
WORK="$(mktemp -d "${TMPDIR:-/tmp/}srtflow-move.XXXXXX")"
# The physical path (/private/var/…): `mount` lists mount points that way, and the cleanup below matches on it.
WORK="$(cd "${WORK}" && pwd -P)"
cleanup() {
  case "${WORK}" in */srtflow-move.*) ;; *) return ;; esac
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
line_of() { grep -n "$1" "${APP_SWIFT}" | head -1 | cut -d: -f1 || true; }
LAUNCH_LINE="$(line_of 'MoveToApplicationsLaunch.offer { \[self\] in startServices() }')"
DID_FINISH_LINE="$(line_of 'func applicationDidFinishLaunching')"
SERVICES_LINE="$(line_of 'private func startServices()')"
BRIDGE_LINE="$(line_of 'AIBridgeServer.shared.start()')"
if [ -z "${LAUNCH_LINE}" ] || [ -z "${DID_FINISH_LINE}" ] || [ -z "${SERVICES_LINE}" ] || [ -z "${BRIDGE_LINE}" ]; then
  fail "${APP_SWIFT}: applicationDidFinishLaunching must call MoveToApplicationsLaunch.offer { [self] in startServices() }, and startServices() start the AI channel"
elif [ "${DID_FINISH_LINE}" -ge "${LAUNCH_LINE}" ] || [ "${LAUNCH_LINE}" -ge "${SERVICES_LINE}" ] || [ "${SERVICES_LINE}" -ge "${BRIDGE_LINE}" ]; then
  fail "${APP_SWIFT}: the offer comes first in applicationDidFinishLaunching, and the AI channel starts only in startServices()"
fi
if [ "$(grep -c 'startServices()' "${APP_SWIFT}")" -ne 2 ] || [ "$(grep -c 'AIBridgeServer.shared.start()' "${APP_SWIFT}")" -ne 1 ]; then
  fail "${APP_SWIFT}: startServices() is called only by the offer and is the one place the AI channel starts"
fi
EJECT="Sources/SrtFlow/InstallerDisk.swift"
if [ "$(grep -c '"\$1" 2>/dev/null; do' "${EJECT}")" -ne 1 ] \
  || [ "$(grep -c 'exec /usr/bin/hdiutil detach "\$2" -quiet$' "${EJECT}")" -ne 1 ] \
  || [ "$(grep -v '^[[:space:]]*//' "${EJECT}" | grep -c 'hdiutil')" -ne 1 ]; then
  fail "${EJECT}: the eject waits for the process, then runs hdiutil detach once, without -force"
fi
# The flow's decisions are MoveToApplicationsFlow's (compiled and run below); the launch only performs them. Pinned here:
# the live running probe before asking and in the mover, Not Now carrying on, and a launch that quits never carrying on.
LAUNCH="Sources/SrtFlow/MoveToApplicationsLaunch.swift"
for line in 'exists: mover.hasItem(at: destination), running: RunningBundleProbe.isRunning(destination))' \
  'isRunning: RunningBundleProbe.isRunning,' \
  'if MoveToApplicationsFlow.continuesAfter(answer) { return continueLaunch() }' \
  'if end.continuesLaunch { continueLaunch() } else { NSApp.terminate(nil) }' \
  'finish(MoveToApplicationsFlow.end(outcome, opened: opened, disk: disk, original: original), appName: appName,'; do
  if [ "$(grep -cF -- "${line}" "${LAUNCH}")" -ne 1 ]; then
    fail "${LAUNCH}: missing or repeated: ${line}"
  fi
done
if [ "$(grep -c 'NSApp.terminate(' "${LAUNCH}")" -ne 1 ]; then
  fail "${LAUNCH}: NSApp.terminate only where the end says the launch doesn't carry on"
fi
# An AI-started launch never asks (the helper marks it), and Connect AI refuses while SkyCut runs from the disk.
HELPER="Sources/SrtFlowMCP/AppConnection.swift"
if [ "$(grep -cF 'static let launchMarker = "SRTFLOW_AI_LAUNCH=1"' "${HELPER}")" -ne 1 ] \
  || [ "$(grep -cF 'process.arguments = ["-g", "--env", Self.launchMarker, ' "${HELPER}")" -ne 2 ] \
  || [ "$(grep -cF 'static let aiLaunchKey = "SRTFLOW_AI_LAUNCH"' Sources/SrtFlow/MoveToApplicationsOffer.swift)" -ne 1 ]; then
  fail "${HELPER}: every launch the helper makes carries SRTFLOW_AI_LAUNCH=1, the variable MoveToApplicationsOffer.aiLaunchKey names"
fi
SETUP="Sources/SrtFlow/AIClientSetup.swift"
if [ "$(grep -cF 'if let refusal = installerDiskRefusal { message = refusal; return }' "${SETUP}")" -ne 2 ] \
  || [ "$(grep -cF 'MoveToApplicationsOffer.runsFromInstallerDisk(MoveToApplicationsLaunch.currentFacts().0)' "${SETUP}")" -ne 1 ]; then
  fail "${SETUP}: Connect and the setup copies refuse while SkyCut runs from the installer disk"
fi
NEW_FILES="Sources/SrtFlow/MoveToApplicationsOffer.swift Sources/SrtFlow/MoveToApplicationsFlow.swift ${LAUNCH} Sources/SrtFlow/MoveToApplicationsAlerts.swift Sources/SrtFlow/AppBundleMover.swift Sources/SrtFlow/AppBundleSignature.swift Sources/SrtFlow/InstallerDisk.swift Sources/SrtFlow/RunningBundleProbe.swift"
# shellcheck disable=SC2086
if grep -nE 'AuthorizationExecuteWithPrivileges|AuthorizationCreate|SMJobBless|SMAppService|administrator privileges|/usr/bin/sudo|"sudo"' ${NEW_FILES}; then
  fail "moving to Applications never asks for administrator rights"
fi

echo "==> build"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -wmo \
  Sources/SrtFlow/MoveToApplicationsOffer.swift \
  Sources/SrtFlow/MoveToApplicationsFlow.swift \
  Sources/SrtFlow/MoveToApplicationsAlerts.swift \
  Sources/SrtFlow/AppBundleMover.swift \
  Sources/SrtFlow/AppBundleSignature.swift \
  Sources/SrtFlow/InstallerDisk.swift \
  Sources/SrtFlow/RunningBundleProbe.swift \
  Sources/SrtFlow/Quarantine.swift \
  checks/MoveToApplications/main.swift \
  checks/MoveToApplications/Fixture.swift \
  checks/MoveToApplications/FlowChecks.swift \
  checks/MoveToApplications/AlertChecks.swift \
  checks/MoveToApplications/MoverChecks.swift \
  checks/MoveToApplications/ProbeChecks.swift \
  checks/MoveToApplications/DiskChecks.swift \
  -o "${WORK}/check-move-to-applications"
"${WORK}/check-move-to-applications" "${WORK}/scratch" || FAILED=1

if [ "${FAILED}" -ne 0 ]; then
  echo "move-to-applications: FAILED"
  exit 1
fi
echo "move-to-applications: all passed"
