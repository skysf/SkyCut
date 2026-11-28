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
#  10. The menu check's window (UPD1, 2026-11-28; code only, comments and strings blanked): never modal (no runModal or
#      NSAlert in the updater); shown only from run-loop turns, AppUpdater's `.openCheckWindow` and `.answer` effects being
#      the one RunLoop.main.perform call each and the menu's download item the one showDownload, never inside a Swift task
#      or a dispatch block (docs/bugfixes/2026-11-27-check-for-updates-crash-tracking-owner-selectors.md); the window file
#      starts no task, dispatches nothing, and with its content never reaches a download, the network or the state machine
#      (closing only hides; Cancel only asks AppUpdater.cancelCheck, which stops nothing but the check's own task); it draws
#      what AppUpdateCheckDisplay reads from the updater's state, opens through the flow, ticks on a run-loop timer, and
#      showDownload starts no check; the menu item is AppUpdateMenuEntry's (one check at a time: greyed while checking);
#      a cancelled check's task reports nothing.
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

# 10. The menu check's window (UPD1). Executable code only: whole files with comments and string literals blanked out
#     (checks/Shared/swift-code.pl), so a call may wrap and a comment never counts (reviews CXC1, CXC2 on the alert this
#     window replaced). Lines that hold a title are pinned twice: their code shape here, their words by a raw count below.
read -r -d '' WINDOW_SCAN <<'PERL' || true
require "./checks/Shared/swift-code.pl";
sub at { my ($code, $offset) = @_; return 1 + (substr($code, 0, $offset) =~ tr/\n//); }
while (my $text = <>) {
    my $code = swift_code($text);
    my $file = $ARGV;
    print "SCANNED $file\n";
    while ($code =~ /\bAppUpdateCheckWindow\s*\.\s*shared\s*\.\s*(open|show|showDownload)\s*\(/g) {
        print "CALL $1 $file:" . at($code, $-[0]) . "\n";
    }
    if ($file =~ m{/AppUpdate/}) {
        while ($code =~ /\b(runModal|NSAlert)\b/g) { print "MODAL $1 $file:" . at($code, $-[0]) . "\n"; }
    }
    print "OPEN $file\n"
        if $code =~ /\bcase\s+\.openCheckWindow\s*:\s*RunLoop\.main\.perform \{ MainActor\.assumeIsolated \{ AppUpdateCheckWindow\.shared\.open\(\) \} \}/;
    print "ANSWER $file\n"
        if $code =~ /\bcase\s+\.answer\s*\(\s*let\s+answer\s*\)\s*:\s*RunLoop\.main\.perform \{ MainActor\.assumeIsolated \{ AppUpdateCheckWindow\.shared\.show\(answer\) \} \}/;
    if ($file =~ m{/AppUpdateCheck(Window|Content)\.swift$}) {
        while ($code =~ /\b(Task|DispatchQueue|asyncAfter|await|URLSession|URLRequest|AppUpdateHTTP|AppUpdatePipeline|cancelDownload|downloadTask|automaticChanged|makeKeyAndOrderFront|makeKey|orderFrontRegardless|activate)\b|\b(send)\s*\(/g) {
            print "FORBIDDEN " . ($1 // $2) . " $file:" . at($code, $-[0]) . "\n";
        }
    }
    if ($file =~ m{/AppUpdateCheckWindow\.swift$}) {
        print "OPENFLOW $file\n" if $code =~ /func\s+open\s*\(\s*\)\s*\{[^{}]*apply\(flow\.chosen\(at:\s*Self\.now\)\)\s*\}/;
        if ($code =~ /func\s+showDownload\s*\(\s*\)\s*\{(.*?)\n    \}/s) {
            my $body = $1;
            print "SHOWDOWNLOAD $file\n" if $body =~ /apply\(flow\.showing\(\.downloading\(offer\)\)\)/ && $body !~ /\bcheck\s*\(/;
        }
        print "CLOSE $file\n"
            if $code =~ /func\s+windowShouldClose\s*\(\s*_\s+sender\s*:\s*NSWindow\s*\)\s*->\s*Bool\s*\{\s*apply\(flow\.closed\(\)\)\s*return\s+false\s*\}/;
        print "CANCEL $file\n"
            if $code =~ /case\s+\.cancel\s*:\s*apply\(flow\.cancelled\(\)\)/ && $code =~ /if\s+step\.stopsCheck\s*\{\s*AppUpdater\.shared\.cancelCheck\(\)\s*\}/;
        print "DISPLAY $file\n" if $code =~ /AppUpdateCheckDisplay\.make\(window\.content,\s*state:\s*updater\.state,\s*mode:\s*updater\.mode\)/;
        print "TIMER $file\n" if $code =~ /RunLoop\.main\.add\(timer,\s*forMode:\s*\.common\)/;
        print "PRESENT $file\n" if $code =~ /private\s+func\s+present\(\)\s*\{[^{}]*\{[^{}]*\}[^{}]*panel\.orderFront\(nil\)\s*\}/;
        print "ESCAPE $file\n" if $code =~ /func\s+escape\(\)\s*\{\s*perform\(\.dismiss\)\s*\}/;
    }
    if ($file =~ m{/AppUpdateCheckContent\.swift$}) {
        my $buttons = () = $code =~ /\bButton\s*\(/g;
        print "BUTTONS $buttons $file\n";
        print "TIPS $file\n"
            if $code =~ /func\s+secondaryButton\([^)]*help:\s*LocalizedStringKey\)\s*->\s*some\s+View\s*\{\s*Button\(title\)\s*\{\s*perform\(action\)\s*\}\s*\.instantHelp\(help\)\s*\}/
            && $code =~ /func\s+defaultButton\([^)]*help:\s*LocalizedStringKey\)\s*->\s*some\s+View\s*\{\s*Button\(title\)\s*\{\s*perform\(action\)\s*\}[^}]*\.keyboardShortcut\(\.defaultAction\)\s*\.instantHelp\(help,\s*shortcut:\s*\.defaultAction\)\s*\}/;
        print "RETURN $file\n" if $code =~ /defaultButton\(\s*,\s*\.restart,/;
        print "NOTESCAP $file\n" if $code =~ /AppUpdateNotes\(heading:\s*,\s*lines:[^\n]*\n?\s*maxHeight:\s*Self\.notesMaxHeight\)/;
    }
    if ($file =~ m{/AppUpdatePopoverParts\.swift$}) {
        print "SCROLL $file\n"
            if $code =~ /ScrollView\(\.vertical\)\s*\{\s*list\s*\}\s*\.frame\(maxHeight:\s*maxHeight\)\s*\.fixedSize\(horizontal:\s*false,\s*vertical:\s*true\)/;
    }
    if ($file =~ m{/AppUpdateMenu\.swift$}) {
        print "MENU $file\n"
            if $code =~ /switch\s+AppUpdateMenuEntry\.make\(updater\.state\)/
            && $code =~ /case\s+\.checking\s*:\s*Button\(\s*\)\s*\{\s*\}\s*\.disabled\(true\)/
            && $code =~ /case\s+\.downloading\(let\s+percent\)\s*:\s*Button\(String\(format:\s*L10n\(\s*\),\s*percent\)\)\s*\{\s*AppUpdateCheckWindow\.shared\.showDownload\(\)\s*\}/
            && $code =~ /case\s+\.check\s*:\s*Button\(\s*\)\s*\{\s*updater\.check\(from:\s*\.menu\)\s*\}/;
    }
    if ($file =~ m{/AppUpdater\.swift$}) {
        print "STOP $file\n" if $code =~ /case\s+\.stopCheck\s*:\s*checkTask\?\.cancel\(\)\s*checkTask\s*=\s*nil/;
        print "CANCELCHECK $file\n" if $code =~ /func\s+cancelCheck\(\)\s*\{\s*send\(\.checkCancelled\)\s*\}/;
        print "JOIN $file\n" if $code =~ /send\(\.checkStarted\(origin\)\)\s*guard\s+!alreadyChecking\s+else\s*\{\s*return\s*\}/;
        print "QUIET $file\n"
            if $code =~ /let\s+result\s*=\s*await\s+AppUpdateHTTP\.check\(source,\s*running:\s*running\)\s*guard\s+!Task\.isCancelled\s+else\s*\{\s*return\s*\}/;
    }
}
PERL
SWIFT_FILES="$(find Sources -name '*.swift' -type f | wc -l | tr -d ' ')"
WINDOW="${DIR}/AppUpdateCheckWindow.swift"
MENU="${DIR}/AppUpdateMenu.swift"
if WINDOW_OUT="$(find Sources -name '*.swift' -type f -print0 | xargs -0 perl -0777 -e "${WINDOW_SCAN}")"; then
  [ "$(grep -c '^SCANNED ' <<<"${WINDOW_OUT}" || true)" = "${SWIFT_FILES}" ] \
    || fail "the check-window scan read fewer than the ${SWIFT_FILES} Swift files under Sources (a partial scan is a false green)"
  calls() { sed -n "s/^CALL $1 //p" <<<"${WINDOW_OUT}"; }
  only_call() { # only_call <name> <file>: exactly one executable reference to AppUpdateCheckWindow.shared.<name>(, in <file>
    local found
    found="$(calls "$1")"
    [ "$(grep -c . <<<"${found}" || true)" = 1 ] && [ "${found%%:*}" = "$2" ]
  }
  has() { grep -qx "$1 $2" <<<"${WINDOW_OUT}"; }
  only_call open "${UPDATER}" && has OPEN "${UPDATER}" \
    || fail "${UPDATER}: the check window opens by exactly one call, RunLoop.main.perform { MainActor.assumeIsolated { AppUpdateCheckWindow.shared.open() } } right after case .openCheckWindow: (a run-loop turn, never a Task or a dispatch block; found: $(calls open | tr '\n' ' '))"
  only_call show "${UPDATER}" && has ANSWER "${UPDATER}" \
    || fail "${UPDATER}: the check's answer reaches the window by exactly one call, RunLoop.main.perform { MainActor.assumeIsolated { AppUpdateCheckWindow.shared.show(answer) } } right after case .answer (found: $(calls show | tr '\n' ' '))"
  only_call showDownload "${MENU}" \
    || fail "only the app menu's download item shows the window on a download (found: $(calls showDownload | tr '\n' ' '))"
  MODALS="$(sed -n 's/^MODAL //p' <<<"${WINDOW_OUT}")"
  [ -z "${MODALS}" ] || fail "the updater opens no modal window (runModal, NSAlert): the check window is never modal (found: $(tr '\n' ' ' <<<"${MODALS}"))"
  FORBIDDEN="$(sed -n 's/^FORBIDDEN //p' <<<"${WINDOW_OUT}")"
  [ -z "${FORBIDDEN}" ] \
    || fail "the check window starts no task or dispatch block and never reaches a download, the network or the state machine itself (found: $(tr '\n' ' ' <<<"${FORBIDDEN}"))"
  has OPENFLOW "${WINDOW}" || fail "${WINDOW}: open() goes through the flow (apply(flow.chosen(at: Self.now))): at once, or straight on a quick answer"
  has SHOWDOWNLOAD "${WINDOW}" || fail "${WINDOW}: showDownload shows the download (apply(flow.showing(.downloading(offer)))) and starts no check"
  has CLOSE "${WINDOW}" || fail "${WINDOW}: the close button only hides the window (apply(flow.closed()), return false): a check or a download goes on"
  has CANCEL "${WINDOW}" || fail "${WINDOW}: Cancel goes through the flow and stops the check only through AppUpdater.cancelCheck()"
  has DISPLAY "${WINDOW}" || fail "${WINDOW}: the window draws AppUpdateCheckDisplay.make(window.content, state: updater.state, mode: updater.mode): the progress is the updater's own"
  has TIMER "${WINDOW}" || fail "${WINDOW}: its ticks are run-loop timers (RunLoop.main.add(timer, forMode: .common))"
  has PRESENT "${WINDOW}" || fail "${WINDOW}: present() only orders the panel in (panel.orderFront(nil)): it never takes the keyboard (review CXU1)"
  has ESCAPE "${WINDOW}" || fail "${WINDOW}: Escape is the close button in every state (func escape() { perform(.dismiss) }): it hides, never cancels (review CXU1)"
  CONTENT="${DIR}/AppUpdateCheckContent.swift"
  [ "$(sed -n "s|^BUTTONS \([0-9]*\) ${CONTENT}\$|\1|p" <<<"${WINDOW_OUT}")" = 2 ] && has TIPS "${CONTENT}" \
    || fail "${CONTENT}: every button is secondaryButton (.instantHelp(help)) or defaultButton (Return, .instantHelp(help, shortcut: .defaultAction)): instant tooltips on all of them (review CXU1)"
  has RETURN "${CONTENT}" || fail "${CONTENT}: Restart and Update is the window's filled button: Return clicks it (review CXU1)"
  has NOTESCAP "${CONTENT}" && has SCROLL "${DIR}/AppUpdatePopoverParts.swift" \
    || fail "the check window caps what's new (maxHeight: Self.notesMaxHeight) and AppUpdateNotes scrolls past it: 8 notes of 300 characters never push the buttons off screen (review CXU1)"
  has MENU "${MENU}" \
    || fail "${MENU}: the item is AppUpdateMenuEntry.make(updater.state): greyed while checking, the download's percent opening the window, the check from the menu"
  [ "$(count 'Button("Checking for Updates…") {}' "${MENU}")" = 1 ] && [ "$(count 'L10n("Downloading Update (%d%%)…")' "${MENU}")" = 1 ] \
    || fail "${MENU}: the greyed «Checking for Updates…» and «Downloading Update (%d%%)…» titles"
  has STOP "${UPDATER}" || fail "${UPDATER}: .stopCheck cancels the check's own task (checkTask) and nothing else"
  has CANCELCHECK "${UPDATER}" || fail "${UPDATER}: cancelCheck() only sends .checkCancelled"
  has JOIN "${UPDATER}" || fail "${UPDATER}: one check at a time: a check started while one runs joins it (guard !alreadyChecking)"
  has QUIET "${UPDATER}" || fail "${UPDATER}: a cancelled check's task reports nothing (guard !Task.isCancelled right after AppUpdateHTTP.check)"
else
  fail "the check-window scan itself failed (find or perl exited non-zero): a scan that doesn't run is a false green"
fi

if [ "${FAILED}" -ne 0 ]; then exit 1; fi
echo "✓ app-update-wiring: one feed address, the atomic swap only, deletes inside Updates only, wired at start / quit / menu / Settings / toolbars, the coordinator pinned, get_status read only, no admin rights, no network in the check, the check window never modal and shown from the run loop"
