#!/usr/bin/env bash
# Signs a built SkyCut DMG with the pinned Developer ID (build-app.sh, before notarize.sh submits it): Gatekeeper checks a
# downloaded disk image's own signature and ticket before it mounts it. signing_mode's refusal stops it (status kept);
# only with SKYCUT_ALLOW_ADHOC=1 does the DMG of an ad-hoc build stay unsigned. docs/architecture/code-signing-and-permissions.md.
#
# Usage: scripts/signing/sign-dmg.sh <SkyCut-x.y.z-arm64.dmg>
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -f "$1" ] || [ "${1%.dmg}" = "$1" ]; then
  echo "Usage: scripts/signing/sign-dmg.sh <SkyCut-x.y.z-arm64.dmg>" >&2
  exit 1
fi
DMG="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
cd "$(dirname "$0")/../.."
source scripts/signing/common.sh

MODE="$(signing_mode)"
if [ "${MODE}" != developer-id ]; then
  echo "⚠️  SKYCUT_ALLOW_ADHOC=1: the DMG stays unsigned. Never hand it to anyone or release it."
  exit 0
fi
codesign --force --sign "$(signing_pinned_sha1)" --timestamp "${DMG}"
codesign --verify --strict "${DMG}"
signing_check_identity "${DMG}"
echo "   DMG signed (team ${SIGNING_TEAM_ID})"
