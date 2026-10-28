#!/usr/bin/env bash
# 扫描守卫：fal.ai 在 App 里的接线（2026-10-28 起只剩配旁白的 fal 声音和设置里那一节；生成、upscale 走 Sky Studio，
# 接线见 checks/sky-studio-wiring.sh 第 8、9 条）。
#
# 自检编不动 App 里那些 @MainActor 的类型（AISession、AIJobs、路由……），「问的时候不弹模态框、Key 只经一处读、
# 配旁白不停下来等人、额度不够就退档」只能在源码层面钉住。每一条都是花用户的钱的地方 ——
# 漏一条就是没问就花、或者问不到人、或者 Key 被读来读去。写法同 encode-settings-memory.sh：文件找不到直接红（扫空 = 假绿）。
#
# 钉的事（每条后面是它守的规矩，出处见 docs/architecture/fal-generation.md）：
#   1. **不弹模态框**：fal 这几个文件里没有 NSAlert / runModal / 任何面板（方案第 9、10 条）；
#   2. **HTTP 只经 FalClient**：`queue.fal.run` 和 `URLSession` 只出现在 FalClient.swift 和它的传输代理 FalTransfer.swift
#      （认证头、取消、错误换话都在 FalClient；FalTransfer 只管流着发 / 收和字节进度）；
#   3. **Key 只经 FalKeyCache 读**：`FalKeyStore.read(` 只在 FalKeyStore.swift 里；用 fal 的 Key 的只剩配旁白一处；
#   4. **生成和 upscale 不再碰 fal**（2026-10-28 起走 Sky Studio、记积分）：它们的文件里没有 fal 的 Key、账和客户端；
#      fal 的账 recordSpend 只剩配旁白读完一句之后那一处；
#   5. **不在提示条上问**：`AISession` 没有 ask / question 了（后台工程没窗口、用户没在看 SrtFlow 时提示条上的问题没人看见）；
#      停止按工程（AIRound）取消这个工程的任务；
#   6. **配旁白是同步工具，不许停下来等用户**：AIVoiceoverTool / AIFalVoice 里没有 `.ask(`，额度用 `allowsWithoutAsking` 判断，用不了就退档；
#      fal 的声音也只经 `AIAudioFileWriter.writeVoiceover` 落盘（scripts/check-mcp.sh 那条扫描也钉着）；
#   7. **清单**：fal 的 Key 不再多列工具（generate_media、upscale_clip 2026-10-28 起属于 Sky Studio）；Key 添加 / 删除照旧同步那个小文件、
#      启动时也对一遍（第 7 刀删 fal 时一起删）；
#   8. **进度看得见**（docs/architecture/fal-generation.md 第十三节，现在给 Sky Studio 的任务用）：get_job 真的并进跑着时的明细（liveDetail），
#      编辑器顶上的状态行（FalStatusRows）挂在 AI 那条横幅底下。
# （生成的「先问后花、任务的阶段和取消、路由」2026-10-28 挪到 checks/sky-studio-wiring.sh 第 9 条；
#   「upscale 的账单查到实收回写工程里的记录」同一天删了：upscale 走 Sky Studio，做完就知道实收。）
#
# 用法：checks/fal-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CLIENT="Sources/SrtFlow/Fal/FalClient.swift"
KEYS="Sources/SrtFlow/Fal/FalKeyStore.swift"
SETTINGS="Sources/SrtFlow/Fal/FalSettingsStore.swift"
VOICE="Sources/SrtFlow/AIFalVoice.swift"
VOICEOVER="Sources/SrtFlow/AIVoiceoverTool.swift"
SESSION="Sources/SrtFlow/AISession.swift"
ROUND="Sources/SrtFlow/AIRound.swift"
BANNER="Sources/SrtFlow/AIActivityBanner.swift"
CATALOG="Sources/SrtFlowMCPKit/MCPToolCatalog.swift"
APP="Sources/SrtFlow/SrtFlowApp.swift"
TRANSFER="Sources/SrtFlow/Fal/FalTransfer.swift"
JOBS="Sources/SrtFlow/AIJobs.swift"
UPSCALE="Sources/SrtFlow/Upscale/UpscaleJob.swift"
UPSCALE_TOOL="Sources/SrtFlow/AIUpscaleTool.swift"
GENERATE_TOOL="Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift"
GENERATE_RUN="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
for file in "${CLIENT}" "${KEYS}" "${SETTINGS}" "${VOICE}" "${VOICEOVER}" "${SESSION}" "${ROUND}" "${BANNER}" "${CATALOG}" "${APP}" \
            "${TRANSFER}" "${JOBS}" "${UPSCALE}" "${UPSCALE_TOOL}" "${GENERATE_TOOL}" "${GENERATE_RUN}"; do
  if [ ! -f "${file}" ]; then
    echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2
    exit 1
  fi
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
count() { grep -c -- "$1" "$2" || true; }

FAL_FILES=(Sources/SrtFlow/Fal/*.swift "${VOICE}")

# 1. 不弹模态框。
for file in "${VOICE}" "${SETTINGS}"; do
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog' "${file}"; then
    fail "${file}：里面弹了模态框 —— AI 在等的时候弹框没人点"
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
if [ "${users}" != "${VOICE} " ]; then
  fail "用 fal 的 Key 的地方应该只剩配旁白一处（生成、upscale 2026-10-28 起用 Sky Studio 的 Key），实际是：${users}"
fi

# 4. 生成和 upscale 不再碰 fal 的 Key、账和客户端；fal 的账只剩配旁白。
for file in "${UPSCALE}" "${UPSCALE_TOOL}" "${GENERATE_TOOL}" "${GENERATE_RUN}"; do
  if grep -nE 'FalJobGate|FalSettingsStore|FalKeyCache|FalClient' "${file}"; then
    fail "${file}：生成和 upscale 2026-10-28 起走 Sky Studio（Key、积分、把关都在 SkyStudio*），不许再碰 fal 的 Key、账和把关"
  fi
done
spenders="$(grep -ln 'recordSpend(' Sources/SrtFlow/*.swift Sources/SrtFlow/*/*.swift | grep -v "^${SETTINGS}\$" | LC_ALL=C sort | tr '\n' ' ')"
[ "${spenders}" = "${VOICE} " ] && [ "$(count 'recordSpend(' "${VOICE}")" -eq 1 ] \
  || fail "fal 的记账 recordSpend 只该剩配旁白读完一句之后一处，实际在：${spenders:-没有}"

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

# 7. 清单：fal 的 Key 不再多列工具；小文件照旧跟着 Key 走。
if grep -nE 'return \.fal\b' "${CATALOG}"; then
  fail "${CATALOG}：又有工具属于 fal 提供方了 —— 生成和 upscale 2026-10-28 起属于 Sky Studio"
fi
# 调用各占一行（8 格缩进）：Key 存 / 删 / 重新查看，共三处（定义那一行不算）。
[ "$(count '^        syncProviders()$' "${SETTINGS}")" -eq 3 ] || fail "${SETTINGS}：Key 添加 / 删除 / 重新查看之后没有同步「配了哪些提供方」的小文件（应恰好三处调用）"
grep -q 'FalSettingsStore.shared.refreshKeyStatus()' "${APP}" || fail "${APP}：启动时没有对一遍「配了 fal」的小文件"

# 8. 进度看得见：AI 从 get_job 看阶段，用户从编辑器顶上的状态行看。
grep -q 'object.merge(job.liveDetail())' "${JOBS}" || fail "${JOBS}：get_job 的 JSON 没并进跑着时的明细（liveDetail）"
grep -q 'FalStatusRows()' "${BANNER}" || fail "${BANNER}：编辑器顶上的状态行没挂 FalStatusRows（用户看不到上传 / 排队 / 处理 / 下载到哪一步）"

if [ "${FAILED}" -ne 0 ]; then
  echo "fal 接线守卫失败" >&2
  exit 1
fi
echo "✓ fal 接线守卫通过"
