#!/bin/bash
# Scan guard and self-test: checks leave no preferences in the login home's ~/Library/Preferences
# (docs/bugfixes/2026-11-19-check-defaults-leftovers.md; the rule: docs/build/build-and-packaging.md, "Installed copies on
# the developer Mac").
#  1. Swift checks never open a UserDefaults suite by name (cfprefsd keeps its plist in the real home whatever the check
#     removes): they use checks/Shared/ScratchDefaults.swift, and each one they make is removed in the same file.
#  2. Every app a check or render script stages carries a check app's bundle id, so the exit trap removes that domain
#     (scripts/test-app-cleanup.sh, scripts/test-defaults-cleanup.sh). The E2E apps run sandboxed away from the real home.
#  3. The run entry points collect those domains and remove them after one wait; check-all.sh compares the home on CI.
#  4. The removal itself, against a fake home: a check app's plist goes after the wait, the real apps' plists never.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-defaults-cleanup.sh
. scripts/test-app-cleanup.sh

failed=0
fail() {
  echo "✗ $*" >&2
  failed=1
}

# ---- 1. Named suites in Swift checks ----
HELPER=checks/Shared/ScratchDefaults.swift
[ -f "${HELPER}" ] || fail "${HELPER} is missing"
raw="$(/usr/bin/grep -rn -E 'UserDefaults(\.init)?\((suiteName:|\))|CFPreferencesSet' --include='*.swift' checks scripts \
  | /usr/bin/grep -v "^${HELPER}:" || true)"
if [ -n "${raw}" ]; then
  fail "a check opens a UserDefaults suite by name, whose plist stays in ~/Library/Preferences; use ScratchDefaults (${HELPER}):"
  printf '%s\n' "${raw}" | sed 's/^/    /' >&2
fi
made=0
while IFS= read -r hit; do
  [ -n "${hit}" ] || continue
  made=$((made + 1))
  file="${hit%%:*}"
  name="$(printf '%s\n' "${hit}" | sed -E 's/.*let ([A-Za-z0-9_]+) = ScratchDefaults\(.*/\1/')"
  if ! /usr/bin/grep -Eq "(^|[^A-Za-z0-9_])${name}\.remove\(\)" "${file}"; then
    fail "${file}: ScratchDefaults ${name} is never removed (defer { ${name}.remove() })"
  fi
done <<< "$(/usr/bin/grep -rn -E 'let [A-Za-z0-9_]+ = ScratchDefaults\(' --include='*.swift' checks scripts || true)"
[ "${made}" -gt 0 ] || fail "no check makes a ScratchDefaults: the scan above found nothing to check"

# ---- 2. Bundle ids of the apps check and render scripts stage ----
staged=0
for script in scripts/check-*.sh scripts/render-*.sh; do
  /usr/bin/grep -q 'CFBundleIdentifier' "${script}" || continue
  case "${script}" in
    scripts/check-e2e.sh|scripts/check-e2e-gui.sh) continue ;; # Sandboxed: launch.py keeps them out of the real home.
  esac
  ids="$(sed -n -E \
    -e 's/.*<key>CFBundleIdentifier<\/key><string>([^<]+)<\/string>.*/\1/p' \
    -e 's/.*Set :CFBundleIdentifier ([^" ]+).*/\1/p' "${script}")"
  [ -n "${ids}" ] || fail "${script}: stages an app whose bundle id this scan cannot read"
  for id in ${ids}; do
    staged=$((staged + 1))
    if [ "${id}" = '${BUNDLE_ID}' ]; then
      id="$(sed -n -E 's/^BUNDLE_ID="([^"]+)".*/\1/p' "${script}" | head -n 1)"
    fi
    id="${id//\$\$/4242}"
    if ! test_defaults_domain_ok "${id}"; then
      fail "${script}: the staged app's bundle id ${id:-?} is not com.srtflow.SrtFlow.<name>check / <name>render[.run<pid>], so its preferences would stay in the real home"
    fi
  done
done
[ "${staged}" -gt 0 ] || fail "no staged check app found: the bundle id scan is broken"

# ---- 3. The run entry points ----
for entry in scripts/check-all.sh scripts/check-local.sh; do
  for call in '^\. scripts/test-defaults-cleanup\.sh' '^test_defaults_collect$' 'test_defaults_remove_collected'; do
    /usr/bin/grep -Eq "${call}" "${entry}" || fail "${entry} does not collect and remove staged check apps' preferences (${call})"
  done
done
/usr/bin/grep -Eq 'test_defaults_left_since' scripts/check-all.sh \
  || fail "scripts/check-all.sh no longer compares the login home's preferences before and after the run on CI"

# ---- 4. The removal against a fake home ----
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
export TEST_DEFAULTS_HOME="${scratch}/home"
prefs="${TEST_DEFAULTS_HOME}/Library/Preferences"
mkdir -p "${prefs}"
slept=""
sleep() { slept="$1"; } # Records the wait instead of taking it.
unregister_test_app() { :; }
unset SRTFLOW_TEST_DEFAULTS_LIST
settle_default="$(/bin/bash -c 'unset TEST_DEFAULTS_SETTLE; . scripts/test-defaults-cleanup.sh; printf %s "${TEST_DEFAULTS_SETTLE}"')"
[ "${settle_default}" -ge 12 ] || fail "the wait (${settle_default} s) must outlast cfprefsd's delayed write, measured at up to 10 s"
TEST_DEFAULTS_SETTLE=15

for id in com.srtflow.SrtFlow.parameterlimitscheck com.srtflow.SrtFlow.lookjobscheck.run4242 com.srtflow.SrtFlow.voicelibraryrender; do
  test_defaults_domain_ok "${id}" || fail "a check app's bundle id is not recognized: ${id}"
done
for id in com.srtflow.SrtFlow com.srtflow.SrtFlow.beta com.srtflow.SrtFlowDev com.srtflow.SrtFlow.skystudiosmoke \
  com.srtflow.e2e4242.skystudiosmoke com.srtflow.SrtFlow.x.check/../../y "" ; do
  if test_defaults_domain_ok "${id}"; then fail "taken for a check app's bundle id: '${id}'"; fi
done

for name in com.srtflow.SrtFlow com.srtflow.SrtFlow.beta com.srtflow.SrtFlow.alonecheck.run4242 com.srtflow.SrtFlow.listedrender \
  com.srtflow.SrtFlow.stagedcheck; do
  : > "${prefs}/${name}.plist"
done
# On its own: waits, then deletes.
remove_test_defaults com.srtflow.SrtFlow.alonecheck.run4242
[ ! -e "${prefs}/com.srtflow.SrtFlow.alonecheck.run4242.plist" ] && [ "${slept}" = 15 ] \
  || fail "a check script run on its own does not wait for cfprefsd and delete its app's plist (slept '${slept}')"
if remove_test_defaults com.srtflow.SrtFlow 2>/dev/null; then fail "the real app's domain was accepted for removal"; fi
[ -e "${prefs}/com.srtflow.SrtFlow.plist" ] || fail "the real app's plist was deleted"
# Under an entry point: collected, then deleted after one wait.
slept=""
test_defaults_collect
list="${SRTFLOW_TEST_DEFAULTS_LIST}"
remove_test_defaults com.srtflow.SrtFlow.listedrender
[ -e "${prefs}/com.srtflow.SrtFlow.listedrender.plist" ] && [ -z "${slept}" ] \
  || fail "a check script under an entry point does not leave the wait and deletion to the end of the run"
test_defaults_remove_collected
[ ! -e "${prefs}/com.srtflow.SrtFlow.listedrender.plist" ] && [ -n "${slept}" ] && [ ! -e "${list}" ] \
  && [ -z "${SRTFLOW_TEST_DEFAULTS_LIST:-}" ] || fail "the end of the run does not wait, delete the collected plists and its list"
# Through the staged app's exit trap: the check app's domain goes, the real app's stays.
for pair in "check:com.srtflow.SrtFlow.stagedcheck" "real:com.srtflow.SrtFlow.beta"; do
  bundle="${scratch}/${pair%%:*}/Fixture.app"
  mkdir -p "${bundle}/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${pair#*:}" "${bundle}/Contents/Info.plist" >/dev/null
  remove_test_app "${bundle}"
  [ ! -e "${bundle}" ] || fail "remove_test_app left ${bundle}"
done
[ ! -e "${prefs}/com.srtflow.SrtFlow.stagedcheck.plist" ] || fail "removing a staged check app leaves its preferences"
[ -e "${prefs}/com.srtflow.SrtFlow.beta.plist" ] || fail "removing a staged app with the beta's bundle id deleted the beta's preferences"
# The CI comparison: only new names with srtflow, skycut or check, outside com.apple.
before="$(test_defaults_snapshot)"
: > "${prefs}/keychain-notice-checks-0001.plist"
: > "${prefs}/com.apple.check.plist"
: > "${prefs}/unrelated.plist"
left="$(test_defaults_left_since "${before}")"
[ "${left}" = "keychain-notice-checks-0001.plist" ] || fail "the before / after comparison reports '${left}'"

[ "${failed}" -eq 0 ] || exit 1
echo "✓ test-defaults-cleanup: ${made} scratch suites removed in their files, ${staged} staged check apps with check ids, entry points wired, removal verified on a fake home."
