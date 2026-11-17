#!/usr/bin/env bash
# A section of scripts/check-mcp.sh (sourced by it, not run on its own): the synthesized sound effects' wiring.
# Moved out of check-mcp.sh on 2026-11-17 when two parallel PRs took it past the 600-line limit
# (docs/architecture/coding-standards.md); the checks are unchanged. Rules: docs/architecture/sound-effect-synth.md section 2.

# 合成音效（docs/architecture/sound-effect-synth.md）：合成器和工具自己不碰 AVAudioFile（写文件只经 AIAudioFileWriter，同配音）；
# 渲染 + 写盘在 MediaReadQueue.analysis 上跑，不占 Swift 并发的线程池。
SFX_WRITERS="$(grep -l 'AVAudioFile' Sources/SrtFlow/SoundEffects/*.swift Sources/SrtFlow/AISoundEffect*.swift || true)"
if [ -n "${SFX_WRITERS}" ]; then
  echo "✗ 音效的文件只能经 AIAudioFileWriter 写，这些文件自己碰了 AVAudioFile：${SFX_WRITERS}"
  exit 1
fi
if [ "$(grep -c 'MediaReadQueue.run(on: MediaReadQueue.analysis)' Sources/SrtFlow/AISoundEffectTool.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'AIAudioFileWriter.writeSoundEffect(' Sources/SrtFlow/AISoundEffectTool.swift || true)" -ne 1 ]; then
  echo "✗ AISoundEffectTool 要在 MediaReadQueue.analysis 上渲染并经 AIAudioFileWriter.writeSoundEffect 写文件"
  exit 1
fi
echo "   ✓ 合成音效：写文件只经 AIAudioFileWriter，渲染在 MediaReadQueue 上"
