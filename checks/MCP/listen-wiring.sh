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

echo "==> listen 文件显式区间：原生 timeRange 有界读取，超时/取消结束本次读取"
LISTEN_FILE="Sources/SrtFlow/AIListenFileAudio.swift"
LISTEN_WINDOW="Sources/SrtFlow/AIListenAudioWindow.swift"
LISTEN_CONTROL="Sources/SrtFlow/AIListenReadControl.swift"
if [ "$(grep -c 'AIListenFileAudio.listen(' "${LISTEN_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'if sourceIn != nil || sourceOut != nil' "${LISTEN_FILE}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AIListenAudioWindow.read(url, from: sourceIn, to: sourceOut, until: deadline)' "${LISTEN_FILE}" || true)" -ne 1 ] \
   || [ "$(grep -c 'reader.timeRange = CMTimeRange' "${LISTEN_WINDOW}" || true)" -ne 1 ] \
   || [ "$(grep -c 'WaveformStore' "${LISTEN_WINDOW}" "${LISTEN_CONTROL}" | grep -cv ':0$' || true)" -ne 0 ] \
   || [ "$(grep -c 'withTaskCancellationHandler' "${LISTEN_WINDOW}" || true)" -ne 1 ] \
   || [ "$(grep -c 'MediaReadQueue.analysis.addOperation(operation)' "${LISTEN_CONTROL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'fileDuration > AIBeats.maxSeconds' "${LISTEN_FILE}" || true)" -ne 1 ]; then
  echo "✗ 文件显式范围没有完整接到有界原生读取/取消路径，或长文件未在节拍解码前受限" >&2
  exit 1
fi
echo "   ✓ 显式范围不走整文件波形；原生 timeRange、生产取消/截止时间、长文件节拍限制已接上"

echo "==> listen 原生生命周期：copy 与取消只由同一 analysis 读取体拥有"
python3 - "${LISTEN_WINDOW}" "${LISTEN_CONTROL}" <<'PY'
import pathlib, sys
window, control = (pathlib.Path(name).read_text() for name in sys.argv[1:])
code = lambda text: "\n".join(line.split("//", 1)[0] for line in text.splitlines())
window, control = code(window), code(control)
assert "cancelReading(" not in control, "✗ listen control must not cancel a reader from the caller/timer thread"
assert "AVAssetReader" not in control, "✗ listen control must not retain the analysis-owned native reader"
assert window.count("reader.cancelReading()") == 1, "✗ listen native reader needs exactly one owner cleanup"
assert "defer { reader.cancelReading(); observe?(.finished) }" in window, "✗ native owner must finish before publishing its result"
assert "loading = false" in control and "loading ? asset : nil" in control, "✗ metadata cancellation must end atomically before the read operation can start"
assert "autoreleasepool { Result" in control, "✗ native reader release must finish on analysis before continuation completion"
assert "runListenReaderLifecycleChecks(url)" in pathlib.Path("checks/MCP/ListenRangeChecks.swift").read_text(), "✗ native lifecycle regression is not called by the production range checks"
# 阶段探针和读取账报的得是那一刻的真事（2026-11-13，docs/architecture/blocking-media-reads.md「回归」）：探针挪早了，
# 自检等到的就不是它要测的那个阶段，照样绿。登记点活不活由自检里的正例管（没给区间的短文件 listen），这里只钉位置。
import re
assert re.search(r"MediaReadQueue\.analysis\.addOperation\(operation\)\s+observe\?\(\.queued\)", control), "✗ the queued probe must fire only after the read operation is handed to the analysis queue"
assert re.search(r"resources\.2\?\.resume\(returning: \.failure\(error\)\)\s+observe\?\(\.stopRequested\)", control), "✗ the stopRequested probe must fire only after a queued caller has been resumed"
assert "audit?.note(.windowStarted(asset.url, from: reader.timeRange.start.seconds, to: reader.timeRange.end.seconds))" in window, "✗ the read audit must record the reader's own timeRange, not the range the caller asked for"
PY
echo "   ✓ 外部取消只发信号；metadata 移交后不再取消 asset；reader 单点收尾并在恢复调用方前释放；阶段探针在交给队列 / 恢复调用方之后才报"

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
