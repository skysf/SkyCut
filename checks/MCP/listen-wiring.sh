#!/usr/bin/env bash
# scripts/check-mcp.sh 的一节（由它 source 进来，不单独跑）：listen 的两个问法接到生产路径上没有 —— 只听某几秒（from / to）、
# 一次查完 V1 的剪辑点（cuts=true，判的输入和 cut_speech 同一份）。纯值在 checks/MCP/ListenChecks.swift、CutCheckChecks.swift、
# SpeechHearingChecks.swift 里测，这里只扫「真的调了它」。约束见 docs/architecture/ai-control-mcp.md 第四节第 13 条。

echo "==> listen 只听时间线上的某几秒：from / to 读进来、片段和整条时间线都按它裁"
# 2026-10-14 用户拍板（docs/architecture/ai-control-mcp.md 第四节第 13 条）；纯值在 checks/MCP/ListenChecks.swift。
LISTEN_TOOL="Sources/SrtFlow/AIListenTool.swift"
if [ "$(grep -c 'settings.from = try args.double("from")' "${LISTEN_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AIAudioLevels.sourceWindow(of: clip, from: settings.from, to: settings.to)' "${LISTEN_TOOL}" || true)" -lt 2 ] \
   || [ "$(grep -c 'AIAudioLevels.sourceWindow(of: $0, from: settings.from, to: settings.to)' "${LISTEN_TOOL}" || true)" -ne 1 ]; then
  echo "✗ ${LISTEN_TOOL} 的 from / to 没接上：片段或整条时间线照旧整段量" >&2
  exit 1
fi
echo "   ✓ from / to 读进来；一段片段、整条时间线都只量落在里面的那几秒"

echo "==> listen cuts=true：V1 的剪辑点一次查完，转写只读缓存、声音从哪段来和判的输入都和 cut_speech 同一份"
# 2026-10-16（docs/plans/2026-10-16-ai-feedback-line-spacing-and-cut-check.md；第四节第 13 条）；纯值在 checks/MCP/CutCheckChecks.swift。
# 2026-10-18：两个工具判切口的输入（整个素材文件的电平、门限、词）只从 AISpeechHearing 来，读法只有 AISpeechCutTool 的 wholeFile / transcript
# 一份 —— 以前各量各的，同一个源时刻 cut_speech 说在声音上、检查说 quiet_spot（docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md）。
CUTS_TOOL="Sources/SrtFlow/AIListenCuts.swift"
CUT_TOOL="Sources/SrtFlow/AISpeechCutTool.swift"
JUDGES="$(grep -l 'AISpeechCutPoints(' Sources/SrtFlow/*.swift | grep -v 'Sources/SrtFlow/AISpeechHearing.swift' || true)"
if [ "$(grep -c 'args.bool("cuts")' "${LISTEN_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AIListenCuts.check(' "${LISTEN_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AISpeechCutTool.speechClip(' "${CUTS_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AISpeechCutTool.wholeFile(' "${CUTS_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AISpeechCutTool.transcript(' "${CUTS_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AISpeechHearing(' "${CUTS_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AISpeechHearing(' "${CUT_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'points: points, frame: frame)' "${CUTS_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AITranscribeTool.cached(' "${CUT_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AIListenTool.waveform(' "${CUT_TOOL}" || true)" -ne 1 ] \
   || [ -n "${JUDGES}" ] \
   || [ "$(grep -cE 'TranscriptHarvester|TranscriptionTask|SpeechTranscriptionService' "${CUTS_TOOL}" "${CUT_TOOL}" | grep -cv ':0$' || true)" -ne 0 ]; then
  echo "✗ listen cuts=true 没接好：listen 要读 cuts 并交给 AIListenCuts；声音从哪段来用 AISpeechCutTool.speechClip，波形和转写缓存只经 AISpeechCutTool.wholeFile / transcript（只读缓存、不许起转写），判切口的点只在 AISpeechHearing 里建（cut_speech 和检查同一份输入），建议对齐到帧（frame）${JUDGES:+；在这些文件里另建了判点：${JUDGES}}" >&2
  exit 1
fi
echo "   ✓ listen 读 cuts；剪辑点检查和 cut_speech 判切口的输入同一份（AISpeechHearing）、转写只读缓存、建议对齐到帧"
