#!/usr/bin/env bash
# checks/sky-studio-wiring.sh 的一节：声音库的收费单只下一次、账只记一次（2026-11-11 深度审查 #362 / #367 之后）。
#
# **不单独跑**：由 sky-studio-wiring.sh 用 `source` 装进来（在总闸之前），共用它的 fail / line_of / code_files_with 和路径变量
# （VOICE_DIR、VOICE_RECORDING、NEW_VOICE_MODEL）。行为由 scripts/check-voice-recovery.sh 的 LibraryOrderChecks / FallbackFeeChecks 钉；
# 这里钉接线（案例：docs/bugfixes/2026-11-11-design-voice-ordered-twice.md；长期约束：docs/architecture/voice-library.md 第十节）：
#   - 设计声音的对话框一份报价只下一单：`design()` 先看 `ordered`，下单那一刻置上、在起任务之前；按钮跟着灰；
#     这一份订单的 idempotency_key 在问价时就定了，交的时候不另起；
#   - 同一件事只开一单（SkyStudioVoiceLibraryJob.running）：任务自己起手先看；建 MiniMax 版的两处在过闸（问 / 记账）之前先看；
#   - 旁白中途那笔一次性费用的问题，在 Sky Studio 受理了建的那一单之后才清（onAccepted），不在记上账那一刻清；
#   - 没做成的单把服务器的原因和改过的价带进 get_job；
#   - 每日预算的规矩只有 SkyStudioSpendStore.decide 一份，对话框不另抄；
#   - 授权那句升了版本（consent_outdated）：两个入口都忘掉目录、用新的再问；
#   - 建声音时整份读录音在后台队列上（make）；声音库的临时文件夹只在 VoiceLibraryTemp 起名、启动时清残留，
#     转写那一处的清理不许带上它们（生成字幕开跑时对话框可能正开着）。

ORDER_DESIGN_MODEL="Sources/SrtFlow/VoiceLibrary/DesignVoiceModel.swift"
ORDER_DESIGN_SHEET="Sources/SrtFlow/VoiceLibrary/DesignVoiceSheet.swift"
ORDER_DESIGN="${VOICE_DIR}/SkyStudioVoiceDesignOrder.swift"
ORDER_JOB="${VOICE_DIR}/SkyStudioVoiceLibraryJob.swift"
ORDER_ONE_TIME="${VOICE_DIR}/SkyStudioVoiceOneTimeStep.swift"
ORDER_FALLBACK="${VOICE_DIR}/SkyStudioVoiceFallbackFee.swift"
ORDER_SUBMISSION="${VOICE_DIR}/SkyStudioVoiceRecordingSubmission.swift"
ORDER_TEMP="Sources/SrtFlow/VoiceLibrary/VoiceLibraryTemp.swift"
for file in "${ORDER_DESIGN_MODEL}" "${ORDER_DESIGN_SHEET}" "${ORDER_DESIGN}" "${ORDER_JOB}" "${ORDER_ONE_TIME}" "${ORDER_FALLBACK}" \
            "${ORDER_SUBMISSION}" "${ORDER_TEMP}"; do
  [ -f "${file}" ] || fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"
done

# 一份报价只下一单。
latch_guard="$(line_of 'guard !ordered' "${ORDER_DESIGN_MODEL}")"
latch_set="$(line_of 'ordered = true' "${ORDER_DESIGN_MODEL}")"
order_start="$(line_of 'SkyStudioVoiceDesignOrder.start(' "${ORDER_DESIGN_MODEL}")"
if [ -z "${latch_guard}" ] || [ -z "${latch_set}" ] || [ -z "${order_start}" ] || [ "${latch_guard}" -ge "${latch_set}" ] \
   || [ "${latch_set}" -ge "${order_start}" ]; then
  fail "${ORDER_DESIGN_MODEL}：design() 要先看 ordered（guard !ordered）、起任务之前置上（ordered = true），一份报价只下一单"
fi
grep -E '\.disabled\(' "${ORDER_DESIGN_SHEET}" | grep -cF 'model.ordered' >/dev/null \
  || fail "${ORDER_DESIGN_SHEET}：下过单「设计」按钮要灰着（.disabled(… || model.ordered)）"
design_code="$(sed 's,//.*,,' "${ORDER_DESIGN}")"
if grep -qE 'UUID\(|idempotencyKey *=' <<<"${design_code}"; then
  fail "${ORDER_DESIGN}：订单的 idempotency_key 在问价时就定了（draft 带着），交的时候不许另起一个"
fi
grep -qF 'identity: SkyStudioVoiceLibraryJob.designIdentity(draft)' "${ORDER_DESIGN}" \
  || fail "${ORDER_DESIGN}：设计的任务按这一份订单认（designIdentity(draft)），同一份再交回开着的那一单"

# 同一件事只开一单。
job_running="$(line_of 'if let existing = Self.running(identity)' "${ORDER_JOB}")"
job_start="$(line_of 'AIJobs.shared.start(kind' "${ORDER_JOB}")"
if [ -z "${job_running}" ] || [ -z "${job_start}" ] || [ "${job_running}" -ge "${job_start}" ]; then
  fail "${ORDER_JOB}：start() 要先看同一件事有没有开着的那一单（Self.running(identity)），有就回它、预留退回"
fi
for file in "${ORDER_ONE_TIME}" "${ORDER_FALLBACK}"; do
  seen="$(line_of 'SkyStudioVoiceLibraryJob.running(identity)' "${file}")"
  gate="$(line_of 'SkyStudioJobGate.voiceOneTime(' "${file}")"
  if [ -z "${seen}" ] || [ -z "${gate}" ] || [ "${seen}" -ge "${gate}" ]; then
    fail "${file}：过闸（问 / 记账）之前先看这个声音这种语言的 MiniMax 版是不是已经在建（SkyStudioVoiceLibraryJob.running）"
  fi
  [ "$(count 'SkyStudioVoiceLibraryJob.running(identity)' "${file}")" -ge 2 ] \
    || fail "${file}：读长期授权（await）之后、过闸之前要再看一次在建的那一单（两处 running(identity)）"
done

# 费用的问题受理之后才清。
reserved_at="$(line_of 'case .reserved(let reservation):' "${ORDER_FALLBACK}")"
accepted_at="$(line_of 'enrolment.onAccepted = {' "${ORDER_FALLBACK}")"
started_at="$(line_of 'let job = enrolment.start()' "${ORDER_FALLBACK}")"
if [ -z "${reserved_at}" ] || [ -z "${accepted_at}" ] || [ -z "${started_at}" ] || [ "${reserved_at}" -ge "${accepted_at}" ] \
   || [ "${accepted_at}" -ge "${started_at}" ]; then
  fail "${ORDER_FALLBACK}：那笔费用的问题要挂在 onAccepted 上清（记上账之后、起任务之前接好）"
else
  early="$(sed -n "${reserved_at},${accepted_at}p" "${ORDER_FALLBACK}" | sed 's,//.*,,' | grep -cF 'fallbackFee = nil' || true)"
  [ "${early}" -eq 0 ] || fail "${ORDER_FALLBACK}：记上账那一刻不许清费用的问题（受理之前没做成，问题就丢了）"
fi
grep -qF 'enrolment.onFailure = {' "${ORDER_FALLBACK}" || fail "${ORDER_FALLBACK}：建的那一单没做成要说下一步（onFailure：问题还开着、改了价记新价）"
grep -qF 'static func updateFee(in file: URL' "${VOICE_DIR}/SkyStudioVoiceRecovery.swift" \
  || fail "恢复记录里那笔费用只许现读现改（SkyStudioVoiceRecovery.updateFee），不拿旧的整份记录去盖"

# 没做成的单：原因和新价进 get_job。
grep -qF 'detail: await failureDetail(error)' "${ORDER_JOB}" || fail "${ORDER_JOB}：没做成时 get_job 要带服务器的原因（failureDetail）"
grep -qF '"credits_now"' "${ORDER_JOB}" || fail "${ORDER_JOB}：price_changed 的新价要带进 get_job（credits_now）"

# 每日预算的规矩只有一份。
model_code="$(sed 's,//.*,,' "${ORDER_DESIGN_MODEL}")"
if grep -qE '0\.0005|dailyLimit' <<<"${model_code}"; then
  fail "${ORDER_DESIGN_MODEL}：超没超每日额度只问 SkyStudioSpendStore.decide，不许另抄一份（连余量一起抄的那种）"
fi
grep -qF 'spend.decide(credits:' "${ORDER_DESIGN_MODEL}" || fail "${ORDER_DESIGN_MODEL}：overLimit 要问 spend.decide(credits:)"

# 授权那句升了版本：两个入口都刷新目录再问。
for file in "${VOICE_RECORDING}" "${NEW_VOICE_MODEL}"; do
  grep -qF 'SkyStudioVoiceLibraryErrors.consentOutdated(error)' "${file}" || fail "${file}：consent_outdated 要认出来（忘掉目录、用新版本再问）"
  grep -qF 'SkyStudioCatalogCache.shared.forget()' "${file}" || fail "${file}：授权那句升了版本要忘掉 10 分钟一份的目录"
done

# 整份读录音在后台队列上；临时文件夹只在一处起名、启动时清。
callers="$(code_files_with 'SkyStudioVoiceRecordingSubmission\(file:' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${callers}" = "${ORDER_SUBMISSION} " ] \
  || fail "SkyStudioVoiceRecordingSubmission 的同步 init（整份读录音）只许它自己的 make 在后台队列上调：${callers:-没有}"
grep -qF 'MediaReadQueue.run(on: MediaReadQueue.analysis)' "${ORDER_SUBMISSION}" || fail "${ORDER_SUBMISSION}：make 要在 MediaReadQueue.analysis 上读"
namers="$(code_files_with '"SkyCut-(new-voice|voice-reference|voice-language)-' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
[ "${namers}" = "${ORDER_TEMP} " ] || fail "声音库的临时文件夹只许在 ${ORDER_TEMP} 起名（清残留照它的前缀）：${namers:-没有}"
grep -qF 'VoiceLibraryTemp.sweepResidue()' Sources/SrtFlow/SrtFlowApp.swift || fail "启动时要清声音库留下的临时文件夹（VoiceLibraryTemp.sweepResidue）"
if grep -qF 'SkyCut-' Sources/SrtFlow/SubtitleGen/AudioWindowReader.swift; then
  fail "AudioWindowReader.sweepTempResidue 每次转写开头都跑：不许带上声音库的临时文件夹（对话框可能正开着）"
fi
