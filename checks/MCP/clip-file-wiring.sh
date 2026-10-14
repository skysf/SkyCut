#!/usr/bin/env bash
# scripts/check-mcp.sh 的一节（由它 source 进来，不单独跑）：edit_clip 的 file（一段换成另一个文件）接到生产路径上没有。
# 纯值在 checks/MCP/ClipFileSwapChecks.swift 里测，这里只扫「真的调了它」。约束见 docs/architecture/ai-control-mcp.md 第四节第 48 条。

echo "==> edit_clip 换文件：读参数、探好再提交、画面按换完的那段放"
CLIP_TOOLS="Sources/SrtFlow/AIClipTools.swift"
if [ "$(grep -c 'if let path = try args.string("file") {' "${CLIP_TOOLS}" || true)" -ne 1 ] \
   || [ "$(grep -c 'plan.change.replacement = replacement' "${CLIP_TOOLS}" || true)" -ne 1 ]; then
  echo "✗ ${CLIP_TOOLS} 没把 edit_clip 的 file 读成 ClipFileReplacement 交给 AIClipEdit" >&2
  exit 1
fi
# 铺满、去黑边、对准主体要看换进来的那个文件，不是旧的。
if [ "$(grep -c 'try requirePicture(subject)' "${CLIP_TOOLS}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AIPictureProbe.blackBars(of: subject)' "${CLIP_TOOLS}" || true)" -ne 1 ]; then
  echo "✗ ${CLIP_TOOLS} 换文件时画面怎么放还按旧文件算" >&2
  exit 1
fi
# 换文件只在 AIClipEdit 里落到段上（ClipFileReplacement.apply），链接伙伴只跟换完之后的改动。
if [ "$(grep -c 'try ClipFileReplacement.apply(replacement, to: &updated' Sources/SrtFlow/AIClipEdit.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'follow(&$0, from: swapped, to: updated)' Sources/SrtFlow/AIClipEdit.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/AIClipEdit.swift 换文件没走 ClipFileReplacement，或链接伙伴跟着换文件挪了源时间" >&2
  exit 1
fi
echo "   ✓ file 读成 ClipFileReplacement、画面按换完的那段放、伙伴不跟换文件"
