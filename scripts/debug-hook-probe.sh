#!/usr/bin/env bash
# Refuses a binary that still names a debug-only test hook: SRTFLOW_TEST_UPLOAD_DROPS and its type CloudUploadFault
# (Sources/SrtFlow/CloudMedia/CloudUploadFault.swift), SRTFLOW_TEST_DOWNLOAD_DROPS and its type CloudDownloadFault
# (Sources/SrtFlow/CloudMedia/CloudDownloadFault.swift; 2026-11-24), each inside #if DEBUG. Exit 1 with the names found, exit 0 when
# the binary is clean; strings failing fails loudly.
#
# scripts/build-app.sh runs it on the release binary before packaging. scripts/check-sky-studio.sh runs it on a build without DEBUG
# (must pass) and on a debug build (must be refused: the control, so a probe that stops refusing turns red there).
# Rules: docs/architecture/sky-studio-jobs.md, "Uploads that the network interrupts".
#
# Usage: scripts/debug-hook-probe.sh <binary>
set -euo pipefail

BINARY="${1:?usage: scripts/debug-hook-probe.sh <binary>}"
FOUND="$(mktemp)"
trap 'rm -f "${FOUND}"' EXIT
strings -a "${BINARY}" > "${FOUND}"
TRACES="$(grep -F -e SRTFLOW_TEST_UPLOAD_DROPS -e CloudUploadFault -e SRTFLOW_TEST_DOWNLOAD_DROPS -e CloudDownloadFault "${FOUND}" || true)"
if [ -n "${TRACES}" ]; then
  printf '✗ %s carries a debug-only test hook; it must stay inside #if DEBUG:\n%s\n' "${BINARY}" "${TRACES}" >&2
  exit 1
fi
echo "✓ no debug-only test hook in ${BINARY}"
