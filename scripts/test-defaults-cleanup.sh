#!/bin/bash
# Remove the preferences a staged check app leaves in the login home: its UserDefaults domain is its bundle id, written by
# cfprefsd as ~/Library/Preferences/<bundle id>.plist. Swift checks' own suites never get there: checks/Shared/ScratchDefaults.swift.
#
# cfprefsd writes a domain's last change up to about 10 s after the app exits, and writes a plist deleted before then
# again (docs/bugfixes/2026-11-19-check-defaults-leftovers.md). So the plist is deleted only once the app has been gone
# for TEST_DEFAULTS_SETTLE seconds. scripts/test-app-cleanup.sh calls this for every staged bundle with a check app's id.
# The run entry points (check-all.sh, check-local.sh) collect the domains and wait once at their end; a check script run
# on its own waits in its exit trap.

TEST_DEFAULTS_SETTLE="${TEST_DEFAULTS_SETTLE:-15}"

# A staged check or render app's bundle id: com.srtflow.SrtFlow.<name>check or <name>render, maybe with .run<pid>.
# Never the real apps (com.srtflow.SrtFlow, com.srtflow.SrtFlow.beta) or a dev or smoke identity.
test_defaults_domain_ok() {
  local pattern='^com\.srtflow\.SrtFlow\.[a-z]+(check|render)(\.run[0-9]+)?$' # a variable: /bin/bash 3.2 misreads it inline
  [[ "$1" =~ ${pattern} ]]
}

test_defaults_plist() {
  printf '%s/Library/Preferences/%s.plist' "${TEST_DEFAULTS_HOME:-${HOME:?}}" "$1"
}

# Deletes the plists now: only for domains whose app has been gone for TEST_DEFAULTS_SETTLE seconds.
delete_test_defaults_now() {
  local domain
  for domain in "$@"; do
    rm -f -- "$(test_defaults_plist "${domain}")"
  done
}

remove_test_defaults() {
  local domain
  for domain in "$@"; do
    if ! test_defaults_domain_ok "${domain}"; then
      echo "✗ Not a staged check app's defaults domain, left alone: ${domain}" >&2
      return 1
    fi
  done
  if [ -n "${SRTFLOW_TEST_DEFAULTS_LIST:-}" ]; then
    printf '%s\n' "$@" >> "${SRTFLOW_TEST_DEFAULTS_LIST}"
    return 0
  fi
  sleep "${TEST_DEFAULTS_SETTLE}"
  delete_test_defaults_now "$@"
}

# For an entry point: from here on, check scripts hand their domains to test_defaults_remove_collected.
test_defaults_collect() {
  SRTFLOW_TEST_DEFAULTS_LIST="$(mktemp "${TMPDIR:-/tmp}/skycut-test-defaults.XXXXXX")"
  export SRTFLOW_TEST_DEFAULTS_LIST
}

# Waits until the last collected app has been gone for TEST_DEFAULTS_SETTLE seconds, then deletes them all.
test_defaults_remove_collected() {
  local list="${SRTFLOW_TEST_DEFAULTS_LIST:-}" age domains
  [ -n "${list}" ] || return 0
  unset SRTFLOW_TEST_DEFAULTS_LIST
  if [ -s "${list}" ]; then
    age=$(( $(date +%s) - $(stat -f %m "${list}") ))
    if [ "${age}" -lt "${TEST_DEFAULTS_SETTLE}" ]; then
      echo "Removing the staged check apps' preferences once cfprefsd has written them ($(( TEST_DEFAULTS_SETTLE - age )) s)"
      sleep $(( TEST_DEFAULTS_SETTLE - age ))
    fi
    domains="$(LC_ALL=C sort -u "${list}")"
    # shellcheck disable=SC2086 # one bundle id per word
    delete_test_defaults_now ${domains}
  fi
  rm -f -- "${list}"
}

# Preferences a check may have left in the login home: names with srtflow, skycut or check, outside com.apple.
# check-all.sh compares the list before and after the run on CI, whose runner starts with none of them.
test_defaults_snapshot() {
  local folder="${TEST_DEFAULTS_HOME:-${HOME:?}}/Library/Preferences"
  [ -d "${folder}" ] || return 0
  find "${folder}" -maxdepth 1 -name '*.plist' -type f -print | sed 's#.*/##' \
    | { /usr/bin/grep -i -E 'srtflow|skycut|check' || true; } | { /usr/bin/grep -v '^com\.apple\.' || true; } | LC_ALL=C sort
}

# The snapshot's names that the given earlier snapshot did not have, one per line.
test_defaults_left_since() {
  local before="$1" name
  test_defaults_snapshot | while IFS= read -r name; do
    if ! /usr/bin/grep -Fxq -- "${name}" <<< "${before}"; then printf '%s\n' "${name}"; fi
  done
}
