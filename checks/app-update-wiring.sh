#!/bin/bash
# Scan guard: SkyCut's updater wiring that scripts/check-app-update.sh can't reach (docs/architecture/app-updates.md).
#   1. The update addresses (the feed, the download page) are written in AppUpdateFeed.swift only; the test hook's
#      defaults key is read only through AppUpdateFeed.Source.overrideKey.
#   2. The app is replaced only through the atomic exchange: renamex_np with RENAME_SWAP in AppUpdateInstaller.swift and
#      nowhere else; the quit's installer keeps the default swap; the installer moves nothing else onto the destination.
#      Nothing is deleted outside AppUpdateFiles.swift (remove, removeEmptyFolder: inside the Updates folder only, never
#      through a link at its root, renamed aside first); only the replaced app goes to the Trash.
#   3. The updater starts once, from startServices (after the move offer, never on the launch path itself); the install
#      runs at applicationWillTerminate, after the Compress / Burn In stop; the menu item follows About; Settings › General
#      holds the section; the pill is in the editor's toolbar (between the AI badge and the cloud tasks) and the tools' one.
#   4. A cancelled quit cancels Restart and Update (ProjectQuit.quitCancelled, set before NSApp.terminate).
#   5. Blocking work (reading the launch's facts, hashing a kept download, staging) runs on AppUpdateWork's queue, never the
#      Swift concurrency pool.
#   6. No administrator rights anywhere in the updater; the release team is the one scripts/signing/common.sh pins; every
#      UserDefaults key keeps the SrtFlow prefix (docs/architecture/product-name.md).
#   7. The check never touches the network: its binary takes only a 127.0.0.1 server, and only FlowChecks.swift and
#      PipelineChecks.swift transfer anything, every address their server's.
#   8. The coordinator, which the check doesn't compile (review FBU1, G1): the probe counts the app itself, never helpers;
#      the production verifier at quit and when staging (no empty verifier anywhere); an install only for `decision ==
#      .updates`; the launch reads and cleans the Updates folder only through AppUpdateLaunchFiles.take, which returns at
#      once unless `decision == .updates`; the restart's shell is AppUpdateRelaunch (waits for this pid, opens the path with
#      /usr/bin/open, never -n); the pipeline's outcome reaches the state machine; file effects go onto the work queue, only
#      for a copy that installs; a copy inside the Updates folder never updates; Settings shows the test hook while one is
#      set. And (review FBU2, F10) the schedule's origin, the retry record at launch, the real home folder, the cadence, a
#      cancelled download's silence and the record matched to the offer.
#   9. get_status's app_update (MCP-85) reads, never acts: one line in AIProjectTools.status takes AppUpdater.statusReport,
#      which only builds AppUpdateStatusReport (pure, Foundation only: no check, download, install, restart or quit).
# Usage: checks/app-update-wiring.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAILED=0
fail() { echo "✗ app-update-wiring: $1" >&2; FAILED=1; }
DIR="Sources/SrtFlow/AppUpdate"
[ -d "${DIR}" ] || { echo "✗ app-update-wiring: ${DIR} is missing (renamed? update this guard)" >&2; exit 1; }
count() { grep -c -F -- "$1" "$2" 2>/dev/null || true; }
line_of() { grep -n -F -- "$1" "$2" | head -1 | cut -d: -f1; }

# 1. One place for the addresses and the test hook.
for address in 'skylu.ai/updates' 'skylu.ai/download/skycut'; do
  HITS="$(grep -rl -F "${address}" Sources --include='*.swift' | sort | tr '\n' ' ')"
  [ "${HITS}" = "${DIR}/AppUpdateFeed.swift " ] || fail "${address} must be written only in ${DIR}/AppUpdateFeed.swift (found in: ${HITS:-nothing})"
done
HOOK="$(grep -rl -F '"SrtFlow.update.feedURL"' Sources --include='*.swift' | tr '\n' ' ')"
[ "${HOOK}" = "${DIR}/AppUpdateFeed.swift " ] || fail "the test hook's key must be written only in AppUpdateFeed.swift (found in: ${HOOK:-nothing})"

# 2. The only way onto the destination: the atomic exchange. (SrtFlowCore's ExclusiveInstall uses renamex_np with
# RENAME_EXCL for new files: another target, another flag.) Deleting: only inside the Updates folder.
code_hits() { grep -rlE "$1" "${2:-Sources/SrtFlow}" --include='*.swift' | while read -r file; do
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
[ "$(count 'guard let staged = files.stagedCopy(of: record) else {' "${INSTALLER}")" = 1 ] \
  || fail "the installer takes only the stager's own copy (AppUpdateFiles.stagedCopy)"
if grep -nE '(^|[^A-Za-z])(moveItem|replaceItem|copyItem|linkItem|createSymbolicLink)' "${INSTALLER}"; then
  fail "AppUpdateInstaller.swift moves, copies or replaces nothing itself: only the swap touches the destination"
fi
REMOVERS="$(code_hits 'removeItem[(]|unlink[(]|rmdir[(]|recycle[(]|Darwin[.]remove[(]' "${DIR}")"
[ "${REMOVERS}" = "${DIR}/AppUpdateFiles.swift " ] \
  || fail "the updater deletes only in AppUpdateFiles.swift (remove, removeEmptyFolder) (found in: ${REMOVERS:-nothing})"
for primitive in 'FileManager.default.removeItem(at:' 'rmdir(' 'unlink('; do
  [ "$(grep -c -F "${primitive}" "${DIR}/AppUpdateFiles.swift")" = 1 ] \
    || fail "AppUpdateFiles.swift deletes in one place each (${primitive}): after renaming aside, an empty folder, a link at removing.noindex"
done
TRASHERS="$(code_hits 'trashItem[(]' "${DIR}")"
[ "${TRASHERS}" = "${DIR}/AppUpdateLaunch.swift ${DIR}/AppUpdater.swift " ] \
  || fail "only the install at quit and the launch cleanup send anything to the Trash (found in: ${TRASHERS:-nothing})"
UPDATER="${DIR}/AppUpdater.swift"
[ "$(count 'let installer = AppUpdateInstaller(' "${UPDATER}")" = 1 ] && [ "$(count 'let outcome = installer.install(record, running: running)' "${UPDATER}")" = 1 ] \
  || fail "AppUpdater.installAtQuit builds the one installer and installs with it"
if grep -nE '\.swap[[:space:]]*=|swap:' "${UPDATER}"; then fail "the quit's installer must keep the default (atomic) swap"; fi

# 3. Where it is wired in.
APP="Sources/SrtFlow/SrtFlowApp.swift"
[ "$(grep -rl -F 'AppUpdater.shared.start()' Sources --include='*.swift' | tr '\n' ' ')" = "${APP} " ] \
  || fail "AppUpdater.shared.start() only in ${APP}"
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
[ "$(count 'AppUpdateWork.run { AppUpdateLaunch.read(files: files, source: source) }' "${UPDATER}")" = 1 ] \
  || fail "${UPDATER}: the launch's facts are read inside AppUpdateWork.run"
PIPELINE="${DIR}/AppUpdatePipeline.swift"
inside_work() { # inside_work <file> <the call> <the line that opens AppUpdateWork.run> : the call follows within 4 lines
  local call opener
  call="$(line_of "$2" "$1")"
  opener="$(grep -n -F -- "$3" "$1" | head -1 | cut -d: -f1)"
  [ -n "${call}" ] && [ -n "${opener}" ] && [ "${call}" -gt "${opener}" ] && [ $((call - opener)) -le 4 ] \
    || fail "$1: '$2' must run inside '$3'"
}
inside_work "${PIPELINE}" 'Result { try stager.stage(dmg, feed: feed, appName: appName, asked: asked) }' 'let staged = await AppUpdateWork.run'
inside_work "${PIPELINE}" 'return files.keptDownloadMatches(dmg, feed: feed)' 'let kept = await AppUpdateWork.run'

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
NETWORK="$(grep -lE 'AppUpdateHTTP\.(check|fetchFeed|download)\(' checks/AppUpdate/*.swift | tr '\n' ' ')"
[ "${NETWORK}" = "checks/AppUpdate/FlowChecks.swift " ] || fail "only FlowChecks.swift calls AppUpdateHTTP (found in: ${NETWORK:-nothing})"
PIPELINES="$(grep -lF 'AppUpdatePipeline.run(' checks/AppUpdate/*.swift | tr '\n' ' ')"
[ "${PIPELINES}" = "checks/AppUpdate/PipelineChecks.swift " ] || fail "only PipelineChecks.swift runs the pipeline (found in: ${PIPELINES:-nothing})"
for transfers in checks/AppUpdate/FlowChecks.swift checks/AppUpdate/PipelineChecks.swift; do
  if grep -nE '"https?://|URLSession|productionURL|downloadPageURL' "${transfers}"; then
    fail "${transfers} fetches nothing but its loopback server (server.url / server.source)"
  fi
done

# 8. The coordinator (review FBU1, G1: each line here was a sabotage nothing else caught).
[ "$(count 'othersRunning: { RunningBundleProbe.processes(inside: $0).contains { $0 != getpid() } },' "${UPDATER}")" = 1 ] \
  || fail "${UPDATER}: the install's probe counts the app itself (processes(inside:)), this process excepted"
if grep -rn 'processes(under:' "${DIR}"; then fail "the updater never counts helpers (processes(under:)): an AI client's skycut-mcp would block every install"; fi
INSTALLER_LINE="$(line_of 'let installer = AppUpdateInstaller(' "${UPDATER}")"
QUIT_VERIFY="$(line_of 'try AppUpdateVerifier.verify(staged, feed: feed, runningApp: bundle, running: running, atQuit: true)' "${UPDATER}")"
if [ -z "${INSTALLER_LINE}" ] || [ -z "${QUIT_VERIFY}" ] || [ "${QUIT_VERIFY}" -le "${INSTALLER_LINE}" ] || [ $((QUIT_VERIFY - INSTALLER_LINE)) -gt 3 ]; then
  fail "${UPDATER}: the installer at quit verifies with AppUpdateVerifier.verify(…, atQuit: true)"
fi
STAGER_LINE="$(line_of 'let stager = AppUpdateStager(files: files, bundleIdentifier: Bundle.main.bundleIdentifier ?? "") { copy, feed in' "${UPDATER}")"
STAGE_VERIFY="$(line_of 'try AppUpdateVerifier.verify(copy, feed: feed, runningApp: bundle, running: running, atQuit: false)' "${UPDATER}")"
if [ -z "${STAGER_LINE}" ] || [ -z "${STAGE_VERIFY}" ] || [ $((STAGE_VERIFY - STAGER_LINE)) -ne 1 ]; then
  fail "${UPDATER}: staging verifies with AppUpdateVerifier.verify(…, atQuit: false)"
fi
[ "$(count 'let outcome = await AppUpdatePipeline.run(feed, files: files, stager: stager, appName: bundle.lastPathComponent,' "${UPDATER}")" = 1 ] \
  || fail "${UPDATER}: the download runs the pipeline with that stager"
if grep -rnE '\{ *_ *, *_ *in *\}' "${DIR}"; then fail "no empty verifier (or other do-nothing closure taking two values) in the updater"; fi
[ "$(count 'guard decision == .updates, state.phase == .ready, let offer = state.offer, let running,' "${UPDATER}")" = 1 ] \
  || fail "${UPDATER}: installAtQuit installs only for decision == .updates and a ready (confirmed) copy"
[ "$(count 'self.send(outcome.event(for: feed, at: Date()))' "${UPDATER}")" = 1 ] || fail "${UPDATER}: the pipeline's outcome reaches the state machine"
for effect in 'AppUpdateWork.queue.addOperation { files.removeStaged(except: nil) }' 'AppUpdateWork.queue.addOperation { files.removeDownloads(except: kept.map(files.dmg(for:))) }' \
  'AppUpdateWork.queue.addOperation { files.writeRetry(record) }'; do
  [ "$(count "${effect}" "${UPDATER}")" = 1 ] || fail "${UPDATER}: missing or repeated file effect: ${effect}"
done
TOUCH_LINE="$(line_of 'if effect.touchesFiles {' "${UPDATER}")"
GATE_LINE="$(line_of 'guard decision == .updates else { return }' "${UPDATER}")"
if [ -z "${TOUCH_LINE}" ] || [ -z "${GATE_LINE}" ] || [ $((GATE_LINE - TOUCH_LINE)) -ne 1 ]; then
  fail "${UPDATER}: file effects run only for a copy that installs (review FBU2, F5)"
fi
# Review FBU2, F10: the coordinator's lines for U1, E5 and the cadence.
[ "$(count 'self?.check(from: .schedule)' "${UPDATER}")" = 1 ] && [ "$(grep -cE 'check\(from: \.(menu|settings)\)' "${UPDATER}")" = 0 ] \
  && [ "$(count 'updater.check(from: .menu)' "${DIR}/AppUpdateMenu.swift")" = 1 ] && [ "$(count 'updater.check(from: .settings)' "${DIR}/AppUpdateSettingsSection.swift")" = 1 ] \
  || fail "the schedule's check is the automatic one (.schedule), the menu's and Settings' the person's: a held DMG stays held"
[ "$(count 'retry: reading.files.retry,' "${UPDATER}")" = 1 ] || fail "${UPDATER}: the retry record read at launch reaches the state machine"
[ "$(count 'static let firstCheckDelay: Duration = .seconds(60)' "${UPDATER}")" = 1 ] \
  && [ "$(count 'static let checkInterval: Duration = .seconds(24 * 60 * 60)' "${UPDATER}")" = 1 ] \
  || fail "${UPDATER}: a check about a minute after launch, then every 24 hours"
CANCEL_LINE="$(line_of 'guard !Task.isCancelled, let self else { return }' "${UPDATER}")"
SEND_LINE="$(line_of 'self.send(outcome.event(for: feed, at: Date()))' "${UPDATER}")"
if [ -z "${CANCEL_LINE}" ] || [ -z "${SEND_LINE}" ] || [ $((SEND_LINE - CANCEL_LINE)) -ne 1 ]; then
  fail "${UPDATER}: a cancelled download reports nothing"
fi
[ "$(count 'let record = files.readStaged(), record.feed.isSameRelease(as: offer) else { return }' "${UPDATER}")" = 1 ] \
  || fail "${UPDATER}: installAtQuit installs only the record of the release on offer"
LAUNCH="${DIR}/AppUpdateLaunch.swift"
[ "$(count 'homeDirectory: manager.homeDirectoryForCurrentUser.path,' "${LAUNCH}")" = 1 ] \
  || fail "${LAUNCH}: the launch's facts carry the real home folder (the protected folders)"
[ "$(count 'let found = AppUpdateLaunchFiles.take(from: files, decision: decision, running: running, runningBundle: Bundle.main.bundleURL,' "${LAUNCH}")" = 1 ] \
  || fail "${LAUNCH}: the launch reads the Updates folder only through AppUpdateLaunchFiles.take, with its decision"
[ "$(count 'guard decision == .updates, let running else { return AppUpdateLaunchFiles() }' "${DIR}/AppUpdateLaunchFiles.swift")" = 1 ] \
  || fail "AppUpdateLaunchFiles.take touches nothing unless this copy installs (decision == .updates)"
for call in 'AppUpdateLaunchFiles.take(' 'detachLeftovers(in:' 'readInstalledNote()'; do
  CALLERS="$(grep -rlF "${call}" "${DIR}" | grep -v -e "${DIR}/AppUpdateLaunchFiles.swift" -e "${DIR}/AppUpdateStager.swift" -e "${DIR}/AppUpdateFiles.swift" | tr '\n' ' ')"
  case "${call}" in
    'AppUpdateLaunchFiles.take(') [ "${CALLERS}" = "${LAUNCH} " ] || fail "only AppUpdateLaunch takes the launch's files (found in: ${CALLERS:-nothing})" ;;
    *) [ -z "${CALLERS}" ] || fail "${call} only through AppUpdateLaunchFiles (found in: ${CALLERS})" ;;
  esac
done
[ "$(count 'insideUpdatesFolder: files.holds(bundle),' "${LAUNCH}")" = 1 ] || fail "${LAUNCH}: a copy inside the Updates folder is told apart (it never updates)"
[ "$(count 'root.appendingPathComponent("staged.noindex", isDirectory: true)' "${DIR}/AppUpdateFiles.swift")" = 1 ] \
  || fail "the staged copy lives under a folder ending in .noindex (Spotlight never lists it)"
RELAUNCH="${DIR}/AppUpdateRelaunch.swift"
[ "$(count 'AppUpdateRelaunch.start(Bundle.main.bundleURL, afterExitOf: ProcessInfo.processInfo.processIdentifier)' "${RESTART}")" = 1 ] \
  && [ "$(grep -rlF 'AppUpdateRelaunch.start(' "${DIR}" | tr '\n' ' ')" = "${RESTART} " ] \
  || fail "${RESTART}: the restart's shell is AppUpdateRelaunch, started once for this process and this bundle"
[ "$(count 'static let opener = "/usr/bin/open"' "${RELAUNCH}")" = 1 ] \
  && [ "$(count 'i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 600 ] && exit 0; sleep 0.1; done; \' "${RELAUNCH}")" = 1 ] \
  && [ "$(count '[ -f "$2/Contents/Info.plist" ] || exit 0; exec "$3" "$2"' "${RELAUNCH}")" = 1 ] \
  || fail "${RELAUNCH}: the shell waits for the pid, then opens the path alone with /usr/bin/open while it holds an app"
if grep -rnE 'open -n|"-n"|-n "\$2"' "${DIR}"; then fail "the updater never opens a second instance (open -n)"; fi
SETTINGS="${DIR}/AppUpdateSettingsSection.swift"
[ "$(count 'if let feed = updater.testFeedURL {' "${SETTINGS}")" = 1 ] && [ "$(count 'L10n("Test update feed: %@")' "${SETTINGS}")" = 1 ] \
  || fail "${SETTINGS}: the test hook's address shows while it is set"

# 9. get_status's app_update: read only.
STATUS_TOOL="Sources/SrtFlow/AIProjectTools.swift"
[ "$(count 'result["app_update"] = try? JSONValue.decode(AppUpdater.shared.statusReport.encoded())' "${STATUS_TOOL}")" = 1 ] \
  || fail "${STATUS_TOOL}: get_status reports app_update from AppUpdater.statusReport, once"
REPORT="${DIR}/AppUpdateStatusReport.swift"
[ "$(grep -c '^import ' "${REPORT}")" = 1 ] && [ "$(count 'import Foundation' "${REPORT}")" = 1 ] \
  || fail "${REPORT} is pure: it imports Foundation only"
if grep -nE 'AppUpdater|[.]check[(]|downloadAndInstall|requestRestart|quitToRestart|installAtQuit|send[(]|NSApp' "${REPORT}" \
  | grep -vE '^[0-9]+:[[:space:]]*//'; then
  fail "${REPORT} only maps a state it is given: no updater, no check, download, install, restart or quit"
fi
REPORT_LINE="$(line_of 'var statusReport: AppUpdateStatusReport {' "${UPDATER}")"
MAKE_LINE="$(line_of 'AppUpdateStatusReport.make(state, decision: decision, automatic: automatic, lastUpToDate: lastUpToDate,' "${UPDATER}")"
if [ -z "${REPORT_LINE}" ] || [ -z "${MAKE_LINE}" ] || [ $((MAKE_LINE - REPORT_LINE)) -ne 1 ]; then
  fail "${UPDATER}: statusReport only builds AppUpdateStatusReport from the published state"
fi

if [ "${FAILED}" -ne 0 ]; then exit 1; fi
echo "✓ app-update-wiring: one feed address, the atomic swap only, deletes inside Updates only, wired at start / quit / menu / Settings / toolbars, the coordinator pinned, get_status read only, no admin rights, no network in the check"
