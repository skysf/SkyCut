#!/bin/bash
# Writes SkyCut's update feed (skycut.json) for a release, from the verified DMG and a notes file
# (docs/architecture/app-updates.md "The feed"; the release steps: docs/build/build-and-packaging.md 「公开下载发布」).
# It reads the version, build and minimum macOS from the app inside the DMG (mounted read-only where Finder doesn't show
# it), wants Gatekeeper to accept the DMG and its app as notarized Developer ID, measures the DMG's size and SHA-256, and
# hands everything to scripts/update-feed/FeedWriter.swift, which composes the feed with SkyCut's own code and parses it back
# with SkyCut's own parser: a feed the app would refuse is never written.
# Usage: scripts/write-update-feed.sh [--test-feed <the test feed's own URL>] <verified.dmg> <immutable DMG URL> <notes.json> <out.json>
#   notes.json: {"zh-Hans": ["…", "…"], "en": ["…", "…"], "es": ["…", "…"]}, 3 to 5 short lines each (at most 8, 300 characters).
#   The DMG URL is its immutable object on https://downloads.skylu.ai. --test-feed (the manual two-build test, never a
#   release): the feed is checked as SkyCut checks one from that test hook, so the DMG may also be served from its origin.
# Not in check-all (it needs the signed release DMG); scripts/check-app-update.sh runs FeedWriter on fixture values.
set -euo pipefail
TEST_FEED=""
if [ "${1:-}" = "--test-feed" ]; then
  TEST_FEED="${2:?--test-feed needs the URL of the test feed itself}"
  shift 2
fi
DMG="${1:?usage: scripts/write-update-feed.sh [--test-feed <url>] <verified.dmg> <immutable DMG URL> <notes.json> <out.json>}"
URL="${2:?the immutable URL of the DMG on downloads.skylu.ai}"
NOTES="${3:?the notes file (zh-Hans, en, es)}"
OUT="${4:?where to write the feed}"
cd "$(dirname "$0")/.."
[ -f "${DMG}" ] || { echo "✗ write-update-feed: no DMG at ${DMG}" >&2; exit 1; }
[ -f "${NOTES}" ] || { echo "✗ write-update-feed: no notes file at ${NOTES}" >&2; exit 1; }
if [ -z "${TEST_FEED}" ]; then
  case "${URL}" in
    https://downloads.skylu.ai/*.dmg) ;;
    *) echo "✗ write-update-feed: the DMG URL must be its immutable object on https://downloads.skylu.ai (never the redirect): ${URL}" >&2; exit 1 ;;
  esac
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp/}skycut-feed.XXXXXX")"
MOUNT="${WORK}/mount"
cleanup() {
  if mount | grep -F " on ${MOUNT} " >/dev/null 2>&1; then /usr/bin/hdiutil detach -quiet -force "${MOUNT}" || true; fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

if ! /usr/sbin/spctl --assess --type open --context context:primary-signature -vv "${DMG}" 2>&1 | grep -F 'source=Notarized Developer ID' >/dev/null; then
  echo "✗ write-update-feed: Gatekeeper doesn't accept ${DMG} as notarized Developer ID" >&2
  exit 1
fi
mkdir -p "${MOUNT}"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "${MOUNT}" "${DMG}"
APP="${MOUNT}/SkyCut.app"
PLIST="${APP}/Contents/Info.plist"
[ -f "${PLIST}" ] || { echo "✗ write-update-feed: no SkyCut.app at the top of ${DMG}" >&2; exit 1; }
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "${PLIST}"; }
BUNDLE_ID="$(read_key CFBundleIdentifier)"
VERSION="$(read_key CFBundleShortVersionString)"
BUILD="$(read_key CFBundleVersion)"
MINIMUM="$(read_key LSMinimumSystemVersion)"
[ "${BUNDLE_ID}" = "com.srtflow.SrtFlow" ] || { echo "✗ write-update-feed: the app is ${BUNDLE_ID}, not the release app" >&2; exit 1; }
if ! /usr/sbin/spctl --assess --type execute -vv "${APP}" 2>&1 | grep -F 'source=Notarized Developer ID' >/dev/null; then
  echo "✗ write-update-feed: Gatekeeper doesn't accept the DMG's app as notarized Developer ID" >&2
  exit 1
fi
/usr/bin/hdiutil detach -quiet "${MOUNT}"
SIZE="$(stat -f %z "${DMG}")"
SHA="$(shasum -a 256 "${DMG}" | awk '{ print $1 }')"

xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  Sources/SrtFlow/AppUpdate/AppUpdateVersion.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateFeed.swift \
  Sources/SrtFlow/AppUpdate/AppUpdateRecords.swift \
  scripts/update-feed/FeedWriter.swift \
  -o "${WORK}/feed-writer"
if [ -n "${TEST_FEED}" ]; then
  "${WORK}/feed-writer" "${OUT}" "${VERSION}" "${BUILD}" "${MINIMUM}" "${URL}" "${SIZE}" "${SHA}" "${NOTES}" "${TEST_FEED}"
else
  "${WORK}/feed-writer" "${OUT}" "${VERSION}" "${BUILD}" "${MINIMUM}" "${URL}" "${SIZE}" "${SHA}" "${NOTES}"
fi
