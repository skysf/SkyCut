# Section 8 of checks/release-signing.sh (sourced; uses its `fail`): scripts/signing/sign-app.sh really signs a fixture
# app, ad-hoc. A stub `security` lists no identity, so the run is the same on CI and on the Mac that has the Developer
# ID, and nothing touches a keychain or the network. Copies of /usr/bin/true stand in for the app and its three helpers;
# the fixture is never launched (so it writes no preferences) and is unregistered and removed on exit.
. scripts/test-app-cleanup.sh

FIXTURE_ROOT="$(mktemp -d)"
FIXTURE_APP="${FIXTURE_ROOT}/SkyCut.app"
test_app_cleanup_on_exit "${FIXTURE_APP}" "${FIXTURE_ROOT}"
mkdir -p "${FIXTURE_APP}/Contents/MacOS" "${FIXTURE_APP}/Contents/Helpers" "${FIXTURE_APP}/Contents/Resources" \
  "${FIXTURE_ROOT}/bin"
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
printf '#!/bin/sh\necho "     0 valid identities found"\n' > "${FIXTURE_ROOT}/bin/security"
chmod +x "${FIXTURE_ROOT}/bin/security"
sign_fixture() {
  PATH="${FIXTURE_ROOT}/bin:${PATH}" /bin/bash scripts/signing/sign-app.sh "${FIXTURE_APP}" 2>&1
}

if ! FIXTURE_OUTPUT="$(sign_fixture)"; then
  fail "sign-app.sh could not sign the fixture app ad-hoc:
${FIXTURE_OUTPUT}"
elif ! grep -qF 'No Developer ID on this Mac: signing ad-hoc' <<<"${FIXTURE_OUTPUT}"; then
  fail "sign-app.sh signed without saying the build is ad-hoc (never handed to a user):
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
