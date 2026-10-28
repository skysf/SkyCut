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
# 规矩见 docs/architecture/sky-studio-account.md。
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

if [ "${FAILED}" -ne 0 ]; then
  echo "见 docs/architecture/sky-studio-account.md" >&2
  exit 1
fi
echo "✓ sky-studio-wiring：地址只在 SkyStudioAPI、原始硬件 UUID 不出本机、后台不弹钥匙串、设置和启动都接上了、照授权拦接在该接的地方"
