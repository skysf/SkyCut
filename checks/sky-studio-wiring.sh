#!/usr/bin/env bash
# 扫描守卫：Sky Studio 账号和照授权拦（收费方案第 5 刀）的接线。秒级、不编译，进 check-all。
#   1. **只有 SkyStudioAPI 碰 Sky Studio 的地址和 URLSession**（认证头、版本号、机器号、错误怎么分都在那一处）；
#      环境变量 SRTFLOW_SKYSTUDIO_API_BASE 只在那里读，而且只认回环地址（Key 不会因此发到别处）；
#   2. **原始的硬件 UUID 不出 SkyStudioMachine**：IOPlatformUUID 只在那里读，`X-SkyCut-Machine` 只在 SkyStudioAPI 里写、写的是哈希；
#   3. **后台问 Sky Studio 从不弹钥匙串授权框**：原生读写只在串行执行器，静默读关闭进程交互并恢复；缓存有截止时间；
#      会弹框的账号入口只有 allowKeychain，只有设置和全 App notice 的 Allow 按钮调用；
#   4. 设置窗口里挂着「Sky Studio」一节，启动时 `SkyStudioAccount.shared.start()`；
#   5. **照授权拦（第 5 刀第二步）接在该接的地方**：AI 的调用在核对参数名之后、建调用排队之前问 SkyStudioAccount.aiRefusal；
#      让不让、带不带水印的判断只在 SkyStudioAccount 里调 SkyCutGates（生不生效另有 get_status 问一句）；导出面板底栏挂着「会带水印」那一行；
#      export_video 开始和做完都告诉 AI 带了水印；get_status 报 skycut_plan。
#   6. **交任务、取消任务只经 SkyStudioJobRun**（第 6 刀）：满了等着再交、同一个 idempotency_key、交的请求不跟着取消、停的时候排队中的退钱 /
#      开始了的取消不了，这些规矩只在那一处；**领槽只经 SkyStudioJobSlots**（声音 PR 4）：SkyStudioJobRun 交之前领（只 GET 的恢复不领），
#      一段旁白的各批由 SkyStudioVoiceBatchQueue 按顺序先领好、先记下出了什么事再还；槽数只照 /me（SkyStudioAccount adopt）；
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
#   11. **声音库（声音 PR 6）和全部权限下的长期授权（声音 PR 7）**，在 checks/sky-studio-wiring/voice-library.sh：`consent: true` 和
#       `consent: "standing_grant"` 只在 SkyStudioVoiceRecordingTool 里、过了 SkyStudioJobGate.voiceConsent 之后造（standing_grant 只在
#       全部权限 + 有效的长期授权时）；`/voices/consent-grant` 只经 SkyStudioVoiceStanding；改权限模式的地方改完都告诉它、设置里先弹说明；
#       `/voices` 的路径只在 SkyStudioVoiceAPI 里拼；没有 MiniMax voice_id 的样子；只经 SkyStudioJobGate 问；声音库的声音不退本机。
#   13. **声音库的收费单只下一次**（2026-11-11 审查之后），在 checks/sky-studio-wiring/voice-library-orders.sh：设计的对话框一份报价只下一单、
#       同一件事只开一单（建 MiniMax 版过闸之前先看在建的）、旁白中途那笔费用的问题受理之后才清、没做成的单把原因和新价带进 get_job、
#       每日预算的规矩不另抄、授权那句升了版本刷新目录再问、整份读录音在后台队列上、声音库的临时文件夹只在一处起名并在启动时清。
#   12. **声音库的界面（声音 PR 8）**：界面和 AI 的工具走同一条路——`consent: true` 另一处只许在新建声音对话框的 NewVoiceModel 里、
#       用户自己勾了那一句（`guard agreed`）之后造；参考录音只经 VoiceReferenceSample.prepare、交只经 SkyStudioVoiceRecordingSubmission
#       （`createVoice` / `addVoiceReference` 别处不许直接调）；删除只经 SkyStudioVoiceDeletion（存储一时不可用再发一次只有这一份）；
#       设计只经 SkyStudioVoiceDesignOrder，对话框按下去先过每日硬预算（SkyStudioJobGate.reserveWithoutAsking）再起任务；
#       界面不用确认码（AIConfirmations）、Key 只静默读；声音库的视图不读工程、不订阅播放器的时钟。
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
# 第一处出现在第几行（没有就是空的）。
line_of() { { grep -nF -- "$1" "$2" || true; } | head -1 | cut -d: -f1; }
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

# 3. 钥匙串读写互斥、静默读关闭进程交互，且不会占住协作线程或 actor。
EXECUTOR="Sources/SrtFlow/KeychainSecretExecutor.swift"
CACHE="Sources/SrtFlow/KeychainSecretCache.swift"
KEY_NOTICE="Sources/SrtFlow/SkyStudio/SkyStudioKeychainNoticeView.swift"
for file in "${EXECUTOR}" "${CACHE}" "${KEY_NOTICE}"; do
  [ -f "${file}" ] || { fail "找不到 ${file}"; exit 1; }
done
others="$(code_files_with 'SecItem(Add|Update|Delete|CopyMatching)\(|SecKeychain(Set|Get)UserInteractionAllowed\(' | grep -v "^${KEYCHAIN}\$" || true)"
[ -z "${others}" ] || fail "原生钥匙串读写只能在 KeychainSecret 的执行器入口：${others}"
others="$(code_files_with '\.read\(\.interactive\)' || true)"
[ -z "${others}" ] || fail "不许绕过缓存直接选择交互读，交互档只能由缓存的用户入口选择：${others}"
[ "$(count 'await KeychainSecretExecutor.run' "${KEYCHAIN}")" -eq 4 ] \
  && [ "$(count 'KeychainSecretExecutor.preconditionIsolated()' "${KEYCHAIN}")" -eq 3 ] \
  && grep -qF 'queue.maxConcurrentOperationCount = 1' "${EXECUTOR}" \
  && grep -qF 'queue.addOperation { continuation.resume(returning: work()) }' "${EXECUTOR}" \
  || fail "钥匙串存在 / 读 / 写 / 删必须只在唯一串行执行器上运行"
grep -qF 'SecKeychainSetUserInteractionAllowed(access == .interactive)' "${KEYCHAIN}" \
  && grep -qF 'SecKeychainGetUserInteractionAllowed(&original)' "${KEYCHAIN}" \
  && grep -qF 'SecKeychainSetUserInteractionAllowed(original.boolValue)' "${KEYCHAIN}" \
  || fail "静默读必须关闭进程交互、保存并恢复原状态，不能只靠查询标记"
grep -qF 'guard silentRead == nil, interactiveRead == nil else { return .needsPermission }' "${CACHE}" \
  && grep -qF 'try await Task.sleep(for: timeout)' "${CACHE}" \
  && grep -qF 'finish(.needsPermission)' "${CACHE}" \
  && ! grep -qF 'Task.detached' "${CACHE}" \
  || fail "缓存必须给静默读加期限，其他调用者不许排在卡住的读取后面"
python3 - <<'PY' || fail "后台 / 启动混入了交互授权"
from pathlib import Path
source=Path('Sources/SrtFlow/SkyStudio/SkyStudioAccount.swift').read_text()
allow=source.split('func allowKeychain() async {',1)[1].split('private func handleKeychainRead',1)[0]
assert source.count('await SkyStudioKey.cache.key()') == 1
assert 'await SkyStudioKey.cache.key()' in allow
assert source.count('let read = await SkyStudioKey.keyWithoutPrompt()') == 2
key=Path('Sources/SrtFlow/SkyStudio/SkyStudioKey.swift').read_text()
assert key.count('await cache.keyWithoutPrompt()') == 1
assert 'await cache.key()' not in key
assert 'await prepareKeychain()' in source.split('func start()',1)[1].split('private func syncProviders',1)[0]
assert 'promptKeychain' not in source
assert 'secret.exists()' not in source
PY
prompters="$(code_files_with '\.allowKeychain\(\)' | LC_ALL=C sort | tr '\n' ' ')"
[ "${prompters}" = "${KEY_NOTICE} ${SECTION} " ] \
  || fail "只有全 App notice 和设置的 Allow 按钮能触发授权，实际在：${prompters}"
grep -qF 'SkyStudioKeychainNoticePolicy.permissionNeeded' "${ACCOUNT}" \
  && grep -qF 'SkyStudioKeychainNoticePolicy.permissionNeeded' Sources/SrtFlow/SkyStudio/SkyStudioJobAccess.swift \
  && grep -qF 'plan["keychain_permission"] = .string("required")' Sources/SrtFlow/SkyStudio/SkyCutGates.swift \
  && grep -qF '.onAppear { account.keychainNoticeDidAppear() }' "${KEY_NOTICE}" \
  || fail "钥匙串授权状态必须接到全 App 提示、每构建一次呈现和 get_status"

# 4. 挂上了。
[ "$(count 'SkyStudioSettingsSection()' Sources/SrtFlow/SettingsWindowView.swift)" -eq 1 ] || fail "${APP}：设置窗口里要挂 SkyStudioSettingsSection()"
[ "$(count 'SkyStudioAccount.shared.start()' "${APP}")" -eq 1 ] || fail "${APP}：启动时要 SkyStudioAccount.shared.start()"

# 4b. 购买地址进入真实界面，设置和导出共用当前授权；AI 的下一步也用同一份。
HINTS="Sources/SrtFlow/SkyStudio/SkyStudioProHints.swift"
[ -f "${HINTS}" ] || { fail "找不到 ${HINTS}"; exit 1; }
[ "$(count 'SkyStudioContactRow(license: license)' "${SECTION}")" -eq 1 ] \
  || fail "设置里的购买提示没有收到此刻的授权"
[ "$(count 'SkyStudioContactRow(license: account.license, isExport: true)' "${HINTS}")" -eq 1 ] \
  || fail "导出面板没有用同一份当前授权的购买提示"
[ "$(count 'if let url = license.proActivationURL {' "${HINTS}")" -eq 1 ] \
  && [ "$(count 'Link("Get SkyCut Pro", destination: url)' "${HINTS}")" -eq 1 ] \
  || fail "购买按钮必须打开此刻授权提供的 proActivationURL"
grep -qF 'let activatePro = Self.activatePro(license: license)' Sources/SrtFlow/SkyStudio/SkyCutGates.swift \
  || fail "AI 的下一步没有按此刻授权选择购买地址 / 邮箱"
grep -qF 'if license.isMachineLimited, let url = license.manageMachinesURL {' "${HINTS}" \
  && grep -qF 'Link("Manage Macs", destination: url)' "${HINTS}" \
  && grep -qF 'if license.isMachineLimited {' "${HINTS}" \
  && grep -qF 'Text("This account is already using SkyCut on \(limit) Macs. This Mac is using the free plan.")' "${HINTS}" \
  || fail "台数满了的界面必须说明当前 Mac 免费、按服务器 limit 显示台数并打开 manageMachinesURL"
grep -qF 'Text(verbatim: message)' "${HINTS}" \
  && grep -qF 'license.unrecognizedPlanMessage' "${HINTS}" \
  && grep -qF 'license.unrecognizedPlanMessage' "${SECTION}" \
  || fail "未知 plan_reason 必须在设置 / 导出显示服务器的 plan_message"

# 4c. 提醒走同一份纯值，正式版没有水印时和只出音频时也要显示；商务 / 宽限的入口不能改成购买按钮。
PRO_NOTICE="Sources/SrtFlow/SkyStudio/SkyStudioProNoticeRow.swift"
[ -f "${PRO_NOTICE}" ] || { fail "找不到 ${PRO_NOTICE}"; exit 1; }
grep -qF 'if let notice = license.proNotice {' "${SECTION}" \
  && grep -qF 'SkyStudioProNoticeRow(notice: notice)' "${SECTION}" \
  && grep -qF 'if let notice = license.proNotice {' "${HINTS}" \
  && grep -qF 'SkyStudioProNoticeRow(notice: notice, isExport: true)' "${HINTS}" \
  || fail "设置和导出必须显示当前授权同一份 Pro 提醒"
grep -qF 'if let url = notice.actionURL {' "${PRO_NOTICE}" \
  && grep -qF 'Link("Renew SkyCut Pro", destination: url)' "${PRO_NOTICE}" \
  && grep -qF 'Link("Update Payment Method", destination: url)' "${PRO_NOTICE}" \
  && grep -qF '.textSelection(.enabled)' "${PRO_NOTICE}" \
  && grep -qF 'SkyStudioCopyEmailButton(identifier:' "${PRO_NOTICE}" \
  || fail "Pro 提醒必须用纯值选出的续约 / 更新付款方式地址，或可选中、复制的邮箱"
grep -qF 'plan["pro_notice"] = .object(details)' Sources/SrtFlow/SkyStudio/SkyCutGates.swift \
  || fail "get_status 必须向 AI 报同一份 Pro 提醒"

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
[ "$(count 'ExportWatermarkNotice(isAudioOnly: isAudioOnly)' "${SHEET}")" -eq 1 ] \
  && grep -qF 'if !isAudioOnly, WatermarkPolicy.required(byLicence: account.exportsWithWatermark) {' "${HINTS}" \
  || fail "${SHEET}：底栏要挂授权提醒，只出声音时只隐藏水印说明"
[ "$(count 'result["watermark"] = .string(SkyCutGates.watermarkNote(license: SkyStudioAccount.shared.license))' "${EXPORT_TOOLS}")" -eq 1 ] \
  && [ "$(count 'detail["watermark"] = .string(SkyCutGates.watermarkNote(license: SkyStudioAccount.shared.license))' "${EXPORT_TOOLS}")" -eq 1 ] \
  && [ "$(count 'watermarked: exporter.watermarked' "${EXPORT_TOOLS}")" -eq 1 ] \
  || fail "${EXPORT_TOOLS}：export_video 开始时（会带）和做完时（带了）都要按此刻授权告诉 AI 水印的事"
[ "$(count 'result["skycut_plan"] = SkyCutGates.statusJSON(' "${STATUS_TOOLS}")" -eq 1 ] \
  || fail "${STATUS_TOOLS}：get_status 要报 skycut_plan（没开通时它照常回，另外只有说明书 skycut_guide）"
# 说明书不等授权问完：aiRefusal 里放行它的那一句要在等授权（settledLicense）之前（docs/bugfixes/2026-11-10-guide-waits-for-license.md）。
REFUSAL_BODY="$(awk '/func aiRefusal\(for tool: MCPToolName\) async -> String\? \{/,/^    \}/' "${ACCOUNT}")"
EARLY_AT="$(grep -nF 'if SkyCutGates.answeredBeforeLicenseCheck.contains(tool) { return nil }' <<<"${REFUSAL_BODY}" | cut -d: -f1 || true)"
WAIT_AT="$(grep -nF 'await settledLicense(' <<<"${REFUSAL_BODY}" | cut -d: -f1 || true)"
if [ -z "${EARLY_AT}" ] || [ -z "${WAIT_AT}" ] || [ "${EARLY_AT}" -gt "${WAIT_AT}" ]; then
  fail "${ACCOUNT}：aiRefusal 要在等授权（第 ${WAIT_AT:-?} 行）之前放行 answeredBeforeLicenseCheck 里的工具（现在：${EARLY_AT:-没有}），不然说明书要等钥匙串和 /me"
fi

# 6. 交任务、取消任务只经 SkyStudioJobRun。
RUN="Sources/SrtFlow/SkyStudio/SkyStudioJobRun.swift"
for call in 'submit\([^)]*, key:' 'cancel\([^)]*, key:'; do
  users="$(code_files_with "${call}" | grep -v "^${API}\$" | LC_ALL=C sort | tr '\n' ' ')"
  [ "${users}" = "${RUN} " ] || fail "SkyStudioAPI 的 ${call%%\\(*} 只许 SkyStudioJobRun 调（满了等着再交、停的规矩都在那里），实际在：${users:-没有}"
done

# 6b. 领槽只经 SkyStudioJobSlots（声音 PR 4，SkyCut 声音方案 8.2）：SkyStudioJobRun 在交之前领、这一单结束就还；只 GET 的恢复不领；
#     一段旁白的各批由 SkyStudioVoiceBatchQueue 按原来的顺序领、交给 SkyStudioJobRun 拿着，记下这一批出了什么事之后才还（后面排着的批看得见）；
#     槽数只有 SkyStudioAccount 照 /me 改；全 App 只有一份（别处不另建）。
SLOTS="Sources/SrtFlow/SkyStudio/SkyStudioJobSlots.swift"
QUEUE="Sources/SrtFlow/SkyStudio/SkyStudioVoiceBatchQueue.swift"
[ -f "${SLOTS}" ] && [ -f "${QUEUE}" ] || fail "找不到 ${SLOTS} 或 ${QUEUE}"
users="$(code_files_with '\.acquire\(kind:' | LC_ALL=C sort | tr '\n' ' ')"
[ "${users}" = "${RUN} ${QUEUE} " ] || fail "领槽（slots.acquire）只许 SkyStudioJobRun 和 SkyStudioVoiceBatchQueue 调，实际在：${users:-没有}"
users="$(code_files_with 'SkyStudioJobSlots\(' | LC_ALL=C sort | tr '\n' ' ')"
[ "${users}" = "${SLOTS} " ] || fail "SkyStudioJobSlots 全 App 只许一份（static let shared），别处另建了：${users:-没有}"
users="$(code_files_with 'SkyStudioJobSlots\.shared\.adopt' | LC_ALL=C sort | tr '\n' ' ')"
[ "${users}" = "${ACCOUNT} " ] || fail "槽数只许 SkyStudioAccount 照 /me 改（adopt），实际在：${users:-没有}"
grep -qF 'let held = try await claimSlot(for: request.kind, onUpdate: onUpdate)' "${RUN}" && grep -qF 'defer { held?.release() }' "${RUN}" \
  || fail "${RUN}：run 要在交之前领槽、这一单结束就还"
[ "$(count 'claimSlot(' "${RUN}")" -eq 2 ] || fail "${RUN}：只有 run 领槽（resume 只 GET 原单、不领）"
grep -qF 'lease = try await slots.acquire(kind: kind)' "${QUEUE}" && grep -qF 'runner.lease = lease' Sources/SrtFlow/SkyStudio/SkyStudioVoiceCloudBatches.swift \
  || fail "一段旁白的各批要在 SkyStudioVoiceBatchQueue 里按顺序领槽、交给 SkyStudioJobRun 拿着"
# 只看交一批的那个函数（submit）：出了事那一支先 record、再 release。
SUBMIT_BODY="$(sed -n '/private func submit(/,/^    }$/p' "${QUEUE}")"
RECORD_AT="$({ grep -nF 'record(index, error)' <<<"${SUBMIT_BODY}" || true; } | head -1 | cut -d: -f1)"
RELEASE_AT="$({ grep -nF 'lease.release()' <<<"${SUBMIT_BODY}" || true; } | head -1 | cut -d: -f1)"
if [ -z "${RECORD_AT}" ] || [ -z "${RELEASE_AT}" ] || [ "${RECORD_AT}" -ge "${RELEASE_AT}" ]; then
  fail "${QUEUE}：一批出了事要先记下再还槽（不然排在后面的批领到槽时看不见，照样交出去）"
fi

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
[ "$(count 'record(store, credits)' "${JOB_GATE}")" -eq 4 ] || fail "${JOB_GATE}：记账 record(store, credits) 应恰好四处（额度内直接做 / 收下令牌 / 配音整批预留 / 声音库的一次性费用点过头）"
movers="$(code_files_with 'SkyStudioSpendStore' | while read -r file; do
  # 只认真动账本的写法（SkyStudioSpendStore.shared.record / refund、拿着它的 store.record / refund）；held?.refund() 是经 SkyStudioHeldCredits 退。
  if grep -qE '(SkyStudioSpendStore\.shared|store)\.(record|refund)\(' <<<"$(sed 's,//.*,,' "${file}")"; then echo "${file}"; fi
done | grep -v "^${SPEND}\$" | LC_ALL=C sort | tr '\n' ' ')"
HELD="Sources/SrtFlow/SkyStudio/SkyStudioHeldCredits.swift"
expected_movers="$(printf '%s\n' "${JOB_GATE}" "${HELD}" | LC_ALL=C sort | tr '\n' ' ')"
[ "${movers}" = "${expected_movers}" ] || fail "积分的账只许在 SkyStudioJobGate（AI 起的）和 SkyStudioHeldCredits（面板起的、按实收换、退回）里动，实际在：${movers:-没有}"
prompters="$(code_files_with '\.prompting' | grep -v "^${JOB_ACCESS}\$" | LC_ALL=C sort | tr '\n' ' ')"
[ "${prompters}" = "${UP_JOB} " ] || fail "会弹钥匙串授权框的那一档（.prompting）只许面板起的 upscale 任务用（UpscaleJob），实际在：${prompters:-没有}"
grep -qE 'case .generateMedia, .upscaleClip.*return .skystudio' "${CATALOG}" || fail "${CATALOG}：upscale_clip 要属于 skystudio 提供方（调用时核对 Key）"
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
STATUS_ROWS="Sources/SrtFlow/CloudMedia/CloudTasksActivity.swift"
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
grep -qE 'case .generateMedia, .upscaleClip.*return .skystudio' "${CATALOG}" || fail "${CATALOG}：generate_media 要属于 skystudio 提供方（Key、授权、积分在调用时核对）"
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
grep -qF 'let generation = SkyStudioGenerationActivity.shared' "${STATUS_ROWS}" || fail "${STATUS_ROWS}：任务入口没订阅 Sky Studio 的生成任务"
for file in "${GEN_TOOL}" "${GEN_RUN}" "${GEN_ACTIVITY}"; do
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog' "${file}"; then
    fail "${file}：弹了模态框 —— 要用户点头就回确认码（SkyStudioJobGate.decide → needs_confirmation），AI 在等的时候弹框没人点"
  fi
done

# 9b. 多模型和参考限制必须接到生产路径，不能只让纯函数自检通过。
REFERENCE_FILES="Sources/SrtFlow/SkyStudio/SkyStudioReferenceFiles.swift"
CONTROLS="Sources/SrtFlow/SkyStudio/SkyStudioGenerationControls.swift"
APPROVAL="Sources/SrtFlow/SkyStudio/SkyStudioApproval.swift"
for file in "${REFERENCE_FILES}" "${CONTROLS}" "${APPROVAL}"; do
  [ -f "${file}" ] || fail "找不到 ${file}"
done
grep -qF 'await SkyStudioModelStatus.read(' "${STATUS_TOOLS}" || fail "get_status 没接只读模型查询"
grep -qF 'SkyStudioModelPolicy.select(catalog:' "${GEN_TOOL}" || fail "生成没有按偏好 / 完整输入挑模型"
READ_AT="$(line_of 'AIWorkspace.shared.confirmReading(picked.files.map' "${GEN_TOOL}")"
MEASURE_AT="$(line_of 'await SkyStudioReferenceFiles.measure(' "${GEN_TOOL}")"
if [ -z "${READ_AT}" ] || [ -z "${MEASURE_AT}" ] || [ "${READ_AT}" -ge "${MEASURE_AT}" ]; then
  fail "全部参考文件必须先确认读取再测量"
fi
grep -qF 'await SkyStudioReferenceFiles.upload(references' "${GEN_RUN}" || fail "真实生成没有上传完整参考组"
grep -qF '"references": .array(job.references)' "${APPROVAL}" || fail "消费确认没绑定参考顺序"
if grep -qE 'SkyStudioGenerationFallback|reserveReplacement\(' "${GEN_RUN}"; then
  fail "生成不许在失败后自动切模型或再收费"
fi
grep -qF 'SkyStudioGenerationRequests.begin(' "${GEN_TOOL}" || fail "重复操作没复用同一本机任务"
grep -qF 'idempotencyKey: idempotencyKey' "${GEN_RUN}" || fail "没有把稳定幂等键送到真实生成路径"
grep -qF 'applyBilling(done)' "${GEN_RUN}" || fail "生成没接服务端 billing"
grep -qF 'job.refresh = ' "${GEN_RUN}" || fail "get_job 没有核查原单的接线"
grep -qF 'payload["submission_keys"]' "${GEN_RUN}" || fail "未知提交未留下幂等 key"

# 图片操作仍走生成任务；实际字节决定落盘格式，不能只测纯值却漏接生产下载之后。
grep -qF 'SkyStudioImageOperation.problem(model: model' "${CONTROLS}" || fail "图片操作未接单图 / 角度 / 倍率合同"
grep -qF 'SkyStudioImageOperation.names' "${CONTROLS}" || fail "图片操作枚举未接生产参数解析"
grep -qF 'try SkyStudioImageOperation.validateRoute(args)' "${GEN_TOOL}" || fail "图片操作未在官方分派前拒绝 film"
grep -qF 'if let operation { body["operation"] = .string(operation) }' Sources/SrtFlow/SkyStudio/SkyStudioJob.swift \
  || fail "图片操作没有进入报价和提交，也无法绑定确认码"
grep -qF 'SkyStudioImageResult.format(at: downloaded)' "${GEN_RUN}" \
  && grep -qF 'SkyStudioImageResult.finalize(downloaded, format: format)' "${GEN_RUN}" \
  || fail "生产下载之后未按真实图片字节确定扩展名"
grep -qF 'operation != "generate"' "${REFERENCE_FILES}" || fail "特殊图片操作没有把 image 接到 image_url"

# 9c. 官方路线必须接到同一个生产运行器：显式准备、精确报价、先落回执、恢复只查原单。
OFFICIAL="Sources/SrtFlow/SkyStudio/SkyStudioOfficialGenerateTool.swift"
RECOVERY="Sources/SrtFlow/SkyStudio/SkyStudioOfficialRecoveryRun.swift"
for file in "${OFFICIAL}" "${RECOVERY}"; do [ -f "${file}" ] || fail "找不到 ${file}"; done
grep -qF 'if SkyStudioOfficialGenerateTool.applies(args)' "${GEN_TOOL}" || fail "generate_media 没有分派官方准备/报价/提交"
grep -qF 'SkyStudioOfficialPreparation.start(generation:' "${OFFICIAL}" || fail "官方入口没接显式真实引用准备"
grep -qF 'SkyStudioOfficialPrepared.shared.reviewedQuote(' "${OFFICIAL}" || fail "官方提交没使用精确双缝报价缓存"
grep -qF 'SkyStudioOfficialRecovery.resume(' "${OFFICIAL}" || fail "官方入口没先找持久原单"
grep -qF 'SkyStudioGenerationRequests.completeStarted(operationKey, result: response, scope: stage)' "${OFFICIAL}" \
  || fail "官方提交只能缓存已启动任务，确认问题与预算阻止不能占住同一个幂等 key"
[ "$(count 'SkyStudioGenerationRequests.complete(operationKey, result: response, scope: stage)' "${OFFICIAL}")" -eq 1 ] \
  || fail "官方新提交不可无条件缓存；唯一未筛选 response 是显式准备任务"
grep -qF 'official?.request ?? generation.job(' "${GEN_RUN}" || fail "生产运行器丢掉已审查的官方精确请求"
grep -qF 'official.recovery.received(status)' "${GEN_RUN}" || fail "生产运行器没保存已知原单回执"
grep -qF 'official?.recovery.delivered(' "${GEN_RUN}" || fail "生成结果没保存可恢复身份"
grep -qF 'await runner.resume(serverID)' "${RECOVERY}" || fail "重启恢复没有只查原单"
if grep -qE 'runner\.run\(|api\.submit\(' "${RECOVERY}"; then fail "重启恢复不许重新 POST 收费"; fi
grep -qF '"prepare_references"' Sources/SrtFlow/AIProjectBinding.swift || fail "官方准备没绑定会话拥有的工程"
grep -qF '["film", "prepared_references", "quote_token", "seam_review"]' Sources/SrtFlow/AIProjectBinding.swift || fail "官方报价/提交没绑定工程"
grep -qF 'SkyStudioOfficialPrepared.digest(.string(approval))' "${OFFICIAL}" || fail "项目批准不许持久化原始 pin"
RECEIPT_AT="$(line_of 'await SkyStudioOfficialRecovery.create(receipt)' "${OFFICIAL}")"
START_AT="$(line_of 'let job = run.start()' "${OFFICIAL}")"
VALIDATE_AT="$(line_of 'try SkyStudioOfficialRequest.validate(request, submitting: true)' "${GEN_RUN}")"
SENT_AT="$(line_of '} else { requestSent = true }' "${GEN_RUN}")"
if [ -z "${RECEIPT_AT}" ] || [ -z "${START_AT}" ] || [ "${RECEIPT_AT}" -ge "${START_AT}" ]; then fail "官方运行器前必须先持久化防重放回执"; fi
if [ -z "${VALIDATE_AT}" ] || [ -z "${SENT_AT}" ] || [ "${VALIDATE_AT}" -ge "${SENT_AT}" ]; then fail "官方本地校验必须早于标记已提交"; fi
grep -qF 'runner.beforeSubmit = ' "${GEN_RUN}" || fail "官方运行器没接每次 POST 前核对"
grep -qF 'try await validateBeforeSubmit()' "${RUN}" || fail "容量重试没有再次执行 POST 前核对"
grep -qF 'await SkyStudioOfficialSubmission.validate(' "${GEN_RUN}" || fail "官方 POST 前未核对原始状态"
OFFICIAL_SUBMIT="Sources/SrtFlow/SkyStudio/SkyStudioOfficialSubmission.swift"
grep -qF 'OpenProjects.shared.all.contains' "${OFFICIAL_SUBMIT}" || fail "官方任务只看 weak，未拒绝已关闭工程"
grep -qF 'try await SkyStudioOfficialGenerateTool.validateScope(' "${OFFICIAL_SUBMIT}" || fail "官方重试未重读账户与工程身份"
grep -qF 'let currentSources = try SkyStudioOfficialPreparation.sources(references)' "${OFFICIAL_SUBMIT}" || fail "官方重试未读取原文件当前身份"
grep -qF 'currentSources == operation.sources' "${OFFICIAL_SUBMIT}" || fail "官方重试未重核原文件身份"
grep -qF 'try SkyStudioOfficialAuthority.recheck(operation.authority,' "${OFFICIAL_SUBMIT}" || fail "官方每次 POST 前未核对权威制作状态"
grep -qF 'try await SkyStudioOfficialAuthority.snapshot(request:' "${OFFICIAL}" || fail "官方新报价未读取已保存制作计划"
grep -qF 'context: ["authority": authority,' "${OFFICIAL}" || fail "官方批准未绑定当前权威制作身份"
grep -qF 'operation.expiresAt > Date()' "${OFFICIAL_SUBMIT}" || fail "官方重试未重核报价有效期"
grep -qF 'try Task.checkCancellation()' "${OFFICIAL_SUBMIT}" || fail "官方 POST 前最后核对没有检查异步等待期间的取消"
CAPTURE_AT="$(line_of 'let projectGeneration = project.documentGeneration' "${OFFICIAL}")"
KEY_AT="$(line_of 'let key = try await readKey()' "${OFFICIAL}")"
if [ -z "${CAPTURE_AT}" ] || [ -z "${KEY_AT}" ] || [ "${CAPTURE_AT}" -ge "${KEY_AT}" ]; then fail "官方入口等待密钥前必须快照工程身份"; fi
grep -qF 'project.documentGeneration == projectGeneration' "${OFFICIAL}" || fail "官方入口等待密钥后必须拒绝已换文档"
grep -qF 'guard status.jobID == id else' "${API}" || fail "GET 原单必须在交给状态/结算回调前核对服务端 job_id"

# 10. 云端配音：回任务号之前整段报价一次、整体预留（额度不够当场停、不问、不换声音），返回任务号；每批照报价带回同一个 params.plan；
#     结束只入轨一整步（SkyCut 声音方案 4.2；2026-11-10 声音 PR 3 把报价从任务里挪到回任务号之前）。
VOICE_RUN="Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverRun.swift"
VOICE_START="Sources/SrtFlow/SkyStudio/SkyStudioVoiceoverStart.swift"
VOICE_PLAN="Sources/SrtFlow/SkyStudio/SkyStudioVoicePlan.swift"
VOICE_INPUT="Sources/SrtFlow/AIVoiceoverInput.swift"
VOICE_BUDGET="Sources/SrtFlow/SkyStudio/SkyStudioVoiceBudget.swift"
VOICE_CLOUD="Sources/SrtFlow/SkyStudio/SkyStudioVoiceCloudBatches.swift"
VOICE_SERVICES="Sources/SrtFlow/SkyStudio/SkyStudioVoiceServices.swift"
VOICE_CHECKPOINT="Sources/SrtFlow/SkyStudio/SkyStudioVoiceCheckpoint.swift"
for file in "${VOICE_RUN}" "${VOICE_START}" "${VOICE_INPUT}" "${VOICE_BUDGET}"; do
  [ -f "${file}" ] || fail "找不到 ${file}"
  if grep -nE 'NSAlert|runModal|beginSheetModal|NSOpenPanel|NSSavePanel|\.alert\(|confirmationDialog|AIConfirmations' "${file}"; then
    fail "${file}：配音额度不够应退本机（克隆报错），不能停下来等确认"
  fi
done
grep -qF 'switch try await SkyStudioVoiceoverStart.start(input, project: project) {' "${ROUTER}" || fail "配音路由没有先经 SkyStudioVoiceoverStart 报价再起任务"
grep -qF 'SkyStudioVoiceoverRun(input: ready, project: project, prepared: prepared, services: services).start()' "${VOICE_START}" \
  || fail "整段报价、预留之后没有起任务"
# 报价在预留之前、预留在起任务之前（中间不再有会失败的步骤，预留不会落在半路）。
QUOTE_AT="$(line_of 'quote = try await services.api.quote(draft.segment, key: resolved.key)' "${VOICE_START}")"
RESERVE_AT="$(line_of 'guard let budget = SkyStudioVoiceBudget.reserve(plan.batchCredits) else {' "${VOICE_START}")"
RUN_AT="$(line_of 'SkyStudioVoiceoverRun(input: ready, project: project, prepared: prepared, services: services).start()' "${VOICE_START}")"
if [ -z "${QUOTE_AT}" ] || [ -z "${RESERVE_AT}" ] || [ -z "${RUN_AT}" ] || [ "${QUOTE_AT}" -ge "${RESERVE_AT}" ] || [ "${RESERVE_AT}" -ge "${RUN_AT}" ]; then
  fail "云端配音要先整段报价、再整体预留、最后起任务（回任务号之前）"
fi
grep -qF 'SkyStudioVoiceRequests.segmentQuote(kind: kind, model: model, voice: voice, batches: speech.map(\.prompt), lines: lines)' "${VOICE_PLAN}" \
  && grep -qF 'try SkyStudioVoiceRequests.batch(index, of: draft.segment, quote: quote)' "${VOICE_PLAN}" \
  || fail "整段报价没有经 segmentQuote（params.batches），或每批没有照报价带回同一个 params.plan"
grep -qF 'SkyStudioJobRun(api: api, key: try await resolvedKey())' "${VOICE_CLOUD}" && grep -qF 'let done = try await runner.run(request)' "${VOICE_CLOUD}" \
  && grep -qF 'run.checkpoint = ' "${VOICE_CLOUD}" || fail "云端配音没有复用统一任务执行器并持久化原单身份"
grep -qF 'switch await SkyStudioJobKey.key(.silent)' "${VOICE_SERVICES}" || fail "云端配音不得弹钥匙串框"
grep -qF 'SkyStudioVoiceBudget.reserve(missingCredits)' "${VOICE_CLOUD}" || fail "恢复补批次没有先预留这几批的报价"
grep -qF 'SkyStudioJobGate.reserveWithoutAsking(credits: total' "${VOICE_BUDGET}" || fail "整批配音没有统一判断每日额度"
[ "$(count 'AIUndoGrouping.step(project.effectiveUndoManager)' "${VOICE_RUN}")" -eq 1 ] || fail "云端配音落地必须只有一整步撤销"
for token in 'SkyStudioGenerationActivity.shared.add(status)' 'SkyStudioGenerationActivity.shared.remove(status)' 'OpenProjects.shared.all.contains' 'submission_keys'; do
  grep -qF "${token}" "${VOICE_RUN}" || fail "配音缺少状态 / 工程归属 / 未知提交 / 原音频保留：${token}"
done
grep -qF 'credits_unknown' "${VOICE_CHECKPOINT}" && grep -qF 'rawFile = file' "${VOICE_CLOUD}" \
  && grep -qF 'SkyStudioVoiceRecovery.resumeIfAsked' "${ROUTER}" || fail "配音必须持久保留原音频、未知账和 MCP 恢复入口"
# 假 Key 启动钩子必须同时限定独立 bundle id 和回环；生产 / Beta 不得装入。
grep -qF 'hasSuffix(".skystudiosmoke") == true' "${ACCOUNT}" && grep -qF 'SkyStudioAPI.isLoopback(host)' "${ACCOUNT}" \
  || fail "假 Sky Studio Key 钩子没有同时限定测试身份和回环"

# 角色 A：服务器引用与本机文件分开；报价选择进入确认身份、提交和 get_job。
CHAR_READ="Sources/SrtFlow/SkyStudio/SkyStudioCharacterReadTool.swift"
CHAR_MODEL="Sources/SrtFlow/SkyStudio/SkyStudioCharacter.swift"
CHAR_REFS="Sources/SrtFlow/SkyStudio/SkyStudioCharacterGeneration.swift"
CHAR_CACHE="Sources/SrtFlow/SkyStudio/SkyStudioCharacterAccess.swift"
grep -qF 'case .listCharacters, .getCharacter: return try await SkyStudioCharacterReadTool.read(tool, args)' "${ROUTER}" || fail "角色只读路由未接上"
grep -qF 'SkyStudioCharacterAccess.invalidate()' "${ACCOUNT}" || fail "换 Key 未清角色和待确认内容"
grep -qF 'AIConfirmations.shared.discard(prefix: "skystudio:")' "${CHAR_CACHE}" || fail "换账号未废掉收费批准"
grep -qF 'if observed == epoch' "${CHAR_CACHE}" || fail "旧账号迟到请求能回填角色缓存"
grep -qF 'SkyStudioCharacterGeneration.accept(quote, generation: &generation, references: &references, model: model)' "${GEN_TOOL}" || fail "生成未接实际角色报价"
grep -qF 'fields["character_revision"]' Sources/SrtFlow/SkyStudio/SkyStudioApproval.swift || fail "确认身份漏角色 revision"
grep -qF 'body["character_revision"]' Sources/SrtFlow/SkyStudio/SkyStudioJob.swift || fail "提交漏角色 revision"
grep -qF 'payload["character_usage"]' "${GEN_RUN}" || fail "get_job 漏实际角色选择"
if grep -E 'api\.(upload|download)|FileManager' "${CHAR_READ}" "${CHAR_REFS}" >/dev/null; then fail "角色服务器引用混进本机传输路径"; fi
for source in SkyStudioCharacter.swift SkyStudioCharacterAPI.swift SkyStudioCharacterGeneration.swift SkyStudioCharacterAccess.swift; do
  grep -qF "Sources/SrtFlow/SkyStudio/${source}" scripts/check-sky-studio.sh || fail "角色生产值未编进假服务器检查：${source}"
done

# 角色 B：生产工作流、付费闸、持久原单、免费删除确认与只读恢复接线。
CHAR_MANAGE="Sources/SrtFlow/SkyStudio/SkyStudioCharacterManageTool.swift"
CHAR_RUN="Sources/SrtFlow/SkyStudio/SkyStudioCharacterRun.swift"
CHAR_WORKFLOW="Sources/SrtFlow/SkyStudio/SkyStudioCharacterWorkflow.swift"
CHAR_RECEIPT="Sources/SrtFlow/SkyStudio/SkyStudioCharacterReceipt.swift"
grep -qF 'case .manageCharacters: return try await SkyStudioCharacterManageTool.run(args, project)' "${ROUTER}" || fail "角色写工具未接生产入口"
grep -qF 'SkyStudioCharacterJobs.restore(id, project: nil)' Sources/SrtFlow/AIExportTools.swift || fail "get_job 未接跨重启角色原单"
grep -qF 'SkyStudioJobGate.decide(credits: plan.quote!.credits' "${CHAR_MANAGE}" || fail "付费角色未过统一确认 / 硬预算闸"
grep -qF 'SkyStudioCharacterJobs.persist(receipt, creating: true)' "${CHAR_MANAGE}" || fail "角色任务未先持久化确认身份"
grep -qF 'receipt.recovery(explicitFreeImport: retryFreeImport)' "${CHAR_RUN}" || fail "角色恢复未使用原单恢复政策"
grep -qF 'if isFree && explicitFreeImport { return .freeImport }' "${CHAR_RECEIPT}" || fail "只有显式免费导入可以重送原 body/key"
grep -qF 'case originalJob(String), libraryRead(String)' "${CHAR_RECEIPT}" || fail "换图恢复必须只读当前角色"
grep -qF 'receipt.mutation = prepared.mutation' "${CHAR_RUN}" || fail "换图上传描述未进入回执"
grep -qF 'runner.cancellable = false' "${CHAR_WORKFLOW}" || fail "原生角色不能调服务器 cancel"
grep -qF 'runner.checkpoint = checkpoint' "${CHAR_WORKFLOW}" || fail "原生角色响应未即时保存原 job_id"
grep -qF 'SkyStudioCharacterJobReport.fields(status, freeImport: isFree)' "${CHAR_RECEIPT}" || fail "角色源图 / 整理 / 账单未分开保留"
grep -qF 'AIFileTools.confirmCharacterDeletion' "${CHAR_MANAGE}" || fail "免费角色删除未走现有确认入口"
grep -qF 'SkyStudioReceiptFile.persist(data, at: file)' "${CHAR_RECEIPT}" || fail "角色回执没用共用私有原子字节边界"
RECOVER_AT="$(line_of 'if isJob && !quoteOnly, let prior = try await SkyStudioCharacterJobs.read(localID)' "${CHAR_MANAGE}")"
FILES_AT="$(line_of 'let paths = try SkyStudioCharacterPlan.paths' "${CHAR_MANAGE}")"
if [ -z "${RECOVER_AT}" ] || [ -z "${FILES_AT}" ] || [ "${RECOVER_AT}" -ge "${FILES_AT}" ]; then fail "必须先恢复持久原单，再碰当前文件 / 角色 / 报价"; fi
for source in SkyStudioCharacterNativeRequest.swift SkyStudioCharacterWorkflow.swift SkyStudioCharacterReceipt.swift SkyStudioCharacterJobReport.swift; do
  grep -qF "Sources/SrtFlow/SkyStudio/${source}" scripts/check-sky-studio.sh || fail "角色 B 生产路径没有编进假服务器检查：${source}"
done

# 11. 声音库（声音 PR 6）和全部权限下的长期授权（声音 PR 7）：拆在自己的文件里，同一个 shell 里 source（主脚本快到 600 行了）。
# shellcheck source=checks/sky-studio-wiring/voice-library.sh
source checks/sky-studio-wiring/voice-library.sh

# 12. 声音库的界面（声音 PR 8）：拆在 checks/sky-studio-wiring/voice-library-ui.sh（这个文件到了行数上限），共用上面的 fail / code_files_with 和路径变量。
source checks/sky-studio-wiring/voice-library-ui.sh

# 13. 声音库的收费单只下一次、账只记一次（2026-11-11 审查 #362 / #367 之后）：拆在 checks/sky-studio-wiring/voice-library-orders.sh。
source checks/sky-studio-wiring/voice-library-orders.sh

# 0.18.62 真积分验收后的结果边界：下面每份纯值规则都必须接到实际工具 / 下载 / 刷新路径。
grep -qF 'characters.map(SkyStudioCharacterSummary.json)' Sources/SrtFlow/SkyStudio/SkyStudioCharacter.swift || fail "角色列表绕过有界摘要"
grep -qF 'SkyStudioGenerationName.stem(' Sources/SrtFlow/SkyStudio/SkyStudioGenerateTool.swift || fail "图片操作未按源图起名"
grep -qF 'detail.merge(localImage.dimensions)' Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift || fail "图片实际尺寸未进入最终 get_job 结果"
grep -qF 'completionMessage(resuming: plan == nil, previousStatus: job.status.rawValue)' "${CHAR_RUN}" || fail "角色完成后刷新未区分正常完成与原单恢复"
grep -qF 'completionMessage(resuming: plan == nil)' "${CHAR_RUN}" || fail "角色首次完成未按实际恢复来源选文案"

# 守卫自己：总闸只许在最后，所有检查都在它前面（2026-11-10 案例：总闸夹在中间时，后面三节的 ✗ 打出来、脚本照样绿，
# docs/bugfixes/2026-11-10-sky-studio-wiring-checks-after-exit.md）。
gate_at="$(grep -n 'if \[ "\${FAILED}" -ne 0 \]; then' "$0" | tail -1 | cut -d: -f1 || true)"
last_fail="$(grep -nE '(\|\| |\{ |^ *)fail "' "$0" | tail -1 | cut -d: -f1 || true)"
if [ -z "${gate_at}" ] || [ -z "${last_fail}" ] || [ "${last_fail}" -gt "${gate_at}" ]; then
  fail "$0：总闸（if FAILED）要在最后一条检查之后（总闸第 ${gate_at:-?} 行、最后一条检查第 ${last_fail:-?} 行）"
fi
last_part="$(grep -n '^source checks/sky-studio-wiring/' "$0" | tail -1 | cut -d: -f1 || true)"
if [ -z "${last_part}" ] || [ -z "${gate_at}" ] || [ "${last_part}" -gt "${gate_at}" ]; then
  fail "$0：拆出去的几节（source checks/sky-studio-wiring/…）也要在总闸之前装进来"
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "见 docs/architecture/sky-studio-account.md 和 docs/architecture/sky-studio-jobs.md" >&2
  exit 1
fi
echo "✓ sky-studio-wiring：地址只在 SkyStudioAPI、原始硬件 UUID 不出本机、后台不弹钥匙串、设置和启动都接上了、照授权拦接在该接的地方、任务只经 SkyStudioJobRun、领槽只经 SkyStudioJobSlots、Key 只发给 Sky Studio、upscale 和生成的把关 / 积分 / 清单 / 路由接对了、声音库的授权 / 长期授权 / 路径 / 服务商 id / 不退本机守住了、声音库的界面和 AI 的工具走同一条路、声音库的收费单只下一次"
