#!/bin/bash
# Unregister and remove only the scratch bundle the calling harness assembled, and a staged check app's preferences.
. "$(dirname "${BASH_SOURCE[0]}")/test-defaults-cleanup.sh"

unregister_test_app() {
  local register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  # A partial build or directly launched executable may never have been registered.
  "${register}" -u "$1" >/dev/null 2>&1 || true
}

remove_test_app() {
  local bundle="$1" domain=""
  if [ -d "${bundle}" ]; then
    domain="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${bundle}/Contents/Info.plist" 2>/dev/null || true)"
    unregister_test_app "${bundle}"
    rm -rf -- "${bundle}"
  fi
  # A check or render app's own UserDefaults domain (its bundle id); real, dev and smoke identities are left alone.
  if test_defaults_domain_ok "${domain}"; then
    remove_test_defaults "${domain}"
  fi
}

test_app_exit_signals() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

test_app_cleanup_on_exit() {
  local cleanup
  printf -v cleanup 'remove_test_app %q && rm -rf -- %q' "$1" "$2"
  trap "${cleanup}" EXIT
  test_app_exit_signals
}
