#!/usr/bin/env bash
# scripts/check-mcp.sh 的一节（由它 source 进来，不单独跑）：视频的声音单独放（J/L cut）接到生产路径上没有。纯值在
# checks/MCP/ClipSoundChecks.swift 里测，这里只扫「真的调了它」。约束见 docs/architecture/ai-control-mcp.md 第四节第 47 条。

echo "==> 视频的声音单独放：分离音频界面和 AI 同一份规则、alone 只挡自己的链接伙伴"
# 界面上的 Detach Audio 和 add_clips 的 sound=separate 都经 ClipSoundSeparation.separate。
if [ "$(grep -c 'ClipSoundSeparation.separate(id, in: &state)' 'Sources/SrtFlow/VideoEditProject+ClipSound.swift' || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/VideoEditProject+ClipSound.swift 的分离音频不经 ClipSoundSeparation：界面和 AI 分家了" >&2
  exit 1
fi
if [ "$(grep -c 'if plan.separateSound { ClipSoundSeparation.separate(plan.clip.id, in: &state) }' Sources/SrtFlow/AITimelineEdits.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/AITimelineEdits.swift 放素材时不按 sound=separate 分离声音" >&2
  exit 1
fi
# edit_clip 的 alone 只挡这一段自己的链接伙伴（别的片段的链接照旧）。
if [ "$(grep -c 'if linkage, !change.alone, let group = clip.linkGroup {' Sources/SrtFlow/AIClipEdit.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/AIClipEdit.swift 的 alone 没挡住链接伙伴跟着改（J/L cut 两边裁不开）" >&2
  exit 1
fi
echo "   ✓ 分离音频界面和 AI 同一份规则；alone 只挡自己的链接伙伴"
