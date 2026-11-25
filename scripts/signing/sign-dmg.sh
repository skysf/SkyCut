#!/usr/bin/env bash
# Signs a built SkyCut DMG with the pinned Developer ID (build-app.sh, before notarize.sh submits it): Gatekeeper checks a
# downloaded disk image's own signature and ticket before it mounts it. On a Mac with no Developer ID of our team the
# DMG stays unsigned, like the ad-hoc app inside it (never handed to a user). docs/architecture/code-signing-and-permissions.md.
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

if [ "$(signing_mode)" != developer-id ]; then
  echo "⚠️  No Developer ID on this Mac: the DMG stays unsigned. Never hand it to a user or release it."
  exit 0
fi
codesign --force --sign "$(signing_pinned_sha1)" --timestamp "${DMG}"
codesign --verify --strict "${DMG}"
signing_check_identity "${DMG}"
echo "   DMG signed (team ${SIGNING_TEAM_ID})"
