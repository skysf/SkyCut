# Release signing, shared by sign-app.sh, sign-dmg.sh and notarize.sh (sourced, never run on its own): which identity
# signs SkyCut for users and releases, how a run picks the way to sign, the app's entitlements and the notary profile.
#
# The identity is the Developer ID Application certificate of team 26TVX3S9FR (TIANYU LU), pinned by its SHA-1 in
# packaging/signing-identity.sha1; its private key is in the login keychain. macOS keys its privacy grants (screen
# recording, microphone, Downloads, Automation, the keychain) to the signature's designated requirement, and a Developer
# ID requirement names the team, not the certificate: a renewed certificate of the same team keeps every grant
# (docs/architecture/code-signing-and-permissions.md).
#
# Callers cd to the repository root first (the paths below are relative).

SIGNING_PIN_FILE="packaging/signing-identity.sha1"
SIGNING_TEAM_ID="26TVX3S9FR"
# Only the app has entitlements; the helpers need none under the hardened runtime.
SIGNING_ENTITLEMENTS="packaging/SkyCut.entitlements"
# One profile for all of the user's apps (user, 2026-11-26), named by the team. The user creates it once with
# `xcrun notarytool store-credentials`; scripts only name it and never read, ask for or print the credentials.
NOTARY_PROFILE="${SKYCUT_NOTARY_PROFILE:-notary-${SIGNING_TEAM_ID}}"

# The pinned SHA-1, lowercase; empty when the file is missing or holds no hash.
signing_pinned_sha1() {
  if [ -f "${SIGNING_PIN_FILE}" ]; then
    { grep -v '^#' "${SIGNING_PIN_FILE}" || true; } | tr -d '[:space:]' | tr 'A-F' 'a-f'
  fi
}

# The SHA-1s (lowercase) in a `security find-identity` listing; with a second argument, only our team's Developer IDs.
# A listing line: `  1) 1EC5…8841 "Developer ID Application: TIANYU LU (26TVX3S9FR)"`; an expired one ends with
# ` (CSSMERR_TP_CERT_EXPIRED)`.
signing_listed_sha1s() {
  awk -v team="${2:-}" '
    $1 ~ /^[0-9]+\)$/ {
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/".*$/, "", name)
      suffix = "(" team ")"
      if (team == "" || (index(name, "Developer ID Application: ") == 1 &&
          substr(name, length(name) - length(suffix) + 1) == suffix)) print tolower($2)
    }' <<<"$1"
}

# How to sign, from the code-signing identities this Mac has. Pure over its inputs so checks/release-signing.sh can feed
# it listings: $1 = `security find-identity -v -p codesigning` (valid identities), $2 = the same without -v (expired and
# revoked ones too). Prints "developer-id" (the pinned identity is valid) or "ad-hoc" (no Developer ID of our team at
# all: CI, someone building from source); refuses with the reason (status 1) when our team's Developer ID is here but is
# not the pinned one, or the pinned one is no longer valid. It never picks any other identity.
signing_mode_from() {
  local valid="$1" all="$2" pinned other
  pinned="$(signing_pinned_sha1)"
  if ! grep -qxE '[0-9a-f]{40}' <<<"${pinned}"; then
    echo "✗ ${SIGNING_PIN_FILE} must hold exactly one SHA-1 (the Developer ID that signs SkyCut)" >&2
    return 1
  fi
  if grep -qxF "${pinned}" <<<"$(signing_listed_sha1s "${valid}")"; then
    echo developer-id
    return 0
  fi
  if grep -qxF "${pinned}" <<<"$(signing_listed_sha1s "${all}")"; then
    echo "✗ The pinned Developer ID (${pinned}) is in the keychain but no longer valid (expired or revoked)." >&2
    echo "  Renew it at developer.apple.com: a new certificate of team ${SIGNING_TEAM_ID} keeps every permission users" >&2
    echo "  gave SkyCut. Then put its SHA-1 in ${SIGNING_PIN_FILE}." >&2
    return 1
  fi
  other="$(signing_listed_sha1s "${all}" "${SIGNING_TEAM_ID}" | awk 'NR == 1')"
  if [ -n "${other}" ]; then
    echo "✗ This Mac has a Developer ID of team ${SIGNING_TEAM_ID} (${other}) but not the pinned one (${pinned})." >&2
    echo "  If it is the renewed certificate, put its SHA-1 in ${SIGNING_PIN_FILE} (same team: users keep every permission)." >&2
    return 1
  fi
  echo ad-hoc
}

signing_mode() {
  local valid all
  valid="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  all="$(security find-identity -p codesigning 2>/dev/null || true)"
  signing_mode_from "${valid}" "${all}"
}

# The signature on $1 is the pinned Developer ID's: our team, the pinned leaf certificate and a secure timestamp
# (notarization refuses code without one). Says what is wrong (status 1) otherwise.
signing_check_identity() {
  local code="$1" details work leaf
  details="$(codesign -dvvv "${code}" 2>&1 || true)"
  if ! grep -qxF "TeamIdentifier=${SIGNING_TEAM_ID}" <<<"${details}"; then
    echo "✗ ${code} is not signed by team ${SIGNING_TEAM_ID}" >&2
    return 1
  fi
  if ! grep -q '^Timestamp=' <<<"${details}"; then
    echo "✗ ${code} has no secure timestamp (notarization refuses it)" >&2
    return 1
  fi
  work="$(mktemp -d)"
  codesign -d --extract-certificates="${work}/certificate" "${code}" >/dev/null 2>&1 || true
  leaf=""
  if [ -f "${work}/certificate0" ]; then
    leaf="$(shasum -a 1 "${work}/certificate0" | awk '{ print $1 }')"
  fi
  rm -rf "${work}"
  if [ "${leaf}" != "$(signing_pinned_sha1)" ]; then
    echo "✗ ${code} is signed with certificate ${leaf:-(none)}, not the pinned $(signing_pinned_sha1)" >&2
    return 1
  fi
}

# notarytool can use the profile (it exists, its password works, Apple answers). Says how to create it otherwise.
notary_profile_ready() {
  local error
  if error="$(xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --output-format json 2>&1 >/dev/null)"; then
    return 0
  fi
  echo "✗ notarytool cannot use the keychain profile \"${NOTARY_PROFILE}\": ${error}" >&2
  echo "  If it does not exist yet, create it once in Terminal (it asks for an app-specific password made at" >&2
  echo "  appleid.apple.com; one profile serves every app of the team):" >&2
  echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <your Apple ID> --team-id ${SIGNING_TEAM_ID}" >&2
  return 1
}
