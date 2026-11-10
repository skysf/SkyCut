# shellcheck shell=bash
# checks/sky-studio-wiring.sh 第 11 节（在同一个 shell 里 source，用它的 fail / line_of / code_files_with；总闸在主脚本最后）。
# 声音库（声音 PR 6）和全部权限下的长期授权（声音 PR 7，SkyCut 声音方案 4.5、5.6、9.1 第 12 项）：
#   - `consent: true`（.thisRecording）只在 SkyStudioVoiceRecordingTool 里过了 SkyStudioJobGate.voiceConsent 之后造，另一处是新建声音
#     对话框（NewVoiceModel，用户自己勾了那一句之后，声音 PR 8，第 12 节管）；`consent: "standing_grant"`（.standingGrant）只在
#     SkyStudioVoiceRecordingTool 里、问出来是 `.standing`（全部权限 + 有效的长期授权）时用；
#   - 长期授权的三个请求（GET / POST / DELETE /voices/consent-grant）只经 SkyStudioVoiceStanding；
#   - 改权限模式的地方（设置那一节、set_settings）改完都告诉 SkyStudioVoiceStanding（打开记、关掉撤）；设置里选全部权限先弹说明，
#     只有「同意并打开」才写 Store；读到 / 存下 Key 时补记升级前就开着全部权限的那一条；
#   - `/voices` 的路径只在 SkyStudioVoiceAPI 里拼；源码和测试数据里没有 MiniMax voice_id 的样子（`Voice` + 一长串十六进制）；
#   - 声音库的几个工具、长期授权问用户只经 SkyStudioJobGate（不另开确认入口）；声音库的声音不退本机。

VOICE_DIR="Sources/SrtFlow/SkyStudio"
VOICE_RECORDING="${VOICE_DIR}/SkyStudioVoiceRecordingTool.swift"
VOICE_LIBRARY_DTO="${VOICE_DIR}/SkyStudioVoiceLibrary.swift"
VOICE_API_FILE="${VOICE_DIR}/SkyStudioVoiceAPI.swift"
VOICE_START_FILE="${VOICE_DIR}/SkyStudioVoiceoverStart.swift"
VOICE_STANDING="${VOICE_DIR}/SkyStudioVoiceStanding.swift"
ACCESS_SECTION="Sources/SrtFlow/AIAccessSettingsSection.swift"
ACCESS_STORE="Sources/SrtFlow/AIAccessStore.swift"
# 新建声音对话框（声音 PR 8）：第 12 节（voice-library-ui.sh）也用这个变量。
NEW_VOICE_MODEL="Sources/SrtFlow/VoiceLibrary/NewVoiceModel.swift"
for file in "${VOICE_RECORDING}" "${VOICE_LIBRARY_DTO}" "${VOICE_API_FILE}" "${VOICE_START_FILE}" "${VOICE_STANDING}" "${ACCESS_SECTION}" \
            "${ACCESS_STORE}" "${ACCOUNT}" "${NEW_VOICE_MODEL}"; do
  [ -f "${file}" ] || fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"
done

# 授权的两种写法都只在建声音的工具里、过了 voiceConsent 之后造。
consent_makers="$(code_files_with '\.thisRecording\(' | grep -vxF "${VOICE_LIBRARY_DTO}" | LC_ALL=C sort -u | tr '\n' ' ' || true)"
expected_makers="$(printf '%s\n' "${VOICE_RECORDING}" "${NEW_VOICE_MODEL}" | LC_ALL=C sort | tr '\n' ' ')"
[ "${consent_makers}" = "${expected_makers}" ] \
  || fail "consent: true（SkyStudioVoiceConsent.thisRecording）只许在 ${VOICE_RECORDING}（确认码点过头）和 ${NEW_VOICE_MODEL}（用户自己勾了那一句）里造：${consent_makers:-没有}"
standing_makers="$(code_files_with '\.standingGrant\b' | grep -vxF "${VOICE_LIBRARY_DTO}" | sort -u || true)"
[ "${standing_makers}" = "${VOICE_RECORDING}" ] \
  || fail "consent: \"standing_grant\"（.standingGrant）只许在 ${VOICE_RECORDING} 里用：${standing_makers:-没有}"
# 第一处出现在第几行，注释行不算（文件头的说明里会提到这些名字）。
code_line_of() { { grep -nF -- "$1" "$2" | grep -vE '^[0-9]+:[[:space:]]*//' || true; } | head -1 | cut -d: -f1; }
gate_line="$(code_line_of 'SkyStudioJobGate.voiceConsent(' "${VOICE_RECORDING}")"
consent_line="$(code_line_of '.thisRecording(' "${VOICE_RECORDING}")"
standing_line="$(code_line_of '.standingGrant' "${VOICE_RECORDING}")"
if [ -z "${gate_line}" ] || [ -z "${consent_line}" ] || [ "${gate_line}" -ge "${consent_line}" ] \
   || [ -z "${standing_line}" ] || [ "${gate_line}" -ge "${standing_line}" ]; then
  fail "${VOICE_RECORDING}：consent: true / standing_grant 要在 SkyStudioJobGate.voiceConsent 放行之后才造"
fi
standing_use="$(grep -F '.standingGrant' "${VOICE_RECORDING}" | grep -v '^ *//' || true)"
grep -qF 'ask == .standing ? .standingGrant' <<<"${standing_use}" \
  || fail "${VOICE_RECORDING}：standing_grant 只在问出来是 .standing（全部权限 + 有效的长期授权）时用"

# 长期授权的三个请求只经 SkyStudioVoiceStanding。
grant_callers="$(code_files_with '(voice|recordVoice|revokeVoice)ConsentGrant\(' | grep -vxF "${VOICE_API_FILE}" | sort -u || true)"
[ "${grant_callers}" = "${VOICE_STANDING}" ] \
  || fail "长期授权（/voices/consent-grant）只许经 ${VOICE_STANDING} 读写：${grant_callers:-没有}"

# 改权限模式的地方改完都告诉 SkyStudioVoiceStanding（打开记、关掉撤）；设置里只有「同意并打开」写全部权限。
# AIAccessStore 的写（设置那一节拿着它叫 access）；优化媒体菜单的 coordinator.setMode 是另一回事。
mode_writers="$(code_files_with '(AIAccessStore\.shared|access)\.setMode\(' | grep -vxF "${ACCESS_STORE}" | sort -u || true)"
mode_hooks="$(code_files_with 'SkyStudioVoiceStanding\.shared\.modeChanged\(|standing\.modeChanged\(' | sort -u || true)"
[ -n "${mode_writers}" ] && [ "${mode_writers}" = "${mode_hooks}" ] \
  || fail "改权限模式的文件（${mode_writers:-没有}）和改完告诉长期授权的文件（${mode_hooks:-没有}）要对得上"
agree_line="$(line_of 'private func agree(' "${ACCESS_SECTION}")"
full_line="$(line_of 'setMode(.full)' "${ACCESS_SECTION}")"
if [ -z "${agree_line}" ] || [ -z "${full_line}" ] || [ "${full_line}" -lt "${agree_line}" ] \
   || ! grep -qF 'FullAccessConsentSheet(' "${ACCESS_SECTION}"; then
  fail "${ACCESS_SECTION}：选全部权限先弹 FullAccessConsentSheet，只有「同意并打开」（agree）才写 Store"
fi
# 选的那一下（choose）：全部权限那一支先弹说明、直接 return，之后才轮到别的模式写 Store。
choose_body="$(sed -n '/private func choose(/,/^    }/p' "${ACCESS_SECTION}")"
choose_full="$(grep -nF 'if mode == .full {' <<<"${choose_body}" | head -1 | cut -d: -f1 || true)"
choose_sheet="$(grep -nF 'explainingFullAccess = true' <<<"${choose_body}" | head -1 | cut -d: -f1 || true)"
choose_write="$(grep -nF 'setMode(' <<<"${choose_body}" | head -1 | cut -d: -f1 || true)"
if [ -z "${choose_full}" ] || [ -z "${choose_sheet}" ] || [ -z "${choose_write}" ] \
   || [ "${choose_full}" -ge "${choose_sheet}" ] || [ "${choose_sheet}" -ge "${choose_write}" ]; then
  fail "${ACCESS_SECTION}：choose 里选全部权限要先弹说明（explainingFullAccess = true）再 return，不许先写 Store"
fi
[ "$(grep -cF 'SkyStudioVoiceStanding.shared.migrateIfNeeded(key: key)' "${ACCOUNT}" || true)" -eq 2 ] \
  || fail "${ACCOUNT}：读到 Key、存下 Key 时都要补记升级前就开着全部权限的那一条（migrateIfNeeded 两处）"

voice_paths="$(code_files_with 'SkyStudioVoicePath\.' | sort -u || true)"
[ "${voice_paths}" = "${VOICE_API_FILE}" ] || fail "/voices 的路径只许在 ${VOICE_API_FILE} 里拼：${voice_paths:-没有}"
provider_ids="$(grep -rEln 'Voice[0-9a-fA-F]{16,}' Sources checks/SkyStudio checks/VoiceRecovery checks/MCP || true)"
[ -z "${provider_ids}" ] || fail "源码和测试数据里不许有 MiniMax voice_id 的样子（服务商的 id 永远不出服务器，约定第 3 条）：${provider_ids}"
for tool in SkyStudioVoiceLibraryTool SkyStudioVoiceRecordingTool SkyStudioVoiceDesignTool SkyStudioVoiceOneTimeStep SkyStudioVoiceFallbackFee \
            SkyStudioVoiceStanding; do
  file="${VOICE_DIR}/${tool}.swift"
  [ -f "${file}" ] || { fail "找不到 ${file}"; continue; }
  stripped="$(sed 's,//.*,,' "${file}")"
  if grep -qF 'AIConfirmations.shared' <<<"${stripped}"; then
    fail "${file}：声音库、长期授权问用户只经 SkyStudioJobGate（voiceConsent / voiceOneTime / voiceDeletion），不另开确认入口"
  fi
done
library_lines="$(grep -cF 'isLibrary' "${VOICE_START_FILE}" || true)"
library_throws="$(grep -F 'isLibrary' "${VOICE_START_FILE}" | grep -cF 'throw AIToolError' || true)"
if [ "${library_lines}" -lt 3 ] || [ "${library_lines}" != "${library_throws}" ]; then
  fail "${VOICE_START_FILE}：认出声音库声音（isLibrary）的每一处都要报错、不许退本机（4.3）：${library_throws}/${library_lines}"
fi
