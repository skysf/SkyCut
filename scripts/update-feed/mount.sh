# The release DMG's mount for scripts/write-update-feed.sh (read-only, hidden from Finder) and the cleanup that leaves
# nothing attached. Sourced, never run on its own. scripts/check-app-update.sh runs these same functions on a scratch
# image and fails after the mount on purpose, because the wrapper itself stops at Gatekeeper without a notarized DMG.
#
# feed_mount_init   makes the work folder FEED_WORK (mktemp) and the mount point FEED_MOUNT inside it.
# feed_attach DMG   attaches the image read-only at FEED_MOUNT, hidden (-nobrowse), opening nothing.
# feed_mounted      is true while a volume is mounted at FEED_MOUNT. It compares the mount point's device with its
#                   parent's, never paths. TMPDIR is under /var, a link to /private/var, and `mount` prints the resolved
#                   path, so matching the path as written never found the mount: a run that failed after the attach
#                   left the DMG attached (docs/bugfixes/2026-11-27-feed-writer-apostrophe-never-parsed.md).
# feed_detach       detaches on the success path. Not forced: a busy volume fails the run and the cleanup forces it.
# feed_cleanup      is the EXIT trap. It forces off whatever is still mounted at FEED_MOUNT, then removes FEED_WORK,
#                   but never while a volume is still mounted inside it.

feed_mount_init() {
  FEED_WORK="$(mktemp -d "${TMPDIR:-/tmp/}skycut-feed.XXXXXX")"
  FEED_MOUNT="${FEED_WORK}/mount"
  mkdir -p "${FEED_MOUNT}"
}

feed_mounted() {
  [ -d "${FEED_MOUNT:-}" ] && [ "$(stat -f %d "${FEED_MOUNT}")" != "$(stat -f %d "${FEED_WORK}")" ]
}

feed_attach() {
  /usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "${FEED_MOUNT}" "$1"
}

feed_detach() {
  /usr/bin/hdiutil detach -quiet "${FEED_MOUNT}" && return 0
  echo "✗ write-update-feed: the DMG did not detach (busy?); the cleanup forces it off" >&2
  return 1
}

feed_cleanup() {
  [ -n "${FEED_WORK:-}" ] || return 0
  if feed_mounted; then
    /usr/bin/hdiutil detach -quiet -force "${FEED_MOUNT}" || true
  fi
  if feed_mounted; then
    echo "✗ write-update-feed: ${FEED_MOUNT} is still mounted: hdiutil detach -force it, then remove ${FEED_WORK}" >&2
    return 0
  fi
  rm -rf "${FEED_WORK}"
}
