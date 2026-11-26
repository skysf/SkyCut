#!/usr/bin/env bash
# Signs an assembled SkyCut.app or SkyCut Beta.app: the only place that signs them (build-app.sh, build-beta-app.sh).
#
# - Inside out: the three Contents/Helpers executables (ffmpeg, skycut-mcp, skycut-web-motion), then the app; the other
#   order breaks the outer signature at once (scripts/check-mcp.sh and checks/web-motion-wiring.sh pin it). Any other
#   code in the bundle stops it: every binary that ships is named here, so none goes out unsigned.
# - The hardened runtime on every piece; entitlements only on the app (packaging/SkyCut.entitlements: the microphone and
#   Apple Events to Finder); the helpers need none. Which feature needs which entitlement, and the proof:
#   docs/architecture/code-signing-and-permissions.md.
# - Identity (scripts/signing/common.sh): the pinned Developer ID with a secure timestamp; afterwards every piece is
#   checked for our team, the pinned certificate, the timestamp and the runtime flag. signing_mode refuses (status kept)
#   an expired or unknown certificate and a Mac with no Developer ID of our team; only SKYCUT_ALLOW_ADHOC=1 (a build for
#   oneself, the guard's fixture) signs ad-hoc, with a warning: such a build never goes to anyone.
# - A notarization ticket stapled to an earlier signature (build-beta-app.sh copies the notarized release) belongs to the
#   old code and is removed; notarize.sh staples the new one.
#
# Usage: scripts/signing/sign-app.sh <app path>
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "Usage: scripts/signing/sign-app.sh <app path>" >&2
  exit 1
fi
APP="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
cd "$(dirname "$0")/../.."
source scripts/signing/common.sh

for helper in ffmpeg skycut-mcp skycut-web-motion; do
  if [ ! -f "${APP}/Contents/Helpers/${helper}" ]; then
    echo "✗ ${APP}/Contents/Helpers/${helper} is missing: assemble the app before signing it" >&2
    exit 1
  fi
done
MAIN="Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP}/Contents/Info.plist")"
UNEXPECTED="$(cd "${APP}" && find Contents -type f -exec file --mime-type -F '|' {} + | awk -F'|' -v main="${MAIN}" '
  NF == 2 && $2 ~ /mach-binary/ && $1 != main && $1 !~ /^Contents\/Helpers\/(ffmpeg|skycut-mcp|skycut-web-motion)$/ {
    print $1
  }')"
if [ -n "${UNEXPECTED}" ]; then
  echo "✗ Code in the bundle that sign-app.sh does not sign (name it here, with only the entitlements it needs):" >&2
  echo "${UNEXPECTED}" >&2
  exit 1
fi

MODE="$(signing_mode)"
if [ "${MODE}" = developer-id ]; then
  IDENTITY=(--sign "$(signing_pinned_sha1)" --timestamp)
  echo "   Identity: Developer ID Application of team ${SIGNING_TEAM_ID} (SHA-1 $(signing_pinned_sha1))"
else
  IDENTITY=(--sign - --timestamp=none)
  echo "⚠️  SKYCUT_ALLOW_ADHOC=1: signing ad-hoc. Never hand this build to anyone or release it: macOS treats every"
  echo "    ad-hoc build as another app (screen recording, microphone, Downloads and keychain permissions are asked again,"
  echo "    and the screen recording switch cannot bring them back), and Gatekeeper blocks it on every other Mac."
fi
rm -f "${APP}/Contents/CodeResources"

# Every piece gets the hardened runtime and the identity's options.
sign_code() {
  codesign --force --options runtime "${IDENTITY[@]}" "$@"
}
sign_code "${APP}/Contents/Helpers/ffmpeg"
sign_code "${APP}/Contents/Helpers/skycut-mcp"
sign_code "${APP}/Contents/Helpers/skycut-web-motion"
sign_code --entitlements "${SIGNING_ENTITLEMENTS}" "${APP}"

codesign --verify --deep --strict "${APP}"
entitlement_keys() {
  { codesign -d --entitlements - --xml "$1" 2>/dev/null || true; } | { grep -o '<key>[^<]*</key>' || true; } | sort
}
WANTED="$(plutil -convert xml1 -o - "${SIGNING_ENTITLEMENTS}" | { grep -o '<key>[^<]*</key>' || true; } | sort)"
for code in "${APP}/Contents/Helpers/ffmpeg" "${APP}/Contents/Helpers/skycut-mcp" "${APP}/Contents/Helpers/skycut-web-motion" "${APP}"; do
  DETAILS="$(codesign -dvvv "${code}" 2>&1 || true)"
  if ! grep -qE 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"${DETAILS}"; then
    echo "✗ ${code} is signed without the hardened runtime (notarization refuses it)" >&2
    exit 1
  fi
  EXPECTED=""
  if [ "${code}" = "${APP}" ]; then
    EXPECTED="${WANTED}"
  fi
  if [ "$(entitlement_keys "${code}")" != "${EXPECTED}" ]; then
    echo "✗ ${code} carries entitlements other than ${EXPECTED:-none}: $(entitlement_keys "${code}" | tr '\n' ' ')" >&2
    exit 1
  fi
  if [ "${MODE}" = developer-id ]; then
    signing_check_identity "${code}"
  fi
done
if [ "${MODE}" = developer-id ]; then
  REQUIREMENT="$(codesign -d -r- "${APP}" 2>&1 || true)"
  if ! grep -qE "anchor apple generic .*certificate leaf\[subject\.OU\] = \"?${SIGNING_TEAM_ID}\"?" <<<"${REQUIREMENT}"; then
    echo "✗ The designated requirement does not name team ${SIGNING_TEAM_ID}: permissions would not carry over" >&2
    echo "${REQUIREMENT}" >&2
    exit 1
  fi
fi
echo "   Signature verified (${MODE}, hardened runtime)"
