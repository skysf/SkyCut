# Section 8 of checks/release-signing.sh (sourced; uses its `fail` and section 3's listings): the real signing scripts,
# run with stub tools first on PATH, so the run is the same on CI and on the Mac with the Developer ID and nothing
# touches a keychain, the network or Apple. Stubs: `security` answers a listing and a status from files; `xcrun` fails
# like a missing notary profile; `codesign` (only for signing_check_identity) reports our team and hands out a fake leaf
# certificate. Copies of /usr/bin/true stand in for the app and its three helpers; the fixture app is never launched (so
# it writes no preferences) and is unregistered and removed on exit.
#
# Refusals (FBS1 review, 2026-11-26): signing_mode stops on a failing `security`, an expired pin and a Mac with no
# Developer ID unless SKYCUT_ALLOW_ADHOC=1; sign-app.sh, sign-dmg.sh and `notarize.sh --check` keep those refusals (status
# and reason), `--check` also stops on an unusable notary profile, and signing_check_identity refuses another leaf
# certificate. Then sign-app.sh signs the fixture ad-hoc with the opt-out and refuses stray code in the bundle.
. scripts/test-app-cleanup.sh

FIXTURE_ROOT="$(mktemp -d)"
FIXTURE_APP="${FIXTURE_ROOT}/SkyCut.app"
STUBS="${FIXTURE_ROOT}/stubs"
test_app_cleanup_on_exit "${FIXTURE_APP}" "${FIXTURE_ROOT}"
mkdir -p "${FIXTURE_APP}/Contents/MacOS" "${FIXTURE_APP}/Contents/Helpers" "${FIXTURE_APP}/Contents/Resources" \
  "${STUBS}/bin" "${STUBS}/codesign" "${STUBS}/listing" "${STUBS}/pin/packaging"
for piece in MacOS/SkyCut Helpers/ffmpeg Helpers/skycut-mcp Helpers/skycut-web-motion; do
  cp /usr/bin/true "${FIXTURE_APP}/Contents/${piece}"
done
cat > "${FIXTURE_APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>SkyCut</string>
	<key>CFBundleIdentifier</key>
	<string>com.srtflow.signing-fixture</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
</dict>
</plist>
PLIST
cat > "${STUBS}/bin/security" <<'SH'
#!/bin/sh
case " $* " in *" -v "*) cat "${STUB_LISTING}/valid" ;; *) cat "${STUB_LISTING}/all" ;; esac
exit "$(cat "${STUB_LISTING}/status")"
SH
printf '#!/bin/sh\necho "Error: No Keychain password item found for profile: stub" >&2\nexit 1\n' > "${STUBS}/bin/xcrun"
cat > "${STUBS}/codesign/codesign" <<'SH'
#!/bin/sh
for argument in "$@"; do
  case "${argument}" in
    -dvvv) printf 'TeamIdentifier=26TVX3S9FR\nTimestamp=Nov 26, 2026 at 01:00:00\n' ;;
    --extract-certificates=*) printf 'stub leaf certificate\n' > "${argument#--extract-certificates=}0" ;;
  esac
done
SH
chmod +x "${STUBS}/bin/security" "${STUBS}/bin/xcrun" "${STUBS}/codesign/codesign"
: > "${FIXTURE_ROOT}/SkyCut-0.0.0-arm64.dmg"

# stub_listing <valid listing> <all listing> <security's exit status>
stub_listing() {
  printf '%s\n' "$1" > "${STUBS}/listing/valid"
  printf '%s\n' "$2" > "${STUBS}/listing/all"
  printf '%s\n' "$3" > "${STUBS}/listing/status"
}
# with_stubs <command…>: runs it without the opt-out, the stubs first on PATH; prints its output, keeps its status.
with_stubs() {
  env -u SKYCUT_ALLOW_ADHOC PATH="${STUBS}/bin:${PATH}" STUB_LISTING="${STUBS}/listing" "$@" 2>&1
}
# expect_refusal <what> <words the refusal must say> <command…>
expect_refusal() {
  local what="$1" words="$2" output status=0
  shift 2
  output="$(with_stubs "$@")" || status=$?
  if [ "${status}" -eq 0 ]; then
    fail "${what} must refuse, but went on: ${output}"
  elif ! grep -qF "${words}" <<<"${output}"; then
    fail "${what} refused without saying \"${words}\": ${output}"
  fi
}
MODE_OF='. scripts/signing/common.sh && signing_mode'

stub_listing "${PINNED_VALID}" "${PINNED_VALID}" 0
FIXTURE_OUTPUT="$(with_stubs /bin/bash -c "${MODE_OF}")" || true
if [ "${FIXTURE_OUTPUT}" != developer-id ]; then
  fail "signing_mode must answer developer-id when the pinned Developer ID is valid, got: ${FIXTURE_OUTPUT}"
fi
expect_refusal "notarize.sh --check with an unusable notary profile" "store-credentials" /bin/bash scripts/signing/notarize.sh --check

stub_listing "${NONE}" "${PINNED_EXPIRED}" 0
expect_refusal "signing_mode with an expired pin" "Renew it" /bin/bash -c "${MODE_OF}"
expect_refusal "sign-app.sh with an expired pin" "Renew it" /bin/bash scripts/signing/sign-app.sh "${FIXTURE_APP}"
expect_refusal "sign-dmg.sh with an expired pin" "Renew it" /bin/bash scripts/signing/sign-dmg.sh "${FIXTURE_ROOT}/SkyCut-0.0.0-arm64.dmg"
expect_refusal "notarize.sh --check with an expired pin" "Renew it" /bin/bash scripts/signing/notarize.sh --check

stub_listing "" "" 1
expect_refusal "signing_mode when security fails" "cannot list" /bin/bash -c "${MODE_OF}"

stub_listing "${NONE}" "${NONE}" 0
expect_refusal "signing_mode with no Developer ID" "SKYCUT_ALLOW_ADHOC=1" /bin/bash -c "${MODE_OF}"
expect_refusal "sign-app.sh with no Developer ID" "SKYCUT_ALLOW_ADHOC=1" /bin/bash scripts/signing/sign-app.sh "${FIXTURE_APP}"
expect_refusal "notarize.sh --check with no Developer ID" "SKYCUT_ALLOW_ADHOC=1" /bin/bash scripts/signing/notarize.sh --check
FIXTURE_OUTPUT="$(with_stubs env SKYCUT_ALLOW_ADHOC=1 /bin/bash -c "${MODE_OF}")" || true
if [ "${FIXTURE_OUTPUT}" != ad-hoc ]; then
  fail "signing_mode must answer ad-hoc with SKYCUT_ALLOW_ADHOC=1 and no Developer ID, got: ${FIXTURE_OUTPUT}"
fi

# signing_check_identity against the stub codesign's leaf: refused against the real pin, accepted against its own SHA-1.
CHECK_IDENTITY=". '${PWD}/scripts/signing/common.sh' && signing_check_identity '${FIXTURE_APP}'"
printf 'stub leaf certificate\n' | shasum -a 1 | awk '{ print $1 }' > "${STUBS}/pin/packaging/signing-identity.sha1"
FIXTURE_STATUS=0
FIXTURE_OUTPUT="$(PATH="${STUBS}/codesign:${PATH}" /bin/bash -c "${CHECK_IDENTITY}" 2>&1)" || FIXTURE_STATUS=$?
if [ "${FIXTURE_STATUS}" -eq 0 ] || ! grep -qF "not the pinned" <<<"${FIXTURE_OUTPUT}"; then
  fail "signing_check_identity must refuse a leaf certificate that is not the pinned one: ${FIXTURE_OUTPUT}"
fi
if ! FIXTURE_OUTPUT="$(cd "${STUBS}/pin" && PATH="${STUBS}/codesign:${PATH}" /bin/bash -c "${CHECK_IDENTITY}" 2>&1)"; then
  fail "signing_check_identity must accept the pinned leaf certificate with our team and a timestamp: ${FIXTURE_OUTPUT}"
fi

# The ad-hoc path, only with the opt-out: the runtime on all four pieces, entitlements only on the app.
stub_listing "${NONE}" "${NONE}" 0
sign_fixture() {
  with_stubs env SKYCUT_ALLOW_ADHOC=1 /bin/bash scripts/signing/sign-app.sh "${FIXTURE_APP}"
}
if ! FIXTURE_OUTPUT="$(sign_fixture)"; then
  fail "sign-app.sh could not sign the fixture app ad-hoc with SKYCUT_ALLOW_ADHOC=1:
${FIXTURE_OUTPUT}"
elif ! grep -qF 'SKYCUT_ALLOW_ADHOC=1: signing ad-hoc' <<<"${FIXTURE_OUTPUT}"; then
  fail "sign-app.sh signed without saying the build is ad-hoc (never handed to anyone):
${FIXTURE_OUTPUT}"
else
  for piece in Helpers/ffmpeg Helpers/skycut-mcp Helpers/skycut-web-motion MacOS/SkyCut; do
    CODE="${FIXTURE_APP}/Contents/${piece}"
    if [ "${piece}" = MacOS/SkyCut ]; then
      CODE="${FIXTURE_APP}"
    fi
    if ! grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$(codesign -dvvv "${CODE}" 2>&1 || true)"; then
      fail "sign-app.sh left ${piece} without the hardened runtime"
    fi
    FIXTURE_ENTITLEMENTS="$(codesign -d --entitlements - --xml "${CODE}" 2>/dev/null || true)"
    if [ "${CODE}" = "${FIXTURE_APP}" ]; then
      for key in com.apple.security.device.audio-input com.apple.security.automation.apple-events; do
        grep -qF "<key>${key}</key>" <<<"${FIXTURE_ENTITLEMENTS}" || fail "sign-app.sh did not give the app ${key}"
      done
    elif grep -qF '<key>' <<<"${FIXTURE_ENTITLEMENTS}"; then
      fail "sign-app.sh gave ${piece} entitlements (the helpers need none)"
    fi
  done
  if ! grep -qF 'cdhash H"' <<<"$(codesign -d -r- "${FIXTURE_APP}" 2>&1 || true)"; then
    fail "the ad-hoc fixture's designated requirement is not its cdhash: did sign-app.sh pick an identity?"
  fi
fi

cp /usr/bin/true "${FIXTURE_APP}/Contents/Resources/stray"
if FIXTURE_OUTPUT="$(sign_fixture)"; then
  fail "sign-app.sh signed an app with code it does not name (Contents/Resources/stray would ship unsigned)"
elif ! grep -qF 'Code in the bundle that sign-app.sh does not sign' <<<"${FIXTURE_OUTPUT}"; then
  fail "sign-app.sh refused the app with stray code for another reason:
${FIXTURE_OUTPUT}"
fi
