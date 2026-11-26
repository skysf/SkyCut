#!/usr/bin/env bash
# Notarizes a Developer-ID-signed SkyCut build with Apple and staples the ticket to it, so Gatekeeper opens it directly,
# offline too (build-app.sh: the app, then its DMG; build-beta-app.sh: the Beta). docs/architecture/code-signing-and-permissions.md.
#
# - An app goes up as a zip made with ditto (notarytool takes no bundle) and gets the ticket stapled to itself, before
#   build-dmg.sh copies it into the DMG; the DMG is signed (sign-dmg.sh), submitted and stapled after that. Either way
#   `stapler validate` and Gatekeeper's own assessment ("source=Notarized Developer ID") must pass. A rejected
#   submission prints Apple's log.
# - Credentials: only the keychain profile NOTARY_PROFILE (common.sh: notary-26TVX3S9FR unless SKYCUT_NOTARY_PROFILE says
#   otherwise), which the user creates once with `xcrun notarytool store-credentials`. Nothing here reads, asks for or
#   prints a password or key.
# - `--check` (build-app.sh and build-beta-app.sh run it first): stops with how to create the profile when notarytool
#   cannot use it, before a long compile is wasted.
# - signing_mode refuses (status kept) an expired or unknown certificate and a Mac with no Developer ID of our team, so
#   `--check` stops a build before the compile. Only with SKYCUT_ALLOW_ADHOC=1 (a build for oneself) is an ad-hoc build
#   let through, not notarized, with a warning: Apple notarizes only Developer ID code.
#
# Usage: scripts/signing/notarize.sh --check | <SkyCut.app | SkyCut Beta.app | SkyCut-x.y.z-arm64.dmg>
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: scripts/signing/notarize.sh --check | <app or dmg>" >&2
  exit 1
fi
if [ "$1" = --check ]; then
  cd "$(dirname "$0")/../.."
  source scripts/signing/common.sh
  MODE="$(signing_mode)"
  if [ "${MODE}" != developer-id ]; then
    echo "⚠️  SKYCUT_ALLOW_ADHOC=1: this build will be signed ad-hoc and not notarized. Never hand it to anyone."
    exit 0
  fi
  notary_profile_ready
  echo "   Notary profile ${NOTARY_PROFILE}: ready"
  exit 0
fi
case "$1" in
  *.app) [ -d "$1" ] ;;
  *.dmg) [ -f "$1" ] ;;
  *) false ;;
esac || { echo "Usage: scripts/signing/notarize.sh --check | <app or dmg>" >&2; exit 1; }
TARGET="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
NAME="$(basename "${TARGET}")"
cd "$(dirname "$0")/../.."
source scripts/signing/common.sh

MODE="$(signing_mode)"
if [ "${MODE}" != developer-id ]; then
  echo "⚠️  SKYCUT_ALLOW_ADHOC=1: ${NAME} is not notarized. Never hand it to anyone or release it."
  exit 0
fi
signing_check_identity "${TARGET}"
notary_profile_ready

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PAYLOAD="${TARGET}"
if [ "${TARGET%.app}" != "${TARGET}" ]; then
  PAYLOAD="${WORK}/${NAME%.app}.zip"
  ditto -c -k --keepParent "${TARGET}" "${PAYLOAD}"
fi
echo "   Submitting ${NAME} to Apple's notary service (profile ${NOTARY_PROFILE}); this usually takes a few minutes"
xcrun notarytool submit "${PAYLOAD}" --keychain-profile "${NOTARY_PROFILE}" --wait --timeout 1h \
  --output-format json > "${WORK}/submission.json" || true
ID="$(plutil -extract id raw -o - "${WORK}/submission.json" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "${WORK}/submission.json" 2>/dev/null || true)"
if [ "${STATUS}" != Accepted ]; then
  echo "✗ Notarization of ${NAME} ended ${STATUS:-without an answer} (submission ${ID:-none}):" >&2
  cat "${WORK}/submission.json" >&2
  if [ -n "${ID}" ]; then
    xcrun notarytool log "${ID}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
  fi
  exit 1
fi
echo "   Accepted (submission ${ID})"

# Seconds after «Accepted» the ticket may not be downloadable yet (FBS1 7): three tries, 20 s apart.
STAPLED=0
for attempt in 1 2 3; do
  if xcrun stapler staple "${TARGET}"; then
    STAPLED=1
    break
  fi
  if [ "${attempt}" -lt 3 ]; then
    sleep 20
  fi
done
if [ "${STAPLED}" -ne 1 ]; then
  echo "✗ The ticket of ${NAME} (submission ${ID}) could not be stapled; try xcrun stapler staple again in a few minutes" >&2
  exit 1
fi
xcrun stapler validate "${TARGET}"
if [ "${TARGET%.app}" != "${TARGET}" ]; then
  ASSESSMENT="$(spctl --assess --type execute -vv "${TARGET}" 2>&1 || true)"
else
  ASSESSMENT="$(spctl --assess --type open --context context:primary-signature -vv "${TARGET}" 2>&1 || true)"
fi
if ! grep -qxF 'source=Notarized Developer ID' <<<"${ASSESSMENT}"; then
  echo "✗ Gatekeeper does not accept ${NAME} as notarized:" >&2
  echo "${ASSESSMENT}" >&2
  exit 1
fi
echo "   ${NAME}: notarized, ticket stapled, Gatekeeper accepts it"
