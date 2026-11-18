#!/usr/bin/env bash
# 扫描守卫：一次只能做一个的活（导出、转写 / 生成字幕、翻译），AI 起的排队（AIWorkQueue，2026-10-17 AI 多开方案板 6、K 节）。
#
# 几个子代理剪几个工程时，以前一撞上「已经在导 / 在转写 / 在翻译」就报错、自己轮询重试；现在排队、回任务号、get_job 报
# status queued 和 queue_position。这几条只能在源码层面钉住（AIWorkQueue 和那几个工具都是 App 里的 @MainActor 类型，自检编不动）：
#   1. 四个入口（export_video、transcribe、generate_subtitles、translate_subtitles）都经 `AIWorkQueue.shared.submit`，不再回「已经在做」；
#   2. 它们的取消都经 `AIQueuedWork.cancel`：还在排就从队里拿掉，开始了才去停导出器 / 转写 / 翻译 —— 不然 cancel_job 排着的那个会把
#      正在做的（别人的）那个停掉；
#   3. get_job 在排队时报 queued 和 queue_position（AIJobs.json 先问队列）；
#   4. 一条道上 AI 起的那个没做完就不算空（`laneIsFree` 先看 active，再看那件东西）：翻译起步是异步的，光看宿主会接连起两个；
#   5. 排着的几个导出各占各的文件名（reservedOutputs）。Since 2026-11-19: picked and reserved in one step after the listing
#      (AIExportDestination), and the video never replaces a file (ExportTarget.newFile).
#
# 用法：checks/ai-work-queue-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

QUEUE="Sources/SrtFlow/AIWorkQueue.swift"
EXPORT="Sources/SrtFlow/AIExportTools.swift"
TRANSCRIBE="Sources/SrtFlow/AITranscribeTool.swift"
SUBTITLES="Sources/SrtFlow/AISubtitleTools.swift"
JOBS="Sources/SrtFlow/AIJobs.swift"
for file in "${QUEUE}" "${EXPORT}" "${TRANSCRIBE}" "${SUBTITLES}" "${JOBS}"; do
  [ -f "${file}" ] || { echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2; exit 1; }
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
count() { grep -c -- "$1" "$2" || true; }

# 1. 都经队列，不再回「已经在做」。
[ "$(count 'AIWorkQueue.shared.submit(.export, jobID: job.id)' "${EXPORT}")" -eq 1 ] || fail "${EXPORT}：export_video 没经 AIWorkQueue 排队"
[ "$(count 'AIWorkQueue.shared.submit(.transcription, jobID: job.id)' "${TRANSCRIBE}")" -eq 1 ] || fail "${TRANSCRIBE}：transcribe 没经 AIWorkQueue 排队"
[ "$(count 'AIWorkQueue.shared.submit(.transcription, jobID: job.id)' "${SUBTITLES}")" -eq 1 ] || fail "${SUBTITLES}：generate_subtitles 没经 AIWorkQueue 排队"
[ "$(count 'AIWorkQueue.shared.submit(.translation, jobID: job.id)' "${SUBTITLES}")" -eq 1 ] || fail "${SUBTITLES}：translate_subtitles 没经 AIWorkQueue 排队"
if grep -nE 'already (running|being generated|transcribing)' "${EXPORT}" "${TRANSCRIBE}" "${SUBTITLES}"; then
  fail "又回「已经在做了」：一次一个的活要排队（AIWorkQueue），不是叫 AI 自己重试"
fi
if grep -nE 'guard !(exporter\.isExporting|task\.isRunning)' "${EXPORT}" "${TRANSCRIBE}" "${SUBTITLES}"; then
  fail "工具里又先看「占着没有」就拒绝：占着就排队"
fi

# 2. 取消：排着的拿掉，开始了的才停。
[ "$(count 'work.cancel(' "${EXPORT}")" -eq 1 ] && [ "$(count 'work.cancel(' "${TRANSCRIBE}")" -eq 1 ] && [ "$(count 'work.cancel(' "${SUBTITLES}")" -eq 2 ] \
  || fail "取消要经 AIQueuedWork.cancel（排着的从队里拿掉；开始了才去停），四个入口各一处"
CANCEL_BODY="$(awk '/    func cancel\(withdrawn/,/^    \}/' "${QUEUE}")"
grep -q 'if AIWorkQueue.shared.withdraw(job.id) {' <<<"${CANCEL_BODY}" && grep -q '} else if started {' <<<"${CANCEL_BODY}" \
  || fail "${QUEUE}：AIQueuedWork.cancel 要先从队里拿掉、开始了的才停（不然会停掉正在做的别人的那个）"

# 3. get_job 报排队。
grep -q 'if job.status == .running, let position = AIWorkQueue.shared.position(of: job.id) {' "${JOBS}" \
  && grep -q 'object\["queue_position"\]' "${JOBS}" || fail "${JOBS}：get_job 在排队时要报 status queued 和 queue_position"

# 4. 一条道上 AI 起的那个没做完就不算空。
FREE_BODY="$(awk '/    private func laneIsFree\(/,/^    \}/' "${QUEUE}")"
grep -q 'if let id = active\[lane\], AIJobs.shared.job(id)?.status == .running { return false }' <<<"${FREE_BODY}" \
  || fail "${QUEUE}：laneIsFree 要先看这条道上 AI 起的那个做完没有（翻译起步是异步的，光看宿主会接连起两个）"

# 5. 排着的导出各占各的文件名。Since 2026-11-19 (docs/bugfixes/2026-11-19-parallel-ai-exports-pick-the-same-name.md) the
#    name is picked against the reservations as they are once the listing is back, and reserved in that same main-actor
#    step: in AIExportDestination.output nothing after the probe awaits, the pick reads `reserved[`, the reservation is
#    written before the return. export_video gives it back when the job is withdrawn, fails to start or ends, and its
#    video is delivered as a new file (never replacing: ExportTarget.newFile), never `.replacing`.
DESTINATION="Sources/SrtFlow/AIExportDestination.swift"
[ -f "${DESTINATION}" ] || fail "${DESTINATION} not found: renamed? Update this guard (an empty scan is a false green)"
OUTPUT_BODY="$(awk '/    static func output\(/,/^    \}/' "${DESTINATION}")"
AFTER_PROBE="$(awk '/await probe\.run\(/ { on = 1; next } on' <<<"${OUTPUT_BODY}" | grep -v '^[[:space:]]*//' || true)"
PICKS_AFTER_LISTING=1
[ -n "${AFTER_PROBE}" ] || PICKS_AFTER_LISTING=0
if grep -q 'await' <<<"${AFTER_PROBE}"; then PICKS_AFTER_LISTING=0; fi
grep -qF 'reserved[key($0)] != nil' <<<"${AFTER_PROBE}" || PICKS_AFTER_LISTING=0
grep -qF 'reserved[chosen.key] = chosen.id' <<<"${AFTER_PROBE}" || PICKS_AFTER_LISTING=0
[ "${PICKS_AFTER_LISTING}" = 1 ] \
  || fail "${DESTINATION}: output must pick the name against the reservations as they are once the listing is back and reserve it in the same step (no await in between); otherwise two projects exporting at once pick the same name"
[ "$(count 'AIExportDestination.release(chosen)' "${EXPORT}")" -eq 3 ] \
  || fail "${EXPORT}: the reservation must be given back in three places (withdrawn while queued, failed to start, finished)"
grep -q 'ExportTarget.newFile(folder: folder' "${DESTINATION}" && ! grep -n '\.replacing(' "${EXPORT}" "${DESTINATION}" \
  || fail "${EXPORT} / ${DESTINATION}: the AI's video is delivered only as a new file (ExportTarget.newFile: a taken name moves on to the next number), never .replacing"

if [ "${FAILED}" = "0" ]; then
  echo "✓ AI 排队接线：四个入口都经 AIWorkQueue、不再回「已经在做」；取消先从队里拿；get_job 报 queued / queue_position；道上 AI 起的没做完不算空；排着的导出各占文件名 (and never replace)"
fi
exit "${FAILED}"
