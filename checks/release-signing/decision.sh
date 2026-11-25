# Section 3 of checks/release-signing.sh (sourced; uses its `fail`): scripts/signing/common.sh's signing_mode_from, fed
# `security find-identity` listings, signs only with the pinned Developer ID, refuses a pin that is no longer valid or a
# different certificate of our team, and falls back to ad-hoc only when no Developer ID of our team is here.

decision_case() {
  local want="$1" valid="$2" all="$3" why="$4" got status
  status=0
  got="$( . scripts/signing/common.sh && signing_mode_from "${valid}" "${all}" 2>/dev/null )" || status=$?
  if [ "${want}" = refuse ]; then
    if [ "${status}" -eq 0 ]; then
      fail "signing_mode_from must refuse ${why}, got: ${got:-(nothing)}"
    fi
  elif [ "${status}" -ne 0 ] || [ "${got}" != "${want}" ]; then
    fail "signing_mode_from must answer ${want} ${why}, got: ${got:-(nothing)} (status ${status})"
  fi
}

PIN_UPPER="$( . scripts/signing/common.sh && signing_pinned_sha1 | tr 'a-f' 'A-F' )"
ANOTHER="0123456789ABCDEF0123456789ABCDEF01234567"
OURS="Developer ID Application: TIANYU LU (26TVX3S9FR)"
PINNED_VALID="  1) ${PIN_UPPER} \"${OURS}\"
     1 valid identities found"
PINNED_EXPIRED="  1) ${PIN_UPPER} \"${OURS}\" (CSSMERR_TP_CERT_EXPIRED)
     1 identities found"
RENEWED="  1) ${ANOTHER} \"${OURS}\"
     1 valid identities found"
OTHER_TEAM="  1) ${ANOTHER} \"Developer ID Application: Someone Else (ABCDE12345)\"
  2) FEDCBA9876543210FEDCBA9876543210FEDCBA98 \"Apple Distribution: TIANYU LU (26TVX3S9FR)\"
     2 valid identities found"
NONE="     0 valid identities found"

decision_case developer-id "${PINNED_VALID}" "${PINNED_VALID}" "when the pinned Developer ID is valid"
decision_case developer-id "${PINNED_VALID}
${OTHER_TEAM}" "${PINNED_VALID}
${OTHER_TEAM}" "when the pinned Developer ID sits next to other identities"
decision_case refuse "${NONE}" "${PINNED_EXPIRED}" "when the pinned Developer ID has expired (not ad-hoc)"
decision_case refuse "${RENEWED}" "${RENEWED}" "when our team's Developer ID is another certificate than the pin"
decision_case refuse "${NONE}" "  1) ${ANOTHER} \"${OURS}\" (CSSMERR_TP_CERT_EXPIRED)" "when only an expired certificate of our team is here"
decision_case ad-hoc "${OTHER_TEAM}" "${OTHER_TEAM}" "when only other teams' identities are here (never sign with them)"
decision_case ad-hoc "${NONE}" "${NONE}" "when this Mac has no identity (CI, a build from source)"
decision_case ad-hoc "" "" "when security lists nothing at all"
