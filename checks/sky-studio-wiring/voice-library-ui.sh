#!/usr/bin/env bash
# checks/sky-studio-wiring.sh 的一节：声音库的界面（声音 PR 8，SkyCut 声音方案 5.1–5.4、5.7）。
#
# **不单独跑**：由 sky-studio-wiring.sh 用 `source` 装进来（在总闸之前），共用它的 fail / code_files_with 和路径变量
# （VOICE_DIR、VOICE_RECORDING、NEW_VOICE_MODEL）。行为由 scripts/check-voice-recovery.sh 的 LibraryUIChecks 和
# scripts/check-sky-studio.sh 的 VoiceLibraryUIChecks 钉；这里钉「界面和 AI 的工具走的是同一条路，不另写一份逻辑」：
#   - `consent: true` 在对话框里只许在用户自己勾了那一句（`guard agreed else`）之后造；
#   - 参考录音只经 VoiceReferenceSample.prepare，交只经 SkyStudioVoiceRecordingSubmission（createVoice / addVoiceReference / deleteVoice
#     别处不许直接调；删除碰上存储一时不可用再发一次只有 SkyStudioVoiceDeletion 那一份）；
#   - 设计只经 SkyStudioVoiceDesignOrder，对话框按下去先过每日硬预算再起任务；
#   - 界面不用确认码、Key 只静默读、不直接动积分的账；声音库的视图不读工程、不订阅播放器的时钟。
# 长期约束见 docs/architecture/voice-library.md 第九节。

VOICE_UI_DIR="Sources/SrtFlow/VoiceLibrary"
VOICE_SUBMISSION="${VOICE_DIR}/SkyStudioVoiceRecordingSubmission.swift"
VOICE_DESIGN_ORDER="${VOICE_DIR}/SkyStudioVoiceDesignOrder.swift"
DESIGN_VOICE_MODEL="${VOICE_UI_DIR}/DesignVoiceModel.swift"
VOICE_UI_STORE="${VOICE_UI_DIR}/VoiceLibraryStore.swift"
for file in "${VOICE_SUBMISSION}" "${VOICE_DESIGN_ORDER}" "${DESIGN_VOICE_MODEL}" "${VOICE_UI_STORE}"; do
  [ -f "${file}" ] || fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"
done
agreed_line="$(grep -nF 'guard agreed else' "${NEW_VOICE_MODEL}" | head -1 | cut -d: -f1 || true)"
dialog_consent_line="$(grep -nF '.thisRecording(' "${NEW_VOICE_MODEL}" | head -1 | cut -d: -f1 || true)"
if [ -z "${agreed_line}" ] || [ -z "${dialog_consent_line}" ] || [ "${agreed_line}" -ge "${dialog_consent_line}" ]; then
  fail "${NEW_VOICE_MODEL}：consent: true 要在用户勾了授权那一句（guard agreed else）之后才造"
fi
grep -qF 'VoiceReferenceSample.prepare(' "${NEW_VOICE_MODEL}" || fail "${NEW_VOICE_MODEL}：参考录音只经 VoiceReferenceSample.prepare（现录的也过这一遍）"
grep -qF 'SkyStudioVoiceRecordingSubmission.make(' "${NEW_VOICE_MODEL}" || fail "${NEW_VOICE_MODEL}：建声音 / 加录音只经 SkyStudioVoiceRecordingSubmission"
grep -qF 'SkyStudioVoiceRecordingSubmission.make(' "${VOICE_RECORDING}" || fail "${VOICE_RECORDING}：AI 的建声音 / 加录音也只经 SkyStudioVoiceRecordingSubmission"
senders="$(code_files_with '\.(createVoice|addVoiceReference|deleteVoice)\(' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${senders}" = "${VOICE_SUBMISSION} " ] \
  || fail "建声音 / 加录音 / 删声音的请求只许从 ${VOICE_SUBMISSION} 发（界面和 AI 共用，删除的再发一次只有那一份）：${senders:-没有}"
grep -qF 'SkyStudioVoiceDeletion.run(' "${VOICE_UI_STORE}" || fail "${VOICE_UI_STORE}：界面的删除只经 SkyStudioVoiceDeletion"
grep -qF 'SkyStudioVoiceDeletion.run(' "${VOICE_DIR}/SkyStudioVoiceLibraryTool.swift" || fail "manage_voices 的删除只经 SkyStudioVoiceDeletion"
grep -qF 'SkyStudioVoiceDesignOrder.draft(' "${DESIGN_VOICE_MODEL}" || fail "${DESIGN_VOICE_MODEL}：设计的核对只经 SkyStudioVoiceDesignOrder.draft"
grep -qF 'SkyStudioVoiceDesignOrder.draft(' "${VOICE_DIR}/SkyStudioVoiceDesignTool.swift" || fail "manage_voices design 的核对只经 SkyStudioVoiceDesignOrder.draft"
reserve_line="$(grep -nF 'SkyStudioJobGate.reserveWithoutAsking(' "${DESIGN_VOICE_MODEL}" | head -1 | cut -d: -f1 || true)"
start_line="$(grep -nF 'SkyStudioVoiceDesignOrder.start(' "${DESIGN_VOICE_MODEL}" | head -1 | cut -d: -f1 || true)"
if [ -z "${reserve_line}" ] || [ -z "${start_line}" ] || [ "${reserve_line}" -ge "${start_line}" ]; then
  fail "${DESIGN_VOICE_MODEL}：按下「设计」要先过每日硬预算（SkyStudioJobGate.reserveWithoutAsking）再起任务（SkyStudioVoiceDesignOrder.start）"
fi
design_jobs="$(code_files_with 'kind: \.voiceDesign' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${design_jobs}" = "${VOICE_DESIGN_ORDER} " ] || fail "设计声音的任务只许在 ${VOICE_DESIGN_ORDER} 里起：${design_jobs:-没有}"
voice_ui_files="$(find "${VOICE_UI_DIR}" -name '*.swift' | LC_ALL=C sort)"
[ -n "${voice_ui_files}" ] || fail "${VOICE_UI_DIR} 里一个文件都没有（扫空 = 假绿）"
while IFS= read -r file; do
  [ -n "${file}" ] || continue
  stripped="$(sed 's,//.*,,' "${file}")"
  if grep -qE 'AIConfirmations\.shared|\.prompting|SkyStudioSpendStore\.shared\.(record|refund)\(' <<<"${stripped}"; then
    fail "${file}：声音库的界面不用确认码、不弹钥匙串框、不直接动积分的账（对话框上的按钮就是确认；记账只经 SkyStudioJobGate）"
  fi
  # 视图（有 body 的文件）：不读工程、不订阅播放器的时钟（SkyCut 声音方案 5.7）。
  if grep -qF 'var body: some View' <<<"${stripped}"; then
    if grep -qE 'VideoEditProject|PlayerClock|OpenProjects' <<<"${stripped}"; then
      fail "${file}：声音库的视图不读工程、不订阅播放器的时钟"
    fi
  fi
done <<<"${voice_ui_files}"
