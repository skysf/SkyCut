#!/usr/bin/env bash
# User and release builds are signed with the pinned Developer ID, with the hardened runtime, and notarized; the app
# deletes a screen recording record that still names an older signature, so the system asks again.
#
# Why: macOS keys privacy grants to the signature's designated requirement. An ad-hoc requirement is the cdhash, so every
# ad-hoc build is "another app", and a screen recording record pinned to an old build cannot be revived from System
# Settings (docs/bugfixes/2026-10-03-screen-recording-permission-stale-after-update.md). A Developer ID requirement names
# the team, so grants survive new builds and certificate renewals, and a notarized download opens directly
# (docs/architecture/code-signing-and-permissions.md).
#
# Pins:
#   1. the build scripts never sign or notarize themselves: scripts/signing/ in order (the notary profile checked before
#      the compile; the app signed, notarized; the DMG built, signed, notarized; the Beta signed, notarized);
#   2. sign-app.sh: one signing command with the hardened runtime, inside out; entitlements only on the app; the Developer
#      ID branch timestamps and checks team, certificate, timestamp, runtime and the team requirement; ad-hoc only when
#      signing_mode finds no Developer ID of our team; sign-dmg.sh timestamps and checks the DMG the same way;
#   3. the pin: one SHA-1, the team, the shared notary profile; signing_mode_from (fed listings) picks only the pinned
#      identity, refuses an expired pin or another certificate of our team, and falls back to ad-hoc otherwise;
#   4. the entitlements: only resource-access keys a usage description in Info.plist needs, every such usage description
#      has its key, no hardened-runtime exception (they need proof that a real feature fails without them);
#   5. notarize.sh: credentials only through the keychain profile; it waits, staples, validates and requires Gatekeeper's
#      "Notarized Developer ID";
#   6. recording a custom region deletes the stale record before asking; tccutil is called in one place;
#   7. no "turn it off and on again" advice;
#   8. sign-app.sh really signs (ad-hoc on a fixture app, `security` reporting no identity): the runtime on all four
#      pieces, entitlements only on the app; stray code in the bundle is refused.
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}
count() { { grep -cE -- "$1" "$2" || true; }; }
countF() { { grep -cF -- "$1" "$2" || true; }; }
first_line() { { grep -nE "$1" "$2" || true; } | awk -F: 'NR == 1 { print $1 }'; }
lineF() { { grep -nF -- "$1" "$2" || true; } | awk -F: 'NR == 1 { print $1 }'; }
# The lines named by the arguments after the file exist once each, in this order.
in_order() {
  local file="$1" previous=0 line text
  shift
  for text in "$@"; do
    line="$(lineF "${text}" "${file}")"
    if [ -z "${line}" ] || [ "$(countF "${text}" "${file}")" -ne 1 ]; then
      fail "${file}: needs exactly one line with: ${text}"
      return
    fi
    if [ "${line}" -le "${previous}" ]; then
      fail "${file}: \"${text}\" (line ${line}) must come after line ${previous}"
    fi
    previous="${line}"
  done
}
SIGN="scripts/signing/sign-app.sh"
SIGN_DMG="scripts/signing/sign-dmg.sh"
NOTARIZE="scripts/signing/notarize.sh"
COMMON="scripts/signing/common.sh"

echo "==> 1. The build scripts sign and notarize only through scripts/signing/, in order"
for script in scripts/build-app.sh scripts/build-beta-app.sh scripts/build-dmg.sh; do
  if [ "$(count '^[[:space:]]*(codesign|xcrun|notarytool|stapler|spctl)[[:space:]]' "${script}")" -ne 0 ]; then
    fail "${script} signs, notarizes or assesses by itself: only scripts/signing/ may (sign-app.sh, sign-dmg.sh, notarize.sh)"
  fi
done
in_order scripts/build-app.sh 'scripts/signing/notarize.sh --check' 'echo "==> swift build -c release (arm64, -O)"' \
  'scripts/signing/sign-app.sh "$APP"' 'scripts/signing/notarize.sh "$APP"' '/bin/bash scripts/build-dmg.sh "$APP" "$DMG"' \
  'scripts/signing/sign-dmg.sh "$DMG"' 'scripts/signing/notarize.sh "$DMG"'
in_order scripts/build-beta-app.sh 'scripts/signing/notarize.sh --check' 'ditto "${SRC}" "${BETA}"' \
  'scripts/signing/sign-app.sh "${BETA}"' 'scripts/signing/notarize.sh "${BETA}"'

echo "==> 2. sign-app.sh: hardened runtime, inside out, entitlements on the app, the identity checked"
if [ "$(count 'codesign --force' "${SIGN}")" -ne 1 ] \
  || [ "$(countF 'codesign --force --options runtime "${IDENTITY[@]}" "$@"' "${SIGN}")" -ne 1 ]; then
  fail "${SIGN} must sign through one command, codesign --force --options runtime \"\${IDENTITY[@]}\" (no --deep)"
fi
in_order "${SIGN}" 'MODE="$(signing_mode)"' 'IDENTITY=(--sign "$(signing_pinned_sha1)" --timestamp)' \
  'IDENTITY=(--sign - --timestamp=none)' 'sign_code "${APP}/Contents/Helpers/ffmpeg"' \
  'sign_code "${APP}/Contents/Helpers/skycut-mcp"' 'sign_code "${APP}/Contents/Helpers/skycut-web-motion"' \
  'sign_code --entitlements "${SIGNING_ENTITLEMENTS}" "${APP}"' 'signing_check_identity "${code}"'
BRANCH_LINE="$(first_line '^if \[ "\$\{MODE\}" = developer-id \]; then$' "${SIGN}")"
ELSE_LINE="$(first_line '^else$' "${SIGN}")"
DEVELOPER_LINE="$(lineF 'IDENTITY=(--sign "$(signing_pinned_sha1)" --timestamp)' "${SIGN}")"
ADHOC_LINE="$(lineF 'IDENTITY=(--sign - --timestamp=none)' "${SIGN}")"
if [ -z "${BRANCH_LINE}" ] || [ -z "${ELSE_LINE}" ] || [ -z "${DEVELOPER_LINE}" ] || [ -z "${ADHOC_LINE}" ] \
  || [ "${DEVELOPER_LINE}" -lt "${BRANCH_LINE}" ] || [ "${DEVELOPER_LINE}" -gt "${ELSE_LINE}" ] \
  || [ "${ADHOC_LINE}" -lt "${ELSE_LINE}" ]; then
  fail "${SIGN}: the timestamped Developer ID signs when signing_mode says developer-id; ad-hoc only in the other branch"
fi
if [ "$(count '^sign_code .*--entitlements' "${SIGN}")" -ne 1 ]; then
  fail "${SIGN}: entitlements only on the outer app (the helpers need none under the hardened runtime)"
fi
for text in 'flags=0x[0-9a-f]+\([^)]*runtime' 'certificate leaf\[subject\.OU\]' 'Code in the bundle that sign-app.sh does not sign' \
  'rm -f "${APP}/Contents/CodeResources"'; do
  if [ "$(countF "${text}" "${SIGN}")" -lt 1 ]; then
    fail "${SIGN} no longer checks or does: ${text}"
  fi
done
for text in 'TeamIdentifier=${SIGNING_TEAM_ID}' "'^Timestamp='" '--extract-certificates='; do
  if [ "$(countF "${text}" "${COMMON}")" -ne 1 ]; then
    fail "${COMMON}: signing_check_identity must check ${text}"
  fi
done
in_order "${SIGN_DMG}" 'if [ "$(signing_mode)" != developer-id ]; then' \
  'codesign --force --sign "$(signing_pinned_sha1)" --timestamp "${DMG}"' 'signing_check_identity "${DMG}"'

echo "==> 3. The pin and the identity decision"
PINNED="$({ grep -v '^#' packaging/signing-identity.sha1 || true; } | { grep -v '^[[:space:]]*$' || true; })"
if [ "$(grep -cxE '[0-9a-f]{40}' <<<"${PINNED}" || true)" -ne 1 ] || [ "$(wc -l <<<"${PINNED}" | tr -d ' ')" -ne 1 ]; then
  fail "packaging/signing-identity.sha1 must hold one lowercase 40-digit SHA-1 (besides comments), not: ${PINNED:-(nothing)}"
fi
for text in 'SIGNING_TEAM_ID="26TVX3S9FR"' 'NOTARY_PROFILE="${SKYCUT_NOTARY_PROFILE:-notary-${SIGNING_TEAM_ID}}"' \
  'SIGNING_ENTITLEMENTS="packaging/SkyCut.entitlements"'; do
  if [ "$(countF "${text}" "${COMMON}")" -ne 1 ]; then
    fail "${COMMON} must say ${text}"
  fi
done
. checks/release-signing/decision.sh

echo "==> 4. Entitlements: only what a usage description needs, no exceptions"
. checks/release-signing/entitlements.sh

echo "==> 5. notarize.sh: the keychain profile only; waits, staples, validates, Gatekeeper accepts"
if [ "$(count '^[[:space:]]*notary_profile_ready$' "${NOTARIZE}")" -ne 2 ]; then
  fail "${NOTARIZE} must check the notary profile both for --check and before submitting"
fi
in_order "${NOTARIZE}" 'signing_check_identity "${TARGET}"' \
  'xcrun notarytool submit "${PAYLOAD}" --keychain-profile "${NOTARY_PROFILE}" --wait --timeout 1h \' \
  'if [ "${STATUS}" != Accepted ]; then' 'xcrun stapler staple "${TARGET}"' 'xcrun stapler validate "${TARGET}"' \
  "if ! grep -qxF 'source=Notarized Developer ID' <<<\"\${ASSESSMENT}\"; then"
CALLS="$({ grep -hE 'notarytool (submit|log|history|store-credentials)' scripts/signing/*.sh scripts/build-*.sh || true; } \
  | { grep -vE '^[[:space:]]*(#|echo )' || true; })"
WITHOUT_PROFILE="$(grep -cvF -- '--keychain-profile "${NOTARY_PROFILE}"' <<<"${CALLS}" || true)"
CREDENTIALS="$(grep -cE -- 'store-credentials|--password|--apple-id|--key |--issuer|--team-id' <<<"${CALLS}" || true)"
if [ -z "${CALLS}" ] || [ "${WITHOUT_PROFILE}" -ne 0 ] || [ "${CREDENTIALS}" -ne 0 ]; then
  fail "notarytool may only be given the keychain profile, never a password, key or Apple ID: ${CALLS:-(no calls found)}"
fi

echo "==> 6. 录自定义区域：先删旧记录再请求，tccutil 只在一处"
PERMS="Sources/SrtFlow/ScreenRecordingPermissions.swift"
REPAIR_CALL="$(first_line '^        await ScreenCapturePermissionRepair\.resetRecordOncePerBuild\(\)$' "${PERMS}")"
REQUEST_CALL="$(first_line '^        _ = CGRequestScreenCaptureAccess\(\)$' "${PERMS}")"
if [ -z "${REPAIR_CALL}" ] || [ -z "${REQUEST_CALL}" ] || [ "${REPAIR_CALL}" -gt "${REQUEST_CALL}" ]; then
  fail "${PERMS} 请求录屏授权之前没先调 ScreenCapturePermissionRepair.resetRecordOncePerBuild()：钉着旧签名的记录不删，系统不会再问"
fi
SETUP="Sources/SrtFlow/ScreenRecordingCoordinator+Setup.swift"
if [ "$(count '_ = await ScreenRecordingPermissions\.requestScreenAccess\(\)' "${SETUP}")" -ne 1 ]; then
  fail "${SETUP} 录自定义区域没走 ScreenRecordingPermissions.requestScreenAccess()"
fi
TCCUTIL_FILES="$(grep -rlF '"/usr/bin/tccutil"' Sources --include='*.swift' || true)"
if [ "${TCCUTIL_FILES}" != "Sources/SrtFlow/ScreenCapturePermissionRepair.swift" ]; then
  fail "调 tccutil 的应该只有 Sources/SrtFlow/ScreenCapturePermissionRepair.swift，现在是：${TCCUTIL_FILES:-（没有）}"
fi

echo "==> 7. 不再叫人「关掉再打开」"
STALE_ADVICE='If the switch is already on, turn it off and on again'
STALE_HITS="$(grep -rlF "${STALE_ADVICE}" Sources || true)"
if [ -n "${STALE_HITS}" ]; then
  fail "还在叫人把录屏开关关掉再打开（钉着旧签名的记录拨开关救不回来）：${STALE_HITS}"
fi

echo "==> 8. sign-app.sh signs a fixture app (ad-hoc: hardened runtime, entitlements on the app, stray code refused)"
. checks/release-signing/fixture.sh

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ release-signing: Developer ID, hardened runtime and notarization only through scripts/signing/; stale screen recording records removed by the app"
