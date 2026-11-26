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
#   1. the build scripts never sign or notarize themselves: scripts/signing/ in order (the identity and notary profile
#      checked before the compile; the app signed, notarized; the DMG built, signed, notarized; the Beta signed,
#      notarized); a failed run deletes what it wrote in dist/; nothing in scripts/ sets the SKYCUT_ALLOW_ADHOC opt-out;
#   2. sign-app.sh: one signing command with the hardened runtime, inside out; entitlements only on the app; the Developer
#      ID branch timestamps, ad-hoc only in the other branch; every check after signing ends the run when it fails;
#      sign-dmg.sh keeps signing_mode's refusal, timestamps and checks the DMG;
#   3. the pin: one SHA-1, the team, the shared notary profile; signing_mode_from (fed listings) picks only the pinned
#      identity, refuses an expired pin or another certificate of our team, and answers ad-hoc otherwise;
#   4. the entitlements: only resource-access keys a usage description in Info.plist needs, every such usage description
#      has its key, no hardened-runtime exception (they need proof that a real feature fails without them);
#   5. notarize.sh: keeps signing_mode's refusal; the whole notarytool command gets only the keychain profile; it waits,
#      retries the staple, validates and requires Gatekeeper's "Notarized Developer ID", each failure ending the run;
#   6. recording a custom region deletes the stale record before asking; tccutil is called in one place;
#   7. no "turn it off and on again" advice;
#   8. the real scripts with stub tools (no keychain, network or Apple): signing_mode refuses a failing `security`, an
#      expired pin and a Mac with no Developer ID unless SKYCUT_ALLOW_ADHOC=1; sign-app.sh, sign-dmg.sh and
#      `notarize.sh --check` stop on those refusals and on an unusable notary profile; signing_check_identity refuses
#      another leaf certificate; sign-app.sh signs a fixture app ad-hoc with the opt-out (the runtime on all four pieces,
#      entitlements only on the app) and refuses stray code.
# Steps are matched as whole lines, indentation included (FBS1 review, 2026-11-26): a step commented out, made
# conditional or given `|| true` is not there any more.
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}
count() { { grep -cE -- "$1" "$2" || true; }; }
countF() { { grep -cF -- "$1" "$2" || true; }; }
countX() { { grep -cxF -- "$1" "$2" || true; }; }
first_line() { { grep -nE "$1" "$2" || true; } | awk -F: 'NR == 1 { print $1 }'; }
lineX() { { grep -nxF -- "$1" "$2" || true; } | awk -F: 'NR == 1 { print $1 }'; }
# The whole lines named by the arguments after the file are there once each, in this order.
in_order() {
  local file="$1" previous=0 line text
  shift
  for text in "$@"; do
    line="$(lineX "${text}" "${file}")"
    if [ -z "${line}" ] || [ "$(countX "${text}" "${file}")" -ne 1 ]; then
      fail "${file}: needs exactly one line that is exactly: ${text}"
      return
    fi
    if [ "${line}" -le "${previous}" ]; then
      fail "${file}: \"${text}\" (line ${line}) must come after line ${previous}"
    fi
    previous="${line}"
  done
}
# Each `if` opened by a whole line read from stdin ends the run when taken: its last line before its own `fi` (same
# indentation) is `exit 1` or `return 1`.
blocks_exit() {
  local file="$1" opener verdict
  while IFS= read -r opener; do
    verdict="$(OPENER="${opener}" awk '
      state == 0 && $0 == ENVIRON["OPENER"] { state = 1; match($0, /^ */); indent = substr($0, 1, RLENGTH); next }
      state == 1 && $0 == indent "fi" {
        state = 2
        print (last == indent "  exit 1" || last == indent "  return 1") ? "ends" : "falls through"
        exit
      }
      state == 1 { last = $0 }
      END { if (state == 0) print "missing"; else if (state == 1) print "unclosed" }' "${file}")"
    if [ "${verdict}" != ends ]; then
      fail "${file}: the branch «${opener}» must end with exit 1 / return 1 (${verdict})"
    fi
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
  "trap 'discard_unfinished \$?' EXIT" 'WROTE_APP=1' 'scripts/signing/sign-app.sh "$APP"' 'scripts/signing/notarize.sh "$APP"' \
  'WROTE_DMG=1' '/bin/bash scripts/build-dmg.sh "$APP" "$DMG"' 'scripts/signing/sign-dmg.sh "$DMG"' \
  'scripts/signing/notarize.sh "$DMG"'
in_order scripts/build-beta-app.sh 'scripts/signing/notarize.sh --check' "trap 'discard_unfinished \$?' EXIT" 'WROTE_BETA=1' \
  'ditto "${SRC}" "${BETA}"' 'scripts/signing/sign-app.sh "${BETA}"' 'scripts/signing/notarize.sh "${BETA}"'
OPT_OUT="$({ grep -rnE '(^|[[:space:];&|(])(export[[:space:]]+)?SKYCUT_ALLOW_ADHOC=' scripts || true; } \
  | { grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|echo )' || true; })"
if [ -n "${OPT_OUT}" ]; then
  fail "only the person building may set SKYCUT_ALLOW_ADHOC (ad-hoc builds are never for users); scripts set it: ${OPT_OUT}"
fi

echo "==> 2. sign-app.sh: hardened runtime, inside out, entitlements on the app, every check ends the run"
if [ "$(count 'codesign --force' "${SIGN}")" -ne 1 ] \
  || [ "$(countX '  codesign --force --options runtime "${IDENTITY[@]}" "$@"' "${SIGN}")" -ne 1 ]; then
  fail "${SIGN} must sign through one command, codesign --force --options runtime \"\${IDENTITY[@]}\" (no --deep)"
fi
in_order "${SIGN}" 'MODE="$(signing_mode)"' '  IDENTITY=(--sign "$(signing_pinned_sha1)" --timestamp)' \
  '  IDENTITY=(--sign - --timestamp=none)' 'rm -f "${APP}/Contents/CodeResources"' 'sign_code "${APP}/Contents/Helpers/ffmpeg"' \
  'sign_code "${APP}/Contents/Helpers/skycut-mcp"' 'sign_code "${APP}/Contents/Helpers/skycut-web-motion"' \
  'sign_code --entitlements "${SIGNING_ENTITLEMENTS}" "${APP}"' 'codesign --verify --deep --strict "${APP}"' \
  '    signing_check_identity "${code}"'
BRANCH_LINE="$(first_line '^if \[ "\$\{MODE\}" = developer-id \]; then$' "${SIGN}")"
ELSE_LINE="$(first_line '^else$' "${SIGN}")"
CLOSE_LINE="$({ grep -nxF 'fi' "${SIGN}" || true; } | awk -F: -v after="${ELSE_LINE:-0}" '$1 > after { print $1; exit }')"
DEVELOPER_LINE="$(lineX '  IDENTITY=(--sign "$(signing_pinned_sha1)" --timestamp)' "${SIGN}")"
ADHOC_LINE="$(lineX '  IDENTITY=(--sign - --timestamp=none)' "${SIGN}")"
if [ -z "${BRANCH_LINE}" ] || [ -z "${ELSE_LINE}" ] || [ -z "${CLOSE_LINE}" ] || [ -z "${DEVELOPER_LINE}" ] \
  || [ -z "${ADHOC_LINE}" ] || [ "${DEVELOPER_LINE}" -lt "${BRANCH_LINE}" ] || [ "${DEVELOPER_LINE}" -gt "${ELSE_LINE}" ] \
  || [ "${ADHOC_LINE}" -lt "${ELSE_LINE}" ] || [ "${ADHOC_LINE}" -gt "${CLOSE_LINE}" ]; then
  fail "${SIGN}: the timestamped Developer ID signs when signing_mode says developer-id; ad-hoc only in the other branch"
fi
if [ "$(count '^sign_code .*--entitlements' "${SIGN}")" -ne 1 ]; then
  fail "${SIGN}: entitlements only on the outer app (the helpers need none under the hardened runtime)"
fi
blocks_exit "${SIGN}" <<'LINES'
  if [ ! -f "${APP}/Contents/Helpers/${helper}" ]; then
if [ -n "${UNEXPECTED}" ]; then
  if ! grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"${DETAILS}"; then
  if [ "$(entitlement_keys "${code}")" != "${EXPECTED}" ]; then
  if ! grep -qE "anchor apple generic .*certificate leaf\[subject\.OU\] = \"?${SIGNING_TEAM_ID}\"?" <<<"${REQUIREMENT}"; then
LINES
blocks_exit "${COMMON}" <<'LINES'
  if ! grep -qxF "TeamIdentifier=${SIGNING_TEAM_ID}" <<<"${details}"; then
  if ! grep -q '^Timestamp=' <<<"${details}"; then
  if [ "${leaf}" != "$(signing_pinned_sha1)" ]; then
  if ! valid="$(security find-identity -v -p codesigning 2>&1)" || ! all="$(security find-identity -p codesigning 2>&1)"; then
  if [ "${mode}" = ad-hoc ] && [ "${SKYCUT_ALLOW_ADHOC:-}" != 1 ]; then
LINES
in_order "${SIGN_DMG}" 'MODE="$(signing_mode)"' 'codesign --force --sign "$(signing_pinned_sha1)" --timestamp "${DMG}"' \
  'codesign --verify --strict "${DMG}"' 'signing_check_identity "${DMG}"'

echo "==> 3. The pin and the identity decision"
PINNED="$({ grep -v '^#' packaging/signing-identity.sha1 || true; } | { grep -v '^[[:space:]]*$' || true; })"
if [ "$(grep -cxE '[0-9a-f]{40}' <<<"${PINNED}" || true)" -ne 1 ] || [ "$(wc -l <<<"${PINNED}" | tr -d ' ')" -ne 1 ]; then
  fail "packaging/signing-identity.sha1 must hold one lowercase 40-digit SHA-1 (besides comments), not: ${PINNED:-(nothing)}"
fi
for text in 'SIGNING_TEAM_ID="26TVX3S9FR"' 'NOTARY_PROFILE="${SKYCUT_NOTARY_PROFILE:-notary-${SIGNING_TEAM_ID}}"' \
  'SIGNING_ENTITLEMENTS="packaging/SkyCut.entitlements"'; do
  if [ "$(countX "${text}" "${COMMON}")" -ne 1 ]; then
    fail "${COMMON} must say ${text}"
  fi
done
. checks/release-signing/decision.sh

echo "==> 4. Entitlements: only what a usage description needs, no exceptions"
. checks/release-signing/entitlements.sh

echo "==> 5. notarize.sh: refusals kept, the keychain profile only; waits, staples, validates, Gatekeeper accepts"
in_order "${NOTARIZE}" '  MODE="$(signing_mode)"' '  notary_profile_ready' 'MODE="$(signing_mode)"' 'signing_check_identity "${TARGET}"' \
  'notary_profile_ready' 'xcrun notarytool submit "${PAYLOAD}" --keychain-profile "${NOTARY_PROFILE}" --wait --timeout 1h \' \
  'if [ "${STATUS}" != Accepted ]; then' '  if xcrun stapler staple "${TARGET}"; then' 'xcrun stapler validate "${TARGET}"' \
  "if ! grep -qxF 'source=Notarized Developer ID' <<<\"\${ASSESSMENT}\"; then"
blocks_exit "${NOTARIZE}" <<'LINES'
if [ "${STATUS}" != Accepted ]; then
if [ "${STAPLED}" -ne 1 ]; then
if ! grep -qxF 'source=Notarized Developer ID' <<<"${ASSESSMENT}"; then
LINES
# Whole commands: a backslash-continued line is read together with the next, so a credential added on a later line counts.
CALLS="$(awk 'FNR == 1 { held = "" } { line = held $0; if (sub(/\\$/, "", line)) { held = line " "; next } held = ""; print line }' \
  scripts/signing/*.sh scripts/build-*.sh | { grep -E 'notarytool (submit|log|history|store-credentials)' || true; } \
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

echo "==> 8. The real scripts with stub tools: refusals kept; an ad-hoc fixture signed with the opt-out; stray code refused"
. checks/release-signing/fixture.sh

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ release-signing: Developer ID, hardened runtime and notarization only through scripts/signing/; stale screen recording records removed by the app"
