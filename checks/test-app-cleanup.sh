#!/bin/bash
# Find check and smoke scripts that stage bundles and verify that failure still unregisters and removes them.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh

failed=0
count=0
while IFS= read -r script; do
  case "${script}" in
    scripts/build-app.sh|scripts/build-beta-app.sh|scripts/build-dmg.sh) continue ;; # Release artifacts.
  esac
  /usr/bin/grep -Eq '^[[:space:]]*mkdir[[:space:]].*/Contents(/|")' "${script}" || continue
  count=$((count + 1))
  if /usr/bin/grep -Eq '^[[:space:]]*(source|\.) .*test-app-cleanup\.sh' "${script}" &&
     { /usr/bin/grep -Eq '^[[:space:]]*test_app_cleanup_on_exit ' "${script}" ||
       { /usr/bin/grep -Eq '^[[:space:]]*trap .* EXIT' "${script}" &&
         /usr/bin/grep -Eq '^[[:space:]]*remove_test_app ' "${script}"; }; }; then
    continue
  fi
  echo "✗ ${script} stages a test app without an unregister-and-remove exit trap" >&2
  failed=1
done < <(find scripts checks -name '*.sh' -type f | sort)
if [ "${count}" -eq 0 ] || ! /usr/bin/grep -Fq '"${register}" -u "$1"' scripts/test-app-cleanup.sh; then
  echo '✗ Test app inventory is empty or the cleanup does not call lsregister -u' >&2
  failed=1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
for expected in 0 37; do
  stage="${scratch}/case ${expected}"
  bundle="${stage}/Fixture.app"
  status=0
  (
    unregister_test_app() {
      [ -d "$1" ] && printf '%s\n' "$1" > "${scratch}/unregistered-${expected}"
    }
    test_app_cleanup_on_exit "${bundle}" "${stage}"
    mkdir -p "${bundle}"
    exit "${expected}"
  ) || status=$?
  if [ "${status}" -ne "${expected}" ] || [ -e "${stage}" ] ||
     [ "$(cat "${scratch}/unregistered-${expected}" 2>/dev/null || true)" != "${bundle}" ]; then
    echo "✗ Test app trap failed to unregister before removal or changed exit ${expected}" >&2
    failed=1
  fi
done

# The synthetic App can be removed even if detaching its read-only DMG fails.
stage="${scratch}/dmg"
mkdir -p "${stage}/fixture/SkyCut.app"
status=0
/bin/bash -e -c '
  . scripts/test-app-cleanup.sh
  WORK="$1"
  FIXTURE_APP="${WORK}/fixture/SkyCut.app"
  MOUNT="${WORK}/mount"
  MOUNTED=1
  unregister_test_app() { :; }
  hdiutil() { return 37; }
  eval "$2"
  cleanup
' -- "${stage}" "$(sed -n '/^cleanup() {$/,/^}$/p' scripts/check-dmg.sh)" || status=$?
if [ "${status}" -ne 37 ] || [ -e "${stage}/fixture/SkyCut.app" ]; then
  echo '✗ The DMG test left its fixture app when detach failed' >&2
  failed=1
fi

[ "${failed}" -eq 0 ] || exit 1
echo "✓ ${count} test app staging scripts use cleanup. The trap preserves both success and failure."
