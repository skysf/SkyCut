#!/usr/bin/env bash
# checks/sky-studio-wiring.sh 的一节：变声（声音 PR 9，SkyCut 声音方案 4.8、4.9、5.5）。
#
# **不单独跑**：由 sky-studio-wiring.sh 用 `source` 装进来（在总闸之前），共用它的 fail / code_files_with / line_of。
# 行为由 scripts/check-voice-recovery.sh 的 VoiceChangeChecks（真 App 对象）钉；这里钉接线：
#   - **AI 的 change_voice 和片段右键的面板是同一条路**：截声音只经 VoiceChangeSource.prepare、报价用的那一份只经 VoiceChangeOrder.draft、
#     起任务只经 VoiceChangeOrder.start（VoiceChangeJob 别处不许造）；
#   - **花钱只判每日硬预算、先过预算再起任务**（两处都是 reserveWithoutAsking 在 start 之前）；变声不是一次性费用，两种权限模式都不问：
#     这一摊里不用确认码、不弹钥匙串框、不直接动积分的账；
#   - **落地是一步撤销**：VoiceChangeJob 里恰好一次 perform、包在 AIUndoGrouping.step 里（checks/MCP/router-wiring.sh 的异步落账扫描
#     钉着「上一行是 step」），落地的规则只有 VoiceChangeLanding.land 一份；路由只起任务、不在外面包撤销分组；
#   - 上传用途只写在 SkyStudioVoiceUpload 一处；截声音的阻塞读只在 MediaReadQueue 上；
#   - 时间线上的块只往 VoiceChangeActivity 里写一个目标（不读工程、不做 IO），面板由挂在检查器底下的 VoiceChangePresenter 摆；
#     面板的视图不读工程、不订阅播放器的时钟，声音选择器用共用的 VoicePickerView。
# 长期约束见 docs/architecture/voice-library.md 第十一节。

CHANGE_DIR="Sources/SrtFlow/VoiceChange"
CHANGE_TOOL="${CHANGE_DIR}/VoiceChangeTool.swift"
CHANGE_MODEL="${CHANGE_DIR}/VoiceChangePanelModel.swift"
CHANGE_ORDER="${CHANGE_DIR}/VoiceChangeOrder.swift"
CHANGE_JOB="${CHANGE_DIR}/VoiceChangeJob.swift"
CHANGE_SOURCE="${CHANGE_DIR}/VoiceChangeSource.swift"
CHANGE_LANDING="${CHANGE_DIR}/VoiceChangeLanding.swift"
CHANGE_PANEL="${CHANGE_DIR}/VoiceChangePanel.swift"
for file in "${CHANGE_TOOL}" "${CHANGE_MODEL}" "${CHANGE_ORDER}" "${CHANGE_JOB}" "${CHANGE_SOURCE}" "${CHANGE_LANDING}" "${CHANGE_PANEL}"; do
  [ -f "${file}" ] || fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"
done
for file in "${CHANGE_TOOL}" "${CHANGE_MODEL}"; do
  grep -qF 'VoiceChangeSource.prepare(' "${file}" || fail "${file}：截这一段的声音只经 VoiceChangeSource.prepare（AI 和面板同一条路）"
  grep -qF 'VoiceChangeOrder.draft(' "${file}" || fail "${file}：报价用的那一份只经 VoiceChangeOrder.draft"
  grep -qF 'VoiceChangeOrder.spokenLanguage(' "${file}" || fail "${file}：这段说什么语言只经 VoiceChangeOrder.spokenLanguage（收费之前）"
  reserve_line="$(line_of 'SkyStudioJobGate.reserveWithoutAsking(' "${file}")"
  start_line="$(line_of 'VoiceChangeOrder.start(' "${file}")"
  if [ -z "${reserve_line}" ] || [ -z "${start_line}" ] || [ "${reserve_line}" -ge "${start_line}" ]; then
    fail "${file}：要先过每日硬预算（SkyStudioJobGate.reserveWithoutAsking）再起任务（VoiceChangeOrder.start）"
  fi
done
quote_line="$(line_of '.quote(draft' "${CHANGE_TOOL}")"
gate_line="$(line_of 'SkyStudioJobGate.reserveWithoutAsking(' "${CHANGE_TOOL}")"
if [ -z "${quote_line}" ] || [ -z "${gate_line}" ] || [ "${quote_line}" -ge "${gate_line}" ]; then
  fail "${CHANGE_TOOL}：先问 /quote，再照报价过每日硬预算"
fi
change_jobs="$(code_files_with 'VoiceChangeJob\(' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${change_jobs}" = "${CHANGE_ORDER} " ] || fail "变声的任务只许在 ${CHANGE_ORDER} 里起（AI 和面板共用）：${change_jobs:-没有}"
change_files="$(find "${CHANGE_DIR}" -name '*.swift' | LC_ALL=C sort)"
[ -n "${change_files}" ] || fail "${CHANGE_DIR} 里一个文件都没有（扫空 = 假绿）"
while IFS= read -r file; do
  [ -n "${file}" ] || continue
  stripped="$(sed 's,//.*,,' "${file}")"
  if grep -qE 'AIConfirmations\.shared|SkyStudioJobGate\.(decide|voiceOneTime|voiceConsent)\(|\.prompting|SkyStudioSpendStore\.shared\.(record|refund)\(|NSAlert' <<<"${stripped}"; then
    fail "${file}：变声只判每日硬预算，不用确认码、不弹钥匙串框和模态框、不直接动积分的账（记账只经 SkyStudioJobGate / SkyStudioHeldCredits）"
  fi
done <<<"${change_files}"
# 落地：一次 perform、一份规则。
if [ "$(grep -cF 'VoiceChangeLanding.land(' "${CHANGE_JOB}" || true)" -ne 1 ] \
   || [ "$(sed 's,//.*,,' "${CHANGE_JOB}" | grep -c '\.perform' || true)" -ne 1 ]; then
  fail "${CHANGE_JOB}：落地恰好一次 perform、只调一次 VoiceChangeLanding.land（静音 + 两条新轨 + 两段新音频 + 链接是一步撤销）"
fi
landers="$(code_files_with 'VoiceChangeLanding\.land\(' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${landers}" = "${CHANGE_JOB} " ] || fail "变声的落地只许从 ${CHANGE_JOB} 调（规则只有 VoiceChangeLanding.land 一份）：${landers:-没有}"
if grep -qE 'registerUndo|\.perform' <<<"$(sed 's,//.*,,' "${CHANGE_LANDING}")"; then
  fail "${CHANGE_LANDING}：落地的规则是纯值，撤销由调用方（VoiceChangeJob）一次包住"
fi
grep -qF 'case .changeVoice: return try await VoiceChangeTool.change(args, project)' Sources/SrtFlow/AIToolRouter.swift \
  || fail "路由里 change_voice 只起任务（落地那一下在任务里自己包 AIUndoGrouping.step，路由不包）"
# 上传用途、阻塞读。
grep -qF 'SkyStudioVoiceUpload.conversionSourcePurpose' "${CHANGE_JOB}" || fail "${CHANGE_JOB}：上传用途用 SkyStudioVoiceUpload.conversionSourcePurpose"
purposes="$(code_files_with '"voice_convert_source"' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${purposes}" = "${VOICE_DIR}/SkyStudioVoiceRequests.swift " ] || fail "voice_convert_source 这个用途只写在 SkyStudioVoiceRequests.swift 一处：${purposes:-没有}"
grep -qF 'MediaReadQueue.run(on: MediaReadQueue.analysis)' "${CHANGE_SOURCE}" || fail "${CHANGE_SOURCE}：截声音的阻塞读只在 MediaReadQueue.analysis 上"
if grep -qF 'copyNextSampleBuffer' "${CHANGE_SOURCE}"; then
  fail "${CHANGE_SOURCE}：读采样只经 VoiceReferenceReader（和参考录音同一份读法），这里不另写读取循环"
fi
# 界面：块只交目标，面板挂在检查器底下，视图不读工程。
BLOCK="Sources/SrtFlow/VideoEditTimelineClipBlock.swift"
grep -qF 'VoiceChangeActivity.shared.present(panelFor: clip.id)' "${BLOCK}" || fail "${BLOCK}：右键「换成我的声音…」只往 VoiceChangeActivity 里写一个目标"
if grep -qE 'VoiceChange(Job|Order|Source|PanelModel|Tool)' <<<"$(sed 's,//.*,,' "${BLOCK}")"; then
  fail "${BLOCK}：时间线上的块不起任务、不读文件、不造面板的模型"
fi
grep -qF '.background(VoiceChangePresenter(project: project).equatable())' Sources/SrtFlow/VideoEditInspector.swift \
  || fail "VoiceChangePresenter 要挂在检查器底下、构造处套 .equatable()（检查器每重算一次不重算它）"
if grep -qE 'VideoEditProject|PlayerClock|OpenProjects' <<<"$(sed 's,//.*,,' "${CHANGE_PANEL}")"; then
  fail "${CHANGE_PANEL}：变声面板的视图不读工程、不订阅播放器的时钟（工程只在 VoiceChangePanelModel 的方法里读）"
fi
grep -qF 'VoicePickerView(selection:' "${CHANGE_PANEL}" || fail "${CHANGE_PANEL}：目标声音用共用的声音选择器 VoicePickerView，不另写"
