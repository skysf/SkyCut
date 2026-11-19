#!/usr/bin/env bash
# Exports SkyCut's tool vocabulary (format skycut-tool-vocabulary/1): the file Sky Studio's content gate checks every
# published editing style and craft card against, so no published text names a tool, parameter or option the build users
# have doesn't take (MCP-62; docs/architecture/ai-control-mcp.md section 4 item 32).
#
#   VERSION=x.y.z scripts/export-tool-vocabulary.sh <out.json>   # each release: build-app.sh's VERSION; the file goes to ops
#   scripts/export-tool-vocabulary.sh <out.json>                 # anything else: skycut_version is null, never published
#
# What is in it: scripts/tool-vocabulary/main.swift. scripts/check-mcp.sh runs this on every PR and compares the file with
# the live catalog (ToolVocabularyChecks), so a change that breaks the export turns red in its own PR.
set -euo pipefail

if [ $# -ne 1 ] || [ -z "${1}" ]; then
  echo "usage: [VERSION=x.y.z] $0 <out.json>" >&2
  exit 2
fi
OUT_FILE="${1}"
case "${OUT_FILE}" in
  /*) ;;
  *) OUT_FILE="$(pwd)/${OUT_FILE}" ;;
esac
if [ ! -d "$(dirname "${OUT_FILE}")" ]; then
  echo "✗ no folder for ${OUT_FILE}" >&2
  exit 2
fi
VERSION_SHAPE='^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$'
if [ -n "${VERSION:-}" ] && ! [[ "${VERSION}" =~ ${VERSION_SHAPE} ]]; then
  echo "✗ VERSION=${VERSION} is not x.y.z (the version scripts/build-app.sh packaged, without a leading v)" >&2
  exit 2
fi
cd "$(dirname "$0")/.."

# Which commit the names come from, and whether the exported sources differ from it (a dirty file may not match the build).
COMMIT="$(git rev-parse HEAD)"
COMMIT_DATE="$(git log -1 --format=%cI HEAD)"
CHANGED="$(git --no-optional-locks status --porcelain -- Sources/SrtFlowMCPKit scripts/tool-vocabulary \
  checks/MCP/CatalogNames.swift Sources/SrtFlow/AIVoiceRole.swift Sources/SrtFlow/Resources/recipes-shared-rules.md)"
DIRTY="false"
if [ -n "${CHANGED}" ]; then
  DIRTY="true"
fi

# SwiftPM prints compile errors on stdout: quiet on success, the whole output on failure.
BUILD_OUT="$(swift build --arch arm64 --target SrtFlowMCPKit 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"

WORK="$(mktemp -d)"
PARTIAL="${OUT_FILE}.partial.$$"
trap 'rm -rf "${WORK}"; rm -f "${PARTIAL}"' EXIT

# catalogKnownNames (CatalogNames.swift) also lists the local voices, so the voice roles come along.
xcrun swiftc \
  -target arm64-apple-macosx15.0 \
  -wmo \
  -I "${BUILD_DIR}/Modules" \
  -o "${WORK}/tool-vocabulary" \
  scripts/tool-vocabulary/main.swift \
  checks/MCP/CatalogNames.swift \
  Sources/SrtFlow/AIVoiceRole.swift \
  Sources/SrtFlow/AIVoiceChoice.swift \
  Sources/SrtFlow/AIToolIO.swift \
  "${BUILD_DIR}"/SrtFlowMCPKit.build/*.o

"${WORK}/tool-vocabulary" --version "${VERSION:-}" --commit "${COMMIT}" --commit-date "${COMMIT_DATE}" --dirty "${DIRTY}" \
  --shared-rules Sources/SrtFlow/Resources/recipes-shared-rules.md > "${PARTIAL}"
mv -f "${PARTIAL}" "${OUT_FILE}"

if [ -z "${VERSION:-}" ]; then
  echo "⚠️  no VERSION: skycut_version is null, not a file to publish against (for a release: VERSION=x.y.z)" >&2
fi
if [ "${DIRTY}" = "true" ]; then
  echo "⚠️  the exported sources have uncommitted changes: this file may not match a build of ${COMMIT}" >&2
fi
echo "✓ wrote ${OUT_FILE} (SkyCut ${VERSION:-without a version}, ${COMMIT})"
