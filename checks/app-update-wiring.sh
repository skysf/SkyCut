#!/bin/bash
# Scan guard: SkyCut's updater wiring that scripts/check-app-update.sh can't reach (docs/architecture/app-updates.md).
#   1. The update addresses (the feed, the download page) are written in AppUpdateFeed.swift only; the test hook's
#      defaults key is read only through AppUpdateFeed.Source.overrideKey.
#   2. The app is replaced only through the atomic exchange: renamex_np with RENAME_SWAP in AppUpdateInstaller.swift and
#      nowhere else; the quit's installer keeps the default swap; the installer moves nothing else onto the destination.
#   3. The updater starts once, from startServices (after the move offer, never on the launch path itself); the install
#      runs at applicationWillTerminate, after the Compress / Burn In stop; the menu item follows About; Settings › General
#      holds the section; the pill is in the editor's toolbar (between the AI badge and the cloud tasks) and the tools' one.
#   4. A cancelled quit cancels Restart and Update (ProjectQuit.quitCancelled, set before NSApp.terminate).
#   5. Blocking work (reading the launch's facts, staging) runs on AppUpdateWork's queue, never the Swift concurrency pool.
#   6. No administrator rights anywhere in the updater; the release team is the one scripts/signing/common.sh pins; every
#      UserDefaults key keeps the SrtFlow prefix (docs/architecture/product-name.md).
#   7. The check never touches the network: its binary takes only a 127.0.0.1 server and fetches nothing else.
# Usage: checks/app-update-wiring.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAILED=0
fail() { echo "✗ app-update-wiring: $1" >&2; FAILED=1; }
DIR="Sources/SrtFlow/AppUpdate"
[ -d "${DIR}" ] || { echo "✗ app-update-wiring: ${DIR} is missing (renamed? update this guard)" >&2; exit 1; }
count() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }

# 1. One place for the addresses and the test hook.
for address in 'skylu.ai/updates' 'skylu.ai/download/skycut'; do
  HITS="$(grep -rl -F "${address}" Sources --include='*.swift' | sort | tr '\n' ' ')"
  [ "${HITS}" = "${DIR}/AppUpdateFeed.swift " ] || fail "${address} must be written only in ${DIR}/AppUpdateFeed.swift (found in: ${HITS:-nothing})"
done
HOOK="$(grep -rl -F '"SrtFlow.update.feedURL"' Sources --include='*.swift' | tr '\n' ' ')"
[ "${HOOK}" = "${DIR}/AppUpdateFeed.swift " ] || fail "the test hook's key must be written only in AppUpdateFeed.swift (found in: ${HOOK:-nothing})"

# 2. The only way onto the destination: the atomic exchange. (SrtFlowCore's ExclusiveInstall uses renamex_np with
# RENAME_EXCL for new files: another target, another flag.)
code_hits() { grep -rlE "$1" Sources/SrtFlow --include='*.swift' | while read -r file; do
  if awk -v pattern="$1" '$0 !~ /^[[:space:]]*\/\// && $0 ~ pattern { found = 1 } END { exit !found }' "${file}"; then
    echo "${file}"
  fi; done | sort | tr '\n' ' '; }
for call in 'renamex_np' 'RENAME_SWAP'; do
  SWAPS="$(code_hits "${call}")"
  [ "${SWAPS}" = "${DIR}/AppUpdateInstaller.swift " ] || fail "${call} in the app only in AppUpdateInstaller.swift (found in: ${SWAPS:-nothing})"
done
INSTALLER="${DIR}/AppUpdateInstaller.swift"
[ "$(count 'renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0' "${INSTALLER}")" = 1 ] \
  || fail "AppUpdateInstaller.exchange must swap with renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP))"
[ "$(count 'var swap: (_ staged: URL, _ destination: URL) throws -> Void = AppUpdateInstaller.exchange' "${INSTALLER}")" = 1 ] \
  || fail "the installer's swap must default to AppUpdateInstaller.exchange"
[ "$(count 'try swap(staged, destination)' "${INSTALLER}")" = 1 ] || fail "the installer must put the new copy in place with one swap"
if grep -nE '(^|[^A-Za-z])(moveItem|replaceItem|copyItem|linkItem|createSymbolicLink)' "${INSTALLER}"; then
  fail "AppUpdateInstaller.swift moves, copies or replaces nothing itself: only the swap touches the destination"
fi
UPDATER="${DIR}/AppUpdater.swift"
[ "$(count 'let installer = AppUpdateInstaller(' "${UPDATER}")" = 1 ] && [ "$(count 'let outcome = installer.install(record, running: running)' "${UPDATER}")" = 1 ] \
  || fail "AppUpdater.installAtQuit builds the one installer and installs with it"
if grep -nE '\.swap[[:space:]]*=|swap:' "${UPDATER}"; then fail "the quit's installer must keep the default (atomic) swap"; fi

# 3. Where it is wired in.
APP="Sources/SrtFlow/SrtFlowApp.swift"
[ "$(grep -rl -F 'AppUpdater.shared.start()' Sources --include='*.swift' | tr '\n' ' ')" = "${APP} " ] \
  || fail "AppUpdater.shared.start() only in ${APP}"
line_of() { grep -n -F -- "$1" "$2" | head -1 | cut -d: -f1; }
SERVICES="$(line_of 'private func startServices()' "${APP}")"
START="$(line_of 'AppUpdater.shared.start()' "${APP}")"
DID_FINISH="$(line_of 'func applicationDidFinishLaunching' "${APP}")"
WILL_TERMINATE="$(line_of 'func applicationWillTerminate' "${APP}")"
ENCODE="$(line_of 'MainActor.assumeIsolated { EncodeJob.stopAllForQuit() }' "${APP}")"
INSTALL="$(line_of 'MainActor.assumeIsolated { AppUpdater.shared.installAtQuit() }' "${APP}")"
if [ -z "${SERVICES}" ] || [ -z "${START}" ] || [ -z "${WILL_TERMINATE}" ] || [ -z "${ENCODE}" ] || [ -z "${INSTALL}" ] || [ -z "${DID_FINISH}" ]; then
  fail "${APP}: startServices() starts the updater, applicationWillTerminate installs at quit after the Compress / Burn In stop"
elif [ "${START}" -le "${SERVICES}" ] || [ "${START}" -ge "$(line_of 'private func expireOptimizedMedia()' "${APP}")" ] \
  || [ "${INSTALL}" -le "${ENCODE}" ] || [ "${ENCODE}" -le "${WILL_TERMINATE}" ]; then
  fail "${APP}: the updater starts inside startServices(); the install is the last step of applicationWillTerminate"
fi
[ "$(count 'CommandGroup(after: .appInfo) { AppUpdateMenuItem() }' "${APP}")" = 1 ] || fail "${APP}: the menu item follows About"
[ "$(count 'AppUpdateSettingsSection()' Sources/SrtFlow/SettingsWindowView.swift)" = 1 ] || fail "Settings › General holds AppUpdateSettingsSection"
BAR="Sources/SrtFlow/VideoEditWorkbenchToolbar.swift"
BANNER="$(line_of 'AIActivityBanner(project: project)' "${BAR}")"
PILL="$(line_of 'AppUpdatePill(project: project)' "${BAR}")"
CLOUD="$(line_of 'CloudTasksButton(project: project)' "${BAR}")"
if [ -z "${PILL}" ] || [ -z "${BANNER}" ] || [ -z "${CLOUD}" ] || [ "${PILL}" -le "${BANNER}" ] || [ "${PILL}" -ge "${CLOUD}" ]; then
  fail "${BAR}: the pill sits between the AI badge and the cloud tasks"
fi
[ "$(count 'AppUpdatePill(project: nil)' Sources/SrtFlow/WorkbenchToolbar.swift)" = 1 ] || fail "the tools' toolbar has the pill too"

# 4. A cancelled quit cancels the restart.
QUIT="Sources/SrtFlow/ProjectQuit.swift"
[ "$(count 'if !ready { quitCancelled?() }' "${QUIT}")" = 1 ] || fail "${QUIT}: a quit that a project stopped tells quitCancelled"
RESTART="${DIR}/AppUpdateRestart.swift"
HOOK_LINE="$(line_of 'ProjectQuit.quitCancelled = { AppUpdateRestart.quitting = false }' "${RESTART}")"
TERMINATE_LINE="$(line_of 'NSApp.terminate(nil)' "${RESTART}")"
if [ -z "${HOOK_LINE}" ] || [ -z "${TERMINATE_LINE}" ] || [ "${HOOK_LINE}" -ge "${TERMINATE_LINE}" ]; then
  fail "${RESTART}: Restart and Update hooks ProjectQuit.quitCancelled before it calls NSApp.terminate"
fi
[ "$(grep -rl 'NSApp.terminate(' "${DIR}" | tr '\n' ' ')" = "${RESTART} " ] || fail "only AppUpdateRestart quits SkyCut for the updater"

# 5. Blocking work off the concurrency pool.
for call in 'AppUpdateWork.run { AppUpdateLaunch.read(files: files, source: source) }' \
  'return Result { try stager.stage(dmg, feed: feed, appName: bundle.lastPathComponent, asked: asked) }'; do
  [ "$(count "${call}" "${UPDATER}")" = 1 ] || fail "${UPDATER}: missing or repeated: ${call}"
done
STAGE_LINE="$(line_of 'return Result { try stager.stage(' "${UPDATER}")"
WORK_LINE="$(grep -n 'let staged = await AppUpdateWork.run' "${UPDATER}" | head -1 | cut -d: -f1)"
if [ -z "${STAGE_LINE}" ] || [ -z "${WORK_LINE}" ] || [ $((STAGE_LINE - WORK_LINE)) -gt 3 ] || [ "${STAGE_LINE}" -le "${WORK_LINE}" ]; then
  fail "${UPDATER}: staging runs inside AppUpdateWork.run"
fi

# 6. No administrator rights; the pinned team; identity-class keys.
if grep -rnE 'AuthorizationExecuteWithPrivileges|AuthorizationCreate|SMJobBless|SMAppService|administrator privileges|/usr/bin/sudo|"sudo"' "${DIR}"; then
  fail "the updater never asks for administrator rights"
fi
TEAM="$(grep -E '^SIGNING_TEAM_ID=' scripts/signing/common.sh | cut -d'"' -f2)"
[ -n "${TEAM}" ] && [ "$(count "static let releaseTeam = \"${TEAM}\"" "${DIR}/AppUpdateEligibility.swift")" = 1 ] \
  || fail "AppUpdateEligibility.releaseTeam must be scripts/signing/common.sh's SIGNING_TEAM_ID (${TEAM:-not found})"
BAD_KEYS="$(grep -rhoE 'static let [A-Za-z]*Key = "[^"]*"' "${DIR}" | grep -v '= "SrtFlow\.' || true)"
[ -z "${BAD_KEYS}" ] || fail "UserDefaults keys keep the SrtFlow prefix: ${BAD_KEYS}"

# 7. No network in the check.
[ "$(count 'guard arguments.count == 4, let base = URL(string: arguments[2]), base.host == "127.0.0.1" else {' checks/AppUpdate/main.swift)" = 1 ] \
  || fail "checks/AppUpdate/main.swift takes only a 127.0.0.1 server"
[ "$(count '"${WORK}/check-app-update" "${WORK}/scratch" "http://127.0.0.1:${PORT}/" "${WORK}/www"' scripts/check-app-update.sh)" = 1 ] \
  || fail "scripts/check-app-update.sh points the check at its loopback server only"
# Every transfer is in FlowChecks.swift, whose addresses all come from the loopback server (no literal URL there).
NETWORK="$(grep -lE 'AppUpdateHTTP\.(check|fetchFeed|download)\(' checks/AppUpdate/*.swift | tr '\n' ' ')"
[ "${NETWORK}" = "checks/AppUpdate/FlowChecks.swift " ] || fail "only FlowChecks.swift transfers anything (found in: ${NETWORK:-nothing})"
if grep -nE '"https?://|URLSession|productionURL|downloadPageURL' checks/AppUpdate/FlowChecks.swift; then
  fail "checks/AppUpdate/FlowChecks.swift fetches nothing but its loopback server (server.url / server.source)"
fi

if [ "${FAILED}" -ne 0 ]; then exit 1; fi
echo "✓ app-update-wiring: one feed address, the atomic swap only, wired at start / quit / menu / Settings / toolbars, no admin rights, no network in the check"
