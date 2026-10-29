#!/usr/bin/env bash
# 扫描守卫：Sky Studio 账号和照授权拦（收费方案第 5 刀）的接线。秒级、不编译，进 check-all 第 1 组。
#   1. **只有 SkyStudioAPI 碰 Sky Studio 的地址和 URLSession**（认证头、版本号、机器号、错误怎么分都在那一处）；
#      环境变量 SRTFLOW_SKYSTUDIO_API_BASE 只在那里读，而且只认回环地址（Key 不会因此发到别处）；
#   2. **原始的硬件 UUID 不出 SkyStudioMachine**：IOPlatformUUID 只在那里读，`X-SkyCut-Machine` 只在 SkyStudioAPI 里写、写的是哈希；
#   3. **后台问 Sky Studio 从不弹钥匙串授权框**：弹框的那一档读只在 KeychainSecret.swift；SkyStudioAccount 里弹框的取法只在
#      `promptKeychain` 为真的那一支，而 `promptKeychain: true` 只出现在设置那一节（用户点了按钮）；
#   4. 设置窗口里挂着「Sky Studio」一节，启动时 `SkyStudioAccount.shared.start()`；
#   5. **照授权拦（第 5 刀第二步）接在该接的地方**：AI 的调用在核对参数名之后、建调用排队之前问 SkyStudioAccount.aiRefusal；
#      让不让、带不带水印的判断只在 SkyStudioAccount 里调 SkyCutGates（生不生效另有 get_status 问一句）；导出面板底栏挂着「会带水印」那一行；
#      export_video 开始和做完都告诉 AI 带了水印；get_status 报 skycut_plan。
#   6. **交任务、取消任务只经 SkyStudioJobRun**（第 6 刀）：满了等着再交、同一个 idempotency_key、交的请求不跟着取消、停的时候排队中的退钱 /
#      开始了的取消不了，这些规矩只在那一处；
#   7. **Key 只发给 Sky Studio**：认证头只在 SkyStudioAPI.request 里写一次，上传的签名地址和成品地址都不经它；
#   8. **upscale 走 Sky Studio**（第 6 刀，2026-10-28）：AI 起的在建任务之前过 SkyStudioJobGate（把关 → 收令牌 → 没收下才发确认码，记账恰好两处），
#      面板起的面板本身就是确认；积分的账只在 SkyStudioJobGate 和 SkyStudioHeldCredits（upscale 和生成共用的那一笔）里动；
#      **只有面板起的任务可能弹钥匙串授权框**（`.prompting`），
#      AI 起的、面板取模型和报价都不弹；upscale_clip 跟着 Sky Studio 的 Key 列（提供方 skystudio，Key 变了同步那个小文件）；
#      路由只起任务（起步不包撤销分组，换源那一下在任务里自己包），AI 起的不弹对比窗口、阶段交给 get_job；这几个文件不弹模态框；
#      get_job 报 Sky Studio 的任务号 skystudio_job_id（交上了就有：跑着、做完、没做成、停了都带）；
#   9. **generate_media 走 Sky Studio**（第 6 刀 6b，2026-10-28）：在建任务之前过 SkyStudioJobGate、任务用记好的那一笔（SkyStudioHeldCredits）；
#      Key 不弹框；清单里它属于 skystudio；路由只起任务（不包撤销分组）；get_job 有阶段和 skystudio_job_id；任务起手登记进
#      SkyStudioGenerationActivity、结束拿掉，状态行订阅它；能取消；这几个文件不弹模态框。
# 规矩见 docs/architecture/sky-studio-account.md（账号、授权）和 docs/architecture/sky-studio-jobs.md（任务）。
#
# 用法：checks/sky-studio-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

API="Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift"
MACHINE="Sources/SrtFlow/SkyStudio/SkyStudioMachine.swift"
ACCOUNT="Sources/SrtFlow/SkyStudio/SkyStudioAccount.swift"
SECTION="Sources/SrtFlow/SkyStudio/SkyStudioSettingsSection.swift"
KEYCHAIN="Sources/SrtFlow/KeychainSecret.swift"
APP="Sources/SrtFlow/SrtFlowApp.swift"
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
SHEET="Sources/SrtFlow/VideoEditExportSheet.swift"
EXPORT_TOOLS="Sources/SrtFlow/AIExportTools.swift"
STATUS_TOOLS="Sources/SrtFlow/AIProjectTools.swift"
for file in "${API}" "${MACHINE}" "${ACCOUNT}" "${SECTION}" "${KEYCHAIN}" "${APP}" "${ROUTER}" "${SHEET}" "${EXPORT_TOOLS}" "${STATUS_TOOLS}"; do
  if [ ! -f "${file}" ]; then
    echo "✗ 找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）" >&2
    exit 1
  fi
done

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
count() { grep -cF -- "$1" "$2" || true; }
# 去掉 // 注释再找（注释里提到名字不算）。查变量用 <<<：管道末端的 grep -q 在 pipefail 下会假报（checks/shell-pipe-grep-q.sh）。
code_files_with() {
  local pattern="$1" file stripped
  grep -rlE --include='*.swift' "${pattern}" Sources | while read -r file; do
    stripped="$(sed 's,//.*,,' "${file}")"
    if grep -qE "${pattern}" <<<"${stripped}"; then echo "${file}"; fi
  done
}

# 1. 地址和 HTTP 只在 SkyStudioAPI。
others="$(code_files_with 'skystudioai\.com/api' | grep -v "^${API}\$" || true)"
[ -z "${others}" ] || fail "这些文件自己写了 Sky Studio 的接口地址：$(tr '\n' ' ' <<<"${others}")—— 请求只经 SkyStudioAPI"
others="$(grep -l 'URLSession' Sources/SrtFlow/SkyStudio/*.swift | grep -v "^${API}\$" || true)"
[ -z "${others}" ] || fail "这些文件自己用了 URLSession：$(tr '\n' ' ' <<<"${others}")—— 请求只经 SkyStudioAPI"
others="$(code_files_with 'SRTFLOW_SKYSTUDIO_API_BASE' | grep -v "^${API}\$" || true)"
[ -z "${others}" ] || fail "这些文件自己读了 SRTFLOW_SKYSTUDIO_API_BASE：$(tr '\n' ' ' <<<"${others}")"
[ "$(count 'let host = url.host, isLoopback(host) else { return productionBase }' "${API}")" -eq 1 ] \
  || fail "${API}：环境变量指的地址不是回环地址时要退回正式地址（只认本机的假服务器）"

# 2. 原始的硬件 UUID 不出 SkyStudioMachine；发出去的是哈希。
others="$(code_files_with 'kIOPlatformUUIDKey' | grep -v "^${MACHINE}\$" || true)"
[ -z "${others}" ] || fail "这些文件读了硬件 UUID：$(tr '\n' ' ' <<<"${others}")—— 只许 SkyStudioMachine 读，发出去的只能是它算的哈希"
others="$(code_files_with 'X-SkyCut-Machine' | grep -v "^${API}\$" || true)"
[ -z "${others}" ] || fail "这些文件自己写了 X-SkyCut-Machine：$(tr '\n' ' ' <<<"${others}")"
[ "$(count 'machine: String? = SkyStudioMachine.current' "${API}")" -eq 1 ] \
  || fail "${API}：机器号默认取 SkyStudioMachine.current（硬件 UUID 的哈希）"

# 3. 后台从不弹钥匙串授权框。
others="$(grep -rlE --include='*.swift' 'read\(\.interactive\)' Sources | grep -v "^${KEYCHAIN}\$" || true)"
[ -z "${others}" ] || fail "这些文件自己做了会弹授权框的那一档读：$(tr '\n' ' ' <<<"${others}")—— 只经 KeychainSecretCache（一次运行最多弹一次）"
[ "$(count 'promptKeychain ? await SkyStudioKey.cache.key() : await SkyStudioKey.cache.keyWithoutPrompt()' "${ACCOUNT}")" -eq 1 ] \
  || fail "${ACCOUNT}：问 /me 时只有 promptKeychain 为真才走会弹框的 key()，否则 keyWithoutPrompt()"
[ "$(count 'SkyStudioKey.cache.key(' "${ACCOUNT}")" -eq 1 ] || fail "${ACCOUNT}：会弹框的 SkyStudioKey.cache.key() 只许出现在那一处"
prompters="$(grep -rl --include='*.swift' 'promptKeychain: true' Sources | LC_ALL=C sort | tr '\n' ' ')"
[ "${prompters}" = "${SECTION} " ] || fail "promptKeychain: true 只许在设置那一节（用户点了按钮），实际在：${prompters}"

# 4. 挂上了。
[ "$(count 'SkyStudioSettingsSection()' "${APP}")" -eq 1 ] || fail "${APP}：设置窗口里要挂 SkyStudioSettingsSection()"
[ "$(count 'SkyStudioAccount.shared.start()' "${APP}")" -eq 1 ] || fail "${APP}：启动时要 SkyStudioAccount.shared.start()"

# 5. 照授权拦接在该接的地方（规矩在 SkyCutGates，生不生效看 SkyCutGates.enforced）。
GATE_AT="$(grep -nF 'if let refusal = await SkyStudioAccount.shared.aiRefusal(for: tool) {' "${ROUTER}" | cut -d: -f1 || true)"
ARGS_AT="$(grep -nF 'MCPArgumentCheck.problem(tool: tool' "${ROUTER}" | head -1 | cut -d: -f1 || true)"
CALL_AT="$(grep -nF 'let call = Call(' "${ROUTER}" | head -1 | cut -d: -f1 || true)"
if [ -z "${GATE_AT}" ] || [ "$(wc -l <<<"${GATE_AT}" | tr -d ' ')" -ne 1 ] || [ -z "${ARGS_AT}" ] || [ -z "${CALL_AT}" ] \
   || [ "${GATE_AT}" -lt "${ARGS_AT}" ] || [ "${GATE_AT}" -gt "${CALL_AT}" ]; then
  fail "${ROUTER}：AI 的调用要在核对参数名（第 ${ARGS_AT:-?} 行）之后、建调用排队（第 ${CALL_AT:-?} 行）之前问一次 SkyStudioAccount.aiRefusal（现在：${GATE_AT:-没有}）"
fi
for decision in 'SkyCutGates\.aiAllows\(' 'SkyCutGates\.watermark\('; do
  others="$(code_files_with "${decision}" | grep -v "^${ACCOUNT}\$" || true)"
  [ -z "${others}" ] || fail "这些文件自己调了 ${decision%%\\(*}：$(tr '\n' ' ' <<<"${others}")—— 只经 SkyStudioAccount（aiRefusal / exportsWithWatermark）"
done
others="$(code_files_with 'SkyCutGates\.enforced\(' | grep -v "^${ACCOUNT}\$" | grep -v "^${STATUS_TOOLS}\$" || true)"
[ -z "${others}" ] || fail "这些文件自己问了 SkyCutGates.enforced：$(tr '\n' ' ' <<<"${others}")—— 只有 SkyStudioAccount 和 get_status 问"
[ "$(count 'if !isAudioOnly { ExportWatermarkNotice() }' "${SHEET}")" -eq 1 ] \
  || fail "${SHEET}：导出面板底栏要挂「会带水印」那一行（只出声音时不挂）"
[ "$(count 'result["watermark"] = .string(SkyCutGates.watermarkNote)' "${EXPORT_TOOLS}")" -eq 1 ] \
  && [ "$(count 'detail["watermark"] = .string(SkyCutGates.watermarkNote)' "${EXPORT_TOOLS}")" -eq 1 ] \
  && [ "$(count 'watermarked: exporter.watermarked' "${EXPORT_TOOLS}")" -eq 1 ] \
  || fail "${EXPORT_TOOLS}：export_video 开始时（会带）和做完时（带了）都要告诉 AI 水印的事"
[ "$(count 'result["skycut_plan"] = SkyCutGates.statusJSON(' "${STATUS_TOOLS}")" -eq 1 ] \
  || fail "${STATUS_TOOLS}：get_status 要报 skycut_plan（没开通时它是唯一照常回的工具）"

# 6. 交任务、取消任务只经 SkyStudioJobRun。
RUN="Sources/SrtFlow/SkyStudio/SkyStudioJobRun.swift"
for call in 'submit\([^)]*, key:' 'cancel\([^)]*, key:'; do
  users="$(code_files_with "${call}" | grep -v "^${API}\$" | LC_ALL=C sort | tr '\n' ' ')"
  [ "${users}" = "${RUN} " ] || fail "SkyStudioAPI 的 ${call%%\\(*} 只许 SkyStudioJobRun 调（满了等着再交、停的规矩都在那里），实际在：${users:-没有}"
done

# 7. Key 只发给 Sky Studio：认证头只在 request() 里写一次。
[ "$(count 'forHTTPHeaderField: "Authorization"' "${API}")" -eq 1 ] \
  || fail "${API}：认证头只许在 request() 里写一次 —— 上传的签名地址、成品地址都不许带 Key"
others="$(code_files_with 'Bearer ' | grep -v "^${API}\$" || true)"
[ -z "${others}" ] || fail "这些文件自己写了 Bearer 认证头：$(tr '\n' ' ' <<<"${others}")—— Sky Studio 的 Key 只经 SkyStudioAPI 发"

# 8. upscale 走 Sky Studio。
UP_TOOL="Sources/SrtFlow/AIUpscaleTool.swift"
UP_JOB="Sources/SrtFlow/Upscale/UpscaleJob.swift"
JOB_GATE="Sources/SrtFlow/SkyStudio/SkyStudioJobGate.swift"
JOB_ACCESS="Sources/SrtFlow/SkyStudio/SkyStudioJobAccess.swift"
SPEND="Sources/SrtFlow/SkyStudio/SkyStudioSpend.swift"
CATALOG="Sources/SrtFlowMCPKit/MCPToolCatalog.swift"
for file in "${UP_TOOL}" "${UP_JOB}" "${JOB_GATE}" "${JOB_ACCESS}" "${SPEND}" "${CATALOG}"; do
  [ -f "${file}" ] || fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"
done
line_of() { { grep -nF -- "$1" "$2" || true; } | head -1 | cut -d: -f1; }
UP_DECIDE="$(line_of 'try SkyStudioJobGate.decide(' "${UP_TOOL}")"
UP_NEW_JOB="$(line_of 'let job = UpscaleJob(' "${UP_TOOL}")"
if [ -z "${UP_DECIDE}" ] || [ -z "${UP_NEW_JOB}" ] || [ "${UP_DECIDE}" -ge "${UP_NEW_JOB}" ]; then
  fail "${UP_TOOL}：花积分的把关（SkyStudioJobGate.decide）必须在建 upscale 任务之前"
fi
G_DECIDE="$(line_of 'store.decide(credits:' "${JOB_GATE}")"
G_REDEEM="$(line_of 'AIConfirmations.shared.redeem(' "${JOB_GATE}")"
G_ASK="$(line_of 'AIConfirmations.shared.ask(' "${JOB_GATE}")"
if [ -z "${G_DECIDE}" ] || [ -z "${G_REDEEM}" ] || [ -z "${G_ASK}" ] || [ "${G_DECIDE}" -ge "${G_REDEEM}" ] || [ "${G_REDEEM}" -ge "${G_ASK}" ]; then
  fail "${JOB_GATE}：把关（store.decide）→ 收令牌（redeem）→ 没收下才发确认码（ask），顺序不能乱"
fi
# 确认的是具体请求，不能拿给人看的摘要当身份（两种 MiniMax 视频同价同摘要曾拿到同一张码）。
grep -qF 'let action = identity' "${JOB_GATE}" || fail "${JOB_GATE}：确认码要绑调用方给的完整请求身份"
grep -qF 'identity: String' "${JOB_GATE}" || fail "${JOB_GATE}：完整请求身份不可省略"
for consumer in "${UP_TOOL}" Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift; do
  grep -qF 'SkyStudioApproval.identity(job:' "${consumer}" || fail "${consumer}：确认码没有从完整请求构造身份"
  grep -qF 'identity: identity, args: args' "${consumer}" || fail "${consumer}：完整请求身份没有接进花积分的闸"
done
grep -qF 'try SkyStudioApproval.file(request.originalURL)' "${UP_TOOL}" || fail "${UP_TOOL}：upscale 确认码没有绑定素材身份"
grep -qF 'try frame.map(SkyStudioApproval.file)' Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift \
  || fail "generate_media：确认码没有绑定首帧文件身份"
[ "$(count 'record(store, credits)' "${JOB_GATE}")" -eq 3 ] || fail "${JOB_GATE}：记账 record(store, credits) 应恰好三处（额度内直接做 / 收下令牌 / 配音整批预留）"
movers="$(code_files_with 'SkyStudioSpendStore' | while read -r file; do
  # 只认真动账本的写法（SkyStudioSpendStore.shared.record / refund、拿着它的 store.record / refund）；held?.refund() 是经 SkyStudioHeldCredits 退。
  if grep -qE '(SkyStudioSpendStore\.shared|store)\.(record|refund)\(' <<<"$(sed 's,//.*,,' "${file}")"; then echo "${file}"; fi
done | grep -v "^${SPEND}\$" | LC_ALL=C sort | tr '\n' ' ')"
HELD="Sources/SrtFlow/SkyStudio/SkyStudioHeldCredits.swift"
expected_movers="$(printf '%s\n' "${JOB_GATE}" "${HELD}" | LC_ALL=C sort | tr '\n' ' ')"
[ "${movers}" = "${expected_movers}" ] || fail "积分的账只许在 SkyStudioJobGate（AI 起的）和 SkyStudioHeldCredits（面板起的、按实收换、退回）里动，实际在：${movers:-没有}"
prompters="$(code_files_with '\.prompting' | grep -v "^${JOB_ACCESS}\$" | LC_ALL=C sort | tr '\n' ' ')"
[ "${prompters}" = "${UP_JOB} " ] || fail "会弹钥匙串授权框的那一档（.prompting）只许面板起的 upscale 任务用（UpscaleJob），实际在：${prompters:-没有}"
grep -qF 'case .generateMedia, .upscaleClip: return .skystudio' "${CATALOG}" || fail "${CATALOG}：upscale_clip 要属于 skystudio 提供方（没存 Sky Studio 的 Key 不列）"
grep -qF 'MCPProviderMarker.write(hasKey ? [.skystudio] : [], to: url)' "${ACCOUNT}" \
  || fail "Sky Studio 的工具标记必须只跟着自己的 Key 写"
[ "$(grep -c '^        syncProviders()$' "${ACCOUNT}" || true)" -eq 1 ] || fail "Sky Studio 启动时必须同步工具提供方标记"
grep -qF '            syncProviders()' "${ACCOUNT}" || fail "Sky Studio 的 Key 变化必须同步工具标记"
UP_INSPECTOR="Sources/SrtFlow/VideoEditInspector+Upscale.swift"
[ -f "${UP_INSPECTOR}" ] || fail "找不到 ${UP_INSPECTOR} —— 改名了就同步改这里（扫空 = 假绿）"
stale="$(for file in "${UP_INSPECTOR}" Sources/SrtFlow/Upscale/*.swift; do
  if grep -qiE '"[^"]*fal\.ai[^"]*"' <<<"$(sed 's,//.*,,' "${file}")"; then echo "${file}"; fi
done)"
[ -z "${stale}" ] || fail "这些 upscale 的界面文件还写着 fal.ai：$(tr '\n' ' ' <<<"${stale}")—— upscale 2026-10-28 起送 Sky Studio"
grep -qF 'Text(verbatim: "Sky Studio").font(.caption2)' "${UP_INSPECTOR}" || fail "${UP_INSPECTOR}：检查器 Upscale 那一节的标题旁边要写送去哪（Sky Studio）"
for file in "${UP_TOOL}" "${UP_JOB}" "${JOB_GATE}" "${SPEND}"; do
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog' "${file}"; then
    fail "${file}：弹了模态框 —— 要用户点头就回确认码（SkyStudioJobGate.decide → needs_confirmation），AI 在等的时候弹框没人点"
  fi
done

# 9. generate_media 走 Sky Studio。
GEN_TOOL="Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift"
GEN_RUN="Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift"
GEN_ACTIVITY="Sources/SrtFlow/SkyStudio/SkyStudioGenerationActivity.swift"
STATUS_ROWS="Sources/SrtFlow/CloudMedia/CloudStatusRows.swift"
for file in "${GEN_TOOL}" "${GEN_RUN}" "${GEN_ACTIVITY}" "${STATUS_ROWS}"; do
  [ -f "${file}" ] || fail "找不到 ${file} —— 改名了就同步改这里（扫空 = 假绿）"
done
GEN_DECIDE="$(line_of 'try SkyStudioJobGate.decide(' "${GEN_TOOL}")"
GEN_NEW_RUN="$(line_of 'let run = SkyStudioGenerationRun(' "${GEN_TOOL}")"
if [ -z "${GEN_DECIDE}" ] || [ -z "${GEN_NEW_RUN}" ] || [ "${GEN_DECIDE}" -ge "${GEN_NEW_RUN}" ]; then
  fail "${GEN_TOOL}：花积分的把关（SkyStudioJobGate.decide）必须在建生成任务之前"
fi
grep -qF 'held = SkyStudioHeldCredits(reservation)' "${GEN_RUN}" || fail "${GEN_RUN}：任务要用起任务之前记好的那一笔（退回、按实收换都按它）"
grep -qF 'switch await SkyStudioJobKey.key(.silent) {' "${GEN_TOOL}" && grep -qF 'switch await SkyStudioJobKey.key(.silent) {' "${GEN_RUN}" \
  || fail "AI 起的生成取 Key 不弹钥匙串授权框（.silent）：工具问价、任务交活都是"
grep -qF 'case .generateMedia, .upscaleClip: return .skystudio' "${CATALOG}" || fail "${CATALOG}：generate_media 要属于 skystudio 提供方（没存 Sky Studio 的 Key 不列）"
grep -qF 'case .generateMedia: return try await SkyStudioGenerateTool.generate(args, project)' "${ROUTER}" \
  || fail "${ROUTER}：generate_media 要分派给 SkyStudioGenerateTool"
[ "$(count '.generateMedia' "${ROUTER}")" -eq 2 ] || fail "${ROUTER}：generate_media 应出现两处（分派、策略：不排撤销分组、不算这一轮的改动）"
if grep -q 'AIUndoGrouping' <<<"$(grep -n 'generateMedia' "${ROUTER}" || true)"; then
  fail "${ROUTER}：generate_media 不改工程，不该包进 AIUndoGrouping（放上时间线是 add_clips 的事）"
fi
grep -qF 'if let id = self.submitted.jobID { detail["skystudio_job_id"] = .string(id) }' "${GEN_RUN}" \
  || fail "${GEN_RUN}：get_job 跑着时要报阶段和 skystudio_job_id（liveDetail）"
grep -qF 'cancel: { [weak self] in self?.cancel() }' "${GEN_RUN}" || fail "${GEN_RUN}：任务没有取消动作（停止按钮、cancel_job 停不了）"
[ "$(count 'SkyStudioGenerationActivity.shared.add(status)' "${GEN_RUN}")" -eq 1 ] && [ "$(count 'SkyStudioGenerationActivity.shared.remove(status)' "${GEN_RUN}")" -eq 1 ] \
  || fail "${GEN_RUN}：生成任务起手要登记进 SkyStudioGenerationActivity、结束拿掉（状态行从它读；各恰好一处）"
grep -qF 'private var generation = SkyStudioGenerationActivity.shared' "${STATUS_ROWS}" || fail "${STATUS_ROWS}：状态行没订阅 Sky Studio 的生成任务"
for file in "${GEN_TOOL}" "${GEN_RUN}" "${GEN_ACTIVITY}"; do
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog' "${file}"; then
    fail "${file}：弹了模态框 —— 要用户点头就回确认码（SkyStudioJobGate.decide → needs_confirmation），AI 在等的时候弹框没人点"
  fi
done

# 10. 云端配音返回任务号；整批预留、不询问付费，结束只入轨一整步。
VOICE_RUN="Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift"
VOICE_INPUT="Sources/SrtFlow/AIVoiceoverInput.swift"
VOICE_BUDGET="Sources/SrtFlow/SkyStudio/SkyStudioVoiceBudget.swift"
for file in "${VOICE_RUN}" "${VOICE_INPUT}" "${VOICE_BUDGET}"; do
  [ -f "${file}" ] || fail "找不到 ${file}"
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog|AIConfirmations' "${file}"; then
    fail "${file}：配音额度不够应退本机（克隆报错），不能停下来等确认"
  fi
done
grep -qF 'SkyStudioVoiceoverRun(input: input, project: project).start()' "${ROUTER}" || fail "配音路由没有启动云端任务"
grep -qF 'SkyStudioJobRun(api: api, key: key).run(request)' "${VOICE_RUN}" || fail "云端配音没有复用统一任务执行器"
grep -qF 'switch await SkyStudioJobKey.key(.silent)' "${VOICE_RUN}" || fail "云端配音不得弹钥匙串框"
grep -qF 'SkyStudioVoiceBudget.reserve(quotes)' "${VOICE_RUN}" || fail "云端配音没有先预留整批报价"
grep -qF 'SkyStudioJobGate.reserveWithoutAsking(credits: total' "${VOICE_BUDGET}" || fail "整批配音没有统一判断每日额度"
[ "$(count 'AIUndoGrouping.step(project.effectiveUndoManager)' "${VOICE_RUN}")" -eq 1 ] || fail "云端配音落地必须只有一整步撤销"
for token in 'SkyStudioGenerationActivity.shared.add(status)' 'SkyStudioGenerationActivity.shared.remove(status)' 'OpenProjects.shared.all.contains' 'credits_unknown' 'submission_keys' 'preserveRaw()'; do
  grep -qF "${token}" "${VOICE_RUN}" || fail "配音缺少状态 / 工程归属 / 未知提交 / 原音频保留：${token}"
done
# 假 Key 启动钩子必须同时限定独立 bundle id 和回环；生产 / Beta 不得装入。
grep -qF 'hasSuffix(".skystudiosmoke") == true' "${ACCOUNT}" && grep -qF 'SkyStudioAPI.isLoopback(host)' "${ACCOUNT}" \
  || fail "假 Sky Studio Key 钩子没有同时限定测试身份和回环"

if [ "${FAILED}" -ne 0 ]; then
  echo "见 docs/architecture/sky-studio-account.md 和 docs/architecture/sky-studio-jobs.md" >&2
  exit 1
fi
echo "✓ sky-studio-wiring：地址只在 SkyStudioAPI、原始硬件 UUID 不出本机、后台不弹钥匙串、设置和启动都接上了、照授权拦接在该接的地方、任务只经 SkyStudioJobRun、Key 只发给 Sky Studio、upscale 和生成的把关 / 积分 / 清单 / 路由接对了"
