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
#   - 界面不用确认码、Key 只静默读、不直接动积分的账；声音库的视图不读工程、不订阅播放器的时钟；
#   - 录音的语言识别只有一份（SpokenLanguageProbe ← VoiceSampleLanguage）：对话框拿它预选，manage_voices 没给 language 时拿它定
#     （给了就照给的、不识别；在参考录音做好之后、问授权之前）。
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

# manage_voices 没给 language 时的识别（2026-11-11，docs/bugfixes/2026-11-11-manage-voices-language-required.md）：和新建声音对话框
# 同一份（VoiceSampleLanguage.detect → SpokenLanguageProbe），不另写一份候选 / 裁决；AI 给了就照它的、不识别；识别在参考录音做好之后、
# 问授权之前（识别不出来时什么都不问、不传）。行为由 check-voice-recovery 的 LibraryLanguageChecks 钉。
VOICE_RECORDING_LANGUAGE="${VOICE_DIR}/SkyStudioVoiceRecordingLanguage.swift"
VOICE_SAMPLE_LANGUAGE="${VOICE_UI_DIR}/VoiceSampleLanguage.swift"
VOICE_LIBRARY_SERVICES="${VOICE_DIR}/SkyStudioVoiceServices.swift"
VOICE_HARVESTER="Sources/SrtFlow/SubtitleGen/TranscriptHarvester.swift"
for file in "${VOICE_RECORDING_LANGUAGE}" "${VOICE_SAMPLE_LANGUAGE}" "${VOICE_LIBRARY_SERVICES}" "${VOICE_HARVESTER}"; do
  [ -f "${file}" ] || fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"
done
probe_users="$(code_files_with 'SpokenLanguageProbe\.' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
expected_probe_users="$(printf '%s\n' "${VOICE_HARVESTER}" "${VOICE_SAMPLE_LANGUAGE}" | LC_ALL=C sort | tr '\n' ' ')"
[ "${probe_users}" = "${expected_probe_users}" ] \
  || fail "这段声音说的是哪种语言只有 SpokenLanguageProbe 一份，只许生成字幕（${VOICE_HARVESTER}）和参考录音（${VOICE_SAMPLE_LANGUAGE}）调：${probe_users:-没有}"
sample_detectors="$(code_files_with 'VoiceSampleLanguage\.detect\(' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
expected_sample_detectors="$(printf '%s\n' "${VOICE_LIBRARY_SERVICES}" "${NEW_VOICE_MODEL}" | LC_ALL=C sort | tr '\n' ' ')"
[ "${sample_detectors}" = "${expected_sample_detectors}" ] \
  || fail "参考录音的语言识别只许两个入口用：对话框（${NEW_VOICE_MODEL}）和 manage_voices（${VOICE_LIBRARY_SERVICES} 的 detectLanguage；变声也只经它，不另调一遍）：${sample_detectors:-没有}"
grep -qF 'detect: services.detectLanguage' "${VOICE_RECORDING}" \
  || fail "${VOICE_RECORDING}：没给 language 时识别只经 services.detectLanguage（默认就是对话框那一份）"
recording_code="$(sed 's,//.*,,' "${VOICE_RECORDING}")"
if grep -qE 'requiredString\("language"\)' <<<"${recording_code}"; then
  fail "${VOICE_RECORDING}：language 是可选的（声音方案 4.6），不许再当必填"
fi
sample_line="$(grep -nF 'VoiceReferenceSample.prepare(' "${VOICE_RECORDING}" | head -1 | cut -d: -f1 || true)"
resolve_line="$(grep -nF 'SkyStudioVoiceRecordingLanguage.resolve(' "${VOICE_RECORDING}" | head -1 | cut -d: -f1 || true)"
ask_line="$(grep -nF 'SkyStudioJobGate.voiceConsent(' "${VOICE_RECORDING}" | head -1 | cut -d: -f1 || true)"
if [ -z "${sample_line}" ] || [ -z "${resolve_line}" ] || [ -z "${ask_line}" ] \
  || [ "${sample_line}" -ge "${resolve_line}" ] || [ "${resolve_line}" -ge "${ask_line}" ]; then
  fail "${VOICE_RECORDING}：语言要在参考录音做好之后（在它上面识别）、问授权之前定下来（识别不出来时什么都不问、不传）"
fi
language_code="$(sed 's,//.*,,' "${VOICE_RECORDING_LANGUAGE}")"
if grep -qE 'SpokenLanguageProbe|SpeechTranscriptionService|SubtitleLanguageDetection|NLLanguageRecognizer' <<<"${language_code}"; then
  fail "${VOICE_RECORDING_LANGUAGE}：这里不许自己识别（另写一份候选 / 裁决），只调传进来的那一个"
fi
given_line="$(grep -nF 'if let given { return' "${VOICE_RECORDING_LANGUAGE}" | head -1 | cut -d: -f1 || true)"
detect_line="$(grep -nF 'await detect(' "${VOICE_RECORDING_LANGUAGE}" | head -1 | cut -d: -f1 || true)"
if [ -z "${given_line}" ] || [ -z "${detect_line}" ] || [ "${given_line}" -ge "${detect_line}" ]; then
  fail "${VOICE_RECORDING_LANGUAGE}：AI 给了 language 就照它的，要在识别之前就回去（不识别、不拿识别的结果盖掉）"
fi
