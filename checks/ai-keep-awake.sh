#!/usr/bin/env bash
# 扫描守卫：AI 在干活时别让 App Nap 把 SkyCut 降速（AIKeepAwake，docs/bugfixes/2026-11-10-ai-work-throttled-by-app-nap.md），领和还成对。
#
# SkyCut 不在前台时 App Nap 把它降到最低的调度优先级；AI 的一次工具调用和 AI 起的每个长任务各领一份 `AIKeepAwake.Lease`，还有没还的就持有
# 一个活动断言。领了不还 = 断言永远不放（整台 Mac 的耗电）；该领没领 = 又被降速。这几条钉住在哪领、在哪还：
#   1. `beginActivity` / `endActivity` 只在 AIKeepAwake 和录屏（录屏另有一份）；
#   2. `AIKeepAwake.shared.hold()` 只在两处领：AIToolRouter.handle（下一行就是 `defer { awake.release() }`）和 AIJobs.start；
#   3. AIJobs 的那一份在 finish 里还（只认第一次 finish 的那一支），start 只领一次。
# 计数、只开一次只关一次、重复还不多还、兜底还、真的工具调用和任务都还回来：scripts/check-voice-recovery.sh 的 KeepAwakeChecks。
#
# 用法：checks/ai-keep-awake.sh
set -euo pipefail
cd "$(dirname "$0")/.."

AWAKE="Sources/SrtFlow/AIKeepAwake.swift"
RECORDING="Sources/SrtFlow/ScreenRecordingCoordinator.swift"
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
JOBS="Sources/SrtFlow/AIJobs.swift"
for file in "${AWAKE}" "${RECORDING}" "${ROUTER}" "${JOBS}"; do
  [ -f "${file}" ] || { echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2; exit 1; }
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }

# 1. 活动断言只在两处开、关。
OUTSIDE="$(grep -rlE 'beginActivity\(|endActivity\(' Sources | grep -vxF -e "${AWAKE}" -e "${RECORDING}" || true)"
[ -z "${OUTSIDE}" ] || fail "活动断言只许在 ${AWAKE}（AI 的活）和 ${RECORDING}（录屏）开关；这些文件也碰了：${OUTSIDE}"
BEGINS="$(grep -c 'ProcessInfo.processInfo.beginActivity(' "${AWAKE}" || true)"
ENDS="$(grep -c 'ProcessInfo.processInfo.endActivity(' "${AWAKE}" || true)"
[ "${BEGINS}" -eq 1 ] && [ "${ENDS}" -eq 1 ] || fail "${AWAKE}：开一处、关一处（现在开 ${BEGINS} 处、关 ${ENDS} 处）"

# 2. 只在两处领：路由领了下一行就还，AIJobs.start 领。
HOLDERS="$(grep -rl 'AIKeepAwake.shared.hold()' Sources | grep -vxF -e "${ROUTER}" -e "${JOBS}" || true)"
[ -z "${HOLDERS}" ] || fail "AIKeepAwake.shared.hold() 只在 AIToolRouter.handle 和 AIJobs.start 领（别处领了没人钉着还）：${HOLDERS}"
HANDLE="$(awk '/    func handle\(_ request: MCPBridge.Request/,/^    \}/' "${ROUTER}")"
AFTER_HOLD="$(awk 'found { print; exit } /let awake = AIKeepAwake\.shared\.hold\(\)/ { found = 1 }' <<<"${HANDLE}")"
[ "${AFTER_HOLD}" = "        defer { awake.release() }" ] \
  || fail "${ROUTER}：handle 一开头领一份（let awake = AIKeepAwake.shared.hold()），紧跟着 defer { awake.release() } 还"
[ "$(grep -c 'AIKeepAwake.shared.hold()' "${ROUTER}" || true)" -eq 1 ] || fail "${ROUTER}：只在 handle 领一份"

START="$(awk '/    func start\(/,/^    \}/' "${JOBS}")"
FINISH="$(awk '/    func finish\(_ job: Job/,/^    \}/' "${JOBS}")"
[ "$(grep -c 'job.awake = AIKeepAwake.shared.hold()' <<<"${START}" || true)" -eq 1 ] || fail "${JOBS}：start 起新任务时领一份（job.awake = AIKeepAwake.shared.hold()）"
[ "$(grep -c 'AIKeepAwake.shared.hold()' "${JOBS}" || true)" -eq 1 ] || fail "${JOBS}：只在 start 领一份"
grep -q 'guard job.status == .running else { return }' <<<"${FINISH}" && grep -q 'job.awake?.release()' <<<"${FINISH}" \
  || fail "${JOBS}：finish（只认第一次）还那一份（job.awake?.release()）"

if [ "${FAILED}" -ne 0 ]; then exit 1; fi
echo "✓ ai-keep-awake：活动断言只在 AIKeepAwake 和录屏开关；路由领了就 defer 还，AI 的任务 start 领、finish 还"
