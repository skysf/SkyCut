#!/usr/bin/env bash
# Confirmation entrypoints and file naming, sourced by check-mcp before compilation.
echo "==> 什么时候问：按操作权限处理文件与草稿越档；改权限 / 提高硬预算始终确认"
# 2026-09-28 用户拍板（docs/plans/2026-09-27-mcp.md 第 34 条）：删进废纸篓先问；读点名文件夹以外的文件问一次，同意了就记住
# 那个文件夹（AIReadGrants），以后不问；从不覆盖（撞名加编号）这一样不问。2026-10-17（AI 多开方案板 9）：fal 超每日额度 / 价格不明
# 从提示条改成同一套确认码。2026-10-28（收费方案第 6 刀）：generate_media、upscale_clip 改走 Sky Studio（SkyStudioJobGate）；fal 那一处
# （旧生成把关）跟着生成一起删了。2026-11-01：每日预算是硬上限（超了回 daily_budget_exceeded、不发码，配旁白也不退档），SkyStudioJobGate
# 只为请求批准模式下超出低成本草稿的、声音库的授权和一次性费用发码；改权限 / 提高硬预算走 AISettingsApproval，全部权限下也问。
ASKERS="$(grep -rl 'AIConfirmations.shared.ask(' Sources/SrtFlow | xargs -n1 basename | sort | tr '\n' ' ')"
if [ "${ASKERS}" != "AIFileTools.swift AIMotionApproval.swift AISettingsApproval.swift AIWorkspace.swift SkyStudioJobGate.swift " ]; then
  echo "✗ 会回 needs_confirmation 的地方变了：${ASKERS}（只许删文件的 AIFileTools、读别处文件的 AIWorkspace、Sky Studio 花积分的 SkyStudioJobGate、改设置的 AISettingsApproval）" >&2
  exit 1
fi
if [ "$(grep -c 'AIReadGrants.shared.remember(' Sources/SrtFlow/AIWorkspace.swift || true)" -ne 1 ]; then
  echo "✗ AIWorkspace.confirmReading 点过头之后没记住那个文件夹：同一个文件夹里的文件会一次次地问" >&2
  exit 1
fi
for wiring in "Sources/SrtFlow/AIExportTools.swift:1" "Sources/SrtFlow/AIProjectTools.swift:2" "Sources/SrtFlow/AIProjectOpenTools.swift:1"; do
  file="${wiring%%:*}"
  want="${wiring##*:}"
  if [ "$(grep -c 'ExportFileName.unoccupied' "${file}" || true)" -lt "${want}" ]; then
    echo "✗ ${file} 撞名没走 ExportFileName.unoccupied（应有 ${want} 处）：AI 会覆盖文件、或者又回头问" >&2
    exit 1
  fi
done
echo "   ✓ 确认入口为文件读取 / 废纸篓、草稿审批和设置权限；日预算不可越额；文件撞名加编号"

