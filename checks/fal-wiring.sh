#!/usr/bin/env bash
# 扫描守卫：fal.ai 生成（方案第 6 块）在 App 里的接线。
#
# 自检编不动 App 里那些 @MainActor 的类型（AISession、AIJobs、路由……），「花钱先问、问的时候不弹模态框、Key 只经一处读、
# 没做出来的钱要退回、清单里有没有这个工具跟着 Key 走」只能在源码层面钉住。每一条都是花用户的钱的地方 ——
# 漏一条就是没问就花、或者问不到人、或者 Key 被读来读去。写法同 encode-settings-memory.sh：文件找不到直接红（扫空 = 假绿）。
#
# 钉的事（每条后面是它守的规矩，出处见 docs/architecture/fal-generation.md）：
#   1. **不弹模态框**：fal 这几个文件里没有 NSAlert / runModal / 任何面板（方案第 9、10 条；要用户点头就回确认码，AI 在聊天里问）；
#   2. **HTTP 只经 FalClient**：`queue.fal.run` 和 `URLSession` 只出现在 FalClient.swift 和它的传输代理 FalTransfer.swift
#      （认证头、取消、错误换话都在 FalClient；FalTransfer 只管流着发 / 收和字节进度）；
#   3. **Key 只经 FalKeyCache 读**：`FalKeyStore.read(` 只在 FalKeyStore.swift 里；用 Key 的只有生成任务和配旁白两处；
#   4. **先问后花**（2026-10-17 起是聊天里的确认码，AI 多开方案板 9）：AI 起的生成任务（generate_media）在**起任务之前**经
#      `FalJobGate.decide` —— 把关 `store.decide(` 在发确认码 `AIConfirmations.shared.ask(` 之前、收令牌 `redeem` 只在这一处、记账恰好两处
#      （额度内 / 收下令牌之后）；工具在建任务之前调它、任务只拿记好的那一笔；没做出来才退（`guard !resultReceived`）；
#      upscale 2026-10-28 起走 Sky Studio、记积分（checks/sky-studio-wiring.sh 第 8 条），不许再碰 fal 的账；
#   5. **不在提示条上问**：`AISession` 没有 ask / question 了（后台工程没窗口、用户没在看 SrtFlow 时提示条上的问题没人看见）；
#      停止按工程（AIRound）取消这个工程的任务；
#   6. **配旁白是同步工具，不许停下来等用户**：AIVoiceoverTool / AIFalVoice 里没有 `.ask(`，额度用 `allowsWithoutAsking` 判断，用不了就退档；
#      fal 的声音也只经 `AIAudioFileWriter.writeVoiceover` 落盘（scripts/check-mcp.sh 那条扫描也钉着）；
#   7. **清单跟着 Key 走**：`generate_media` 属于 fal（MCPToolName.provider；upscale_clip 2026-10-28 起属于 Sky Studio）、Key 添加 / 删除都同步那个小文件、
#      启动时也对一遍；
#   8. 路由：generate_media 只起任务、回任务号（起步不排进撤销分组）；任务有 waitingForUser 和取消；
#   9. **进度看得见**（docs/architecture/fal-generation.md 第十三节）：生成任务把阶段交给 AIJobs 的 liveDetail（get_job 的 phase /
#      queue_position / transfer_percent）、get_job 真的并进去；任务起手登记进 FalGenerationActivity、结束拿掉；
#      编辑器顶上的状态行（FalStatusRows）挂在 AI 那条横幅底下。
# （第 10 条「upscale 的账单查到实收回写工程里的记录」2026-10-28 删了：upscale 走 Sky Studio，做完就知道实收。）
#
# 用法：checks/fal-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

RUN="Sources/SrtFlow/Fal/FalGenerationRun.swift"
TOOL="Sources/SrtFlow/Fal/FalGenerateTool.swift"
CLIENT="Sources/SrtFlow/Fal/FalClient.swift"
KEYS="Sources/SrtFlow/Fal/FalKeyStore.swift"
SETTINGS="Sources/SrtFlow/Fal/FalSettingsStore.swift"
VOICE="Sources/SrtFlow/AIFalVoice.swift"
VOICEOVER="Sources/SrtFlow/AIVoiceoverTool.swift"
SESSION="Sources/SrtFlow/AISession.swift"
ROUND="Sources/SrtFlow/AIRound.swift"
BANNER="Sources/SrtFlow/AIActivityBanner.swift"
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
CATALOG="Sources/SrtFlowMCPKit/MCPToolCatalog.swift"
APP="Sources/SrtFlow/SrtFlowApp.swift"
TRANSFER="Sources/SrtFlow/Fal/FalTransfer.swift"
JOBS="Sources/SrtFlow/AIJobs.swift"
GATE="Sources/SrtFlow/Fal/FalJobGate.swift"
UPSCALE="Sources/SrtFlow/Upscale/UpscaleJob.swift"
UPSCALE_TOOL="Sources/SrtFlow/AIUpscaleTool.swift"
for file in "${RUN}" "${TOOL}" "${CLIENT}" "${KEYS}" "${SETTINGS}" "${VOICE}" "${VOICEOVER}" "${SESSION}" "${ROUND}" "${BANNER}" "${ROUTER}" "${CATALOG}" "${APP}" \
            "${TRANSFER}" "${JOBS}" "${GATE}" "${UPSCALE}" "${UPSCALE_TOOL}"; do
  if [ ! -f "${file}" ]; then
    echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2
    exit 1
  fi
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
count() { grep -c -- "$1" "$2" || true; }
line_of() { { grep -n -- "$1" "$2" || true; } | head -1 | cut -d: -f1; }

FAL_FILES=(Sources/SrtFlow/Fal/*.swift "${VOICE}")

# 1. 不弹模态框。
for file in "${RUN}" "${TOOL}" "${VOICE}" "${SETTINGS}" "${GATE}"; do
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog' "${file}"; then
    fail "${file}：里面弹了模态框 —— 要用户点头就回确认码（FalJobGate.decide → needs_confirmation），AI 在等的时候弹框没人点"
  fi
done

# 2. HTTP 只经 FalClient（和它的传输代理 FalTransfer：只管流着发 / 收和字节进度，不拼地址、不带 Key）。
others="$(grep -l 'queue\.fal\.run\|URLSession' "${FAL_FILES[@]}" | grep -v "^${CLIENT}\$" | grep -v "^${TRANSFER}\$" || true)"
if [ -n "${others}" ]; then
  fail "这些文件自己碰了 fal 的地址 / URLSession：$(tr '\n' ' ' <<<"${others}")—— 请求只经 FalClient（认证头、取消、错误换话都在那里）"
fi
grep -q 'queue\.fal\.run\|authorized(' "${TRANSFER}" && fail "${TRANSFER}：传输代理不许拼 fal 的地址、不许带 Key（那是 FalClient 的事）"
[ "$(count 'FalTransfer.perform(' "${CLIENT}")" -eq 1 ] || fail "${CLIENT}：下载要经 FalTransfer.perform（字节进度从任务代理来），且只在 transfer() 一处"

# 3. Key 只经 FalKeyCache 读。
direct="$(grep -ln 'FalKeyStore\.read(' Sources/SrtFlow/*.swift Sources/SrtFlow/*/*.swift | grep -v "^${KEYS}\$" || true)"
if [ -n "${direct}" ]; then
  fail "这些文件直接读了钥匙串：$(tr '\n' ' ' <<<"${direct}")—— 读 Key 只经 FalKeyCache（一次运行最多问钥匙串一次、也就最多弹一次授权框）"
fi
users="$(grep -ln 'FalKeyCache\.shared\.key(' Sources/SrtFlow/*.swift Sources/SrtFlow/*/*.swift | LC_ALL=C sort | tr '\n' ' ')"
expected="$(printf '%s\n' "${VOICE}" "${RUN}" | LC_ALL=C sort | tr '\n' ' ')"
if [ "${users}" != "${expected}" ]; then
  fail "用 fal 的 Key 的地方应该只有生成任务和配旁白两处（upscale 2026-10-28 起用 Sky Studio 的 Key），实际是：${users}"
fi

# 4. 先问后花：AI 起的任务在起任务之前都经 FalJobGate.decide（规则只有一处；超了是聊天里的确认码）。
GATE_DECIDE="$(line_of 'store.decide(' "${GATE}")"
GATE_ASK="$(line_of 'AIConfirmations.shared.ask(' "${GATE}")"
GATE_REDEEM="$(line_of 'AIConfirmations.shared.redeem(' "${GATE}")"
if [ -z "${GATE_DECIDE}" ] || [ -z "${GATE_ASK}" ] || [ -z "${GATE_REDEEM}" ] || [ "${GATE_DECIDE}" -ge "${GATE_REDEEM}" ] || [ "${GATE_REDEEM}" -ge "${GATE_ASK}" ]; then
  fail "${GATE}：花钱的把关（store.decide）→ 收令牌（redeem）→ 没收下才发确认码（AIConfirmations.shared.ask），顺序不能乱"
fi
[ "$(count 'record(store, estimate)' "${GATE}")" -eq 2 ] \
  || fail "${GATE}：记账 record(store, estimate) 应恰好两处（额度内直接做 / 收下令牌之后）"
[ "$(count 'AIConfirmations.shared.ask(' "${GATE}")" -eq 1 ] && [ "$(count 'AIConfirmations.shared.redeem(' "${GATE}")" -eq 1 ] \
  || fail "${GATE}：超额度 / 没登记单价只发一处确认码、只在一处收令牌"
for file in "${RUN}" "${TOOL}"; do
  if grep -nE 'store\.decide\(|AIConfirmations\.shared\.(ask|redeem)\(' "${file}"; then
    fail "${file}：把关和确认码只许在 FalJobGate 里"
  fi
done
for file in "${UPSCALE}" "${UPSCALE_TOOL}"; do
  if grep -nE 'FalJobGate|FalSettingsStore|FalKeyCache|FalClient' "${file}"; then
    fail "${file}：upscale 2026-10-28 起走 Sky Studio（Key、积分、把关都在 SkyStudio*），不许再碰 fal 的 Key、账和把关"
  fi
done
TOOL_DECIDE="$(line_of 'try FalJobGate.decide(' "${TOOL}")"
TOOL_RUN="$(line_of 'let run = FalGenerationRun(' "${TOOL}")"
if [ -z "${TOOL_DECIDE}" ] || [ -z "${TOOL_RUN}" ] || [ "${TOOL_DECIDE}" -ge "${TOOL_RUN}" ]; then
  fail "${TOOL}：把关（FalJobGate.decide）必须在建生成任务（FalGenerationRun）之前"
fi
grep -q 'reserved = (reservation.amount, reservation.day)' "${RUN}" || fail "${RUN}：任务要用起任务之前记好的那一笔（退账按它退）"
[ "$(count 'guard !resultReceived' "${RUN}")" -eq 1 ] || fail "${RUN}：退账必须只在没拿到结果时（fal 只对做出来的收钱）"
[ "$(count 'recordSpend(' "${GATE}")" -eq 1 ] && [ "$(count 'recordSpend(' "${VOICE}")" -eq 1 ] \
  || fail "记账 recordSpend 只该在 FalJobGate（AI 起的任务）一处、配旁白读完一句之后一处"
[ "$(count 'recordSpend(' "${RUN}")" -eq 0 ] || fail "${RUN}：生成任务自己记账了，应经 FalJobGate"

# 5. 不在提示条上问（AI 多开方案板 9：后台工程没有窗口、用户没在看 SrtFlow 时，提示条上的问题没人看见）。
if grep -nE 'func ask\(|var question|pendingQuestions' "${SESSION}" || grep -n 'session.question' "${BANNER}"; then
  fail "${SESSION} / ${BANNER}：又在提示条上问用户了 —— 要用户点头的事走聊天里的确认码（AIConfirmations）"
fi
# 2026-10-17 起停止按工程（AIRound）：停的是这个工程的任务。
STOP_BODY="$(awk '/    func stop\(\) \{/,/^    \}/' "${ROUND}")"
grep -q 'AIJobs.shared.cancel(stoppingWith: projectID)' <<<"${STOP_BODY}" \
  || fail "${ROUND}：按停止时没有取消这个工程的任务"

# 6. 配旁白是同步工具，不许停下来等用户。
for file in "${VOICEOVER}" "${VOICE}"; do
  if grep -nE '\.ask\(' "${file}"; then
    fail "${file}：配旁白是同步的工具（客户端一分钟左右超时），不许停下来问用户 —— 额度不够就退到下一档"
  fi
done
grep -q 'FalSpendPolicy.allowsWithoutAsking' "${VOICE}" || fail "${VOICE}：能不能用 fal 的声音必须按额度判断（allowsWithoutAsking）"
grep -q 'falAvailable: offer != nil' "${VOICEOVER}" || fail "${VOICEOVER}：挑声音没把「fal 能不能用」传给 AIVoiceChoice.choose"
[ "$(count 'AIAudioFileWriter.writeVoiceover(' "${VOICE}")" -eq 1 ] || fail "${VOICE}：fal 的声音必须经 AIAudioFileWriter.writeVoiceover 落盘（先过一道音量）"

# 7. 清单跟着 Key 走。
grep -Eq 'case \.generateMedia: return \.fal' "${CATALOG}" || fail "${CATALOG}：generate_media 没属于 fal 提供方 —— 没配 Key 也会列出来"
# 调用各占一行（8 格缩进）：Key 存 / 删 / 重新查看，共三处（定义那一行不算）。
[ "$(count '^        syncProviders()$' "${SETTINGS}")" -eq 3 ] || fail "${SETTINGS}：Key 添加 / 删除 / 重新查看之后没有同步「配了哪些提供方」的小文件（应恰好三处调用）"
grep -q 'FalSettingsStore.shared.refreshKeyStatus()' "${APP}" || fail "${APP}：启动时没有对一遍「配了 fal」的小文件"

# 8. 路由与任务。
[ "$(count '\.generateMedia' "${ROUTER}")" -eq 2 ] || fail "${ROUTER}：generate_media 应出现两处（分派、策略：不排撤销分组、不算这一轮的改动）"
if grep -q 'AIUndoGrouping' <<<"$(grep -n 'generateMedia' "${ROUTER}" || true)"; then
  fail "${ROUTER}：generate_media 不改工程，不该包进 AIUndoGrouping（放上时间线是 add_clips 的事）"
fi

grep -q 'waitingForUser: { \[weak self\] in self?.waiting }' "${RUN}" || fail "${RUN}：任务没把「在等用户」交给 AIJobs（AI 会对着 running 干等）"
grep -q 'cancel: { \[weak self\] in self?.cancel() }' "${RUN}" || fail "${RUN}：任务没有取消动作（停止按钮取消不了）"

# 9. 进度看得见：AI 从 get_job 看阶段，用户从编辑器顶上的状态行看。
grep -q 'liveDetail: { \[weak self\] in self?.progress?.json() ?? \[:\] }' "${RUN}" \
  || fail "${RUN}：生成任务没把阶段（FalJobProgress）交给 AIJobs 的 liveDetail（get_job 看不到 phase / queue_position / transfer_percent）"
grep -q 'object.merge(job.liveDetail())' "${JOBS}" || fail "${JOBS}：get_job 的 JSON 没并进跑着时的明细（liveDetail）"
[ "$(count 'FalGenerationActivity.shared.add(self)' "${RUN}")" -eq 1 ] && [ "$(count 'FalGenerationActivity.shared.remove(self)' "${RUN}")" -eq 1 ] \
  || fail "${RUN}：生成任务起手要登记进 FalGenerationActivity、结束拿掉（状态行从它读；各恰好一处）"
grep -q 'FalStatusRows()' "${BANNER}" || fail "${BANNER}：编辑器顶上的状态行没挂 FalStatusRows（用户看不到上传 / 排队 / 处理 / 下载到哪一步）"

if [ "${FAILED}" -ne 0 ]; then
  echo "fal 接线守卫失败" >&2
  exit 1
fi
echo "✓ fal 接线守卫通过"
