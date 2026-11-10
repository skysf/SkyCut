#!/usr/bin/env bash
# scripts/check-mcp.sh 的一节（由它 source 进来，不单独跑）：克隆参考录音的有声门限是和 Sky Studio 的跨仓库合同
# （SkyCut 0.0056，服务器故意放宽到 0.0055）。纯值和真读真写在 checks/MCP/VoiceReferenceChecks.swift /
# VoiceReferenceFileChecks.swift；这里只钉「它是单独写死的常量」—— 比数值查不出「又借回了 AIVoiceLevel.activeFloor」
# （现在两个值碰巧都是 0.0056），以后调配音响度时合同就会悄悄跟着变。约束见 docs/architecture/voice-library.md 第二节，
# 案例 docs/bugfixes/2026-11-10-voice-reference-floor-borrowed-from-voice-level.md。

echo "==> 克隆参考录音的有声门限：VoiceReferenceWindow 里单独写死 0.0056，不借配音响度的常量"
VOICE_WINDOW="Sources/SrtFlow/VoiceReferenceWindow.swift"
# 只看代码，注释里提到 AIVoiceLevel（说明为什么不借它）不算。
VOICE_WINDOW_CODE="$(sed 's,//.*,,' "${VOICE_WINDOW}")"
if [ "$(grep -c 'static let speechRMSFloor: Float = 0\.0056$' <<<"${VOICE_WINDOW_CODE}" || true)" -ne 1 ]; then
  echo "✗ ${VOICE_WINDOW} 没有单独写死 speechRMSFloor = 0.0056：这是和 Sky Studio 的合同（服务器放宽到 0.0055）" >&2
  exit 1
fi
if [ "$(grep -c 'AIVoiceLevel' <<<"${VOICE_WINDOW_CODE}" || true)" -ne 0 ]; then
  echo "✗ ${VOICE_WINDOW} 的代码用了 AIVoiceLevel：参考录音的门限不许跟着配音响度变" >&2
  exit 1
fi
echo "   ✓ speechRMSFloor 单独写死 0.0056，代码里不碰 AIVoiceLevel"
