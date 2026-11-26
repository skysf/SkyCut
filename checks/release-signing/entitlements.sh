# Section 4 of checks/release-signing.sh (sourced; uses its `fail`): the app's entitlements under the hardened runtime.
#
# The runtime silently denies a protected resource the app has no entitlement for: macOS never even asks the user.
# So every usage description in Info.plist for such a resource needs its entitlement (a microphone description without
# com.apple.security.device.audio-input records silence), and every entitlement needs the usage description the system
# shows when it asks. Exceptions to the runtime (JIT, unsigned memory, library validation, DYLD variables, debugging)
# are refused here: each needs proof that a real feature fails without it, and then this list and
# docs/architecture/code-signing-and-permissions.md change together.

ENTITLEMENTS="packaging/SkyCut.entitlements"
INFO="packaging/Info.plist"
# usage description in Info.plist → the entitlement the hardened runtime needs before macOS asks for that resource
RESOURCES="NSMicrophoneUsageDescription com.apple.security.device.audio-input
NSCameraUsageDescription com.apple.security.device.camera
NSAppleEventsUsageDescription com.apple.security.automation.apple-events
NSLocationUsageDescription com.apple.security.personal-information.location
NSLocationWhenInUseUsageDescription com.apple.security.personal-information.location
NSContactsUsageDescription com.apple.security.personal-information.addressbook
NSCalendarsUsageDescription com.apple.security.personal-information.calendars
NSPhotoLibraryUsageDescription com.apple.security.personal-information.photos-library"

has_info_key() { /usr/libexec/PlistBuddy -c "Print :$1" "${INFO}" >/dev/null 2>&1; }
entitlement_value() { /usr/libexec/PlistBuddy -c "Print :$1" "${ENTITLEMENTS}" 2>/dev/null || true; }

if ! plutil -lint -s "${ENTITLEMENTS}"; then
  fail "${ENTITLEMENTS} is not a valid property list"
fi
while read -r usage entitlement; do
  if has_info_key "${usage}" && [ "$(entitlement_value "${entitlement}")" != true ]; then
    fail "${INFO} asks for ${usage} but ${ENTITLEMENTS} lacks ${entitlement}: the hardened runtime denies it without asking"
  fi
done <<<"${RESOURCES}"
KEYS="$(plutil -convert xml1 -o - "${ENTITLEMENTS}" | { grep -o '<key>[^<]*</key>' || true; } | sed -e 's/<key>//' -e 's/<\/key>//')"
if [ -z "${KEYS}" ]; then
  fail "${ENTITLEMENTS} has no entitlements: the microphone and Apple Events to Finder would be denied without asking"
fi
while read -r key; do
  [ -n "${key}" ] || continue
  USAGES="$(awk -v key="${key}" '$2 == key { print $1 }' <<<"${RESOURCES}")"
  if [ -z "${USAGES}" ]; then
    fail "${ENTITLEMENTS}: ${key} is not a resource-access entitlement; runtime exceptions need proof that a feature fails without them"
    continue
  fi
  if [ "$(entitlement_value "${key}")" != true ]; then
    fail "${ENTITLEMENTS}: ${key} must be true"
  fi
  JUSTIFIED=0
  while read -r usage; do
    if has_info_key "${usage}"; then
      JUSTIFIED=1
    fi
  done <<<"${USAGES}"
  if [ "${JUSTIFIED}" -ne 1 ]; then
    fail "${ENTITLEMENTS}: ${key} without its usage description in ${INFO} (macOS has nothing to show when it asks)"
  fi
done <<<"${KEYS}"
