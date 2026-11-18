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
# Since 2026-11-17 every file listen (named range or the whole file) and every clip listen is one bounded read of its window:
# the true peak and the loudest frame need the samples (docs/architecture/ai-control-mcp.md section 4 item 13).
LISTEN_FILE="Sources/SrtFlow/AIListenFileAudio.swift"
LISTEN_WINDOW="Sources/SrtFlow/AIListenAudioWindow.swift"
LISTEN_CONTROL="Sources/SrtFlow/AIListenReadControl.swift"
if [ "$(grep -c 'AIListenFileAudio.listen(' "${LISTEN_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AIListenAudioWindow.read(url, from: sourceIn, to: sourceOut, until: deadline,' "${LISTEN_FILE}" || true)" -ne 1 ] \
   || [ "$(grep -c 'AIListenAudioWindow.read(clip.sourceURL, from: from, to: to, until: deadline,' "${LISTEN_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'edges: .sound, gain: frames.sampleGain)' "${LISTEN_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'let edges = edges ?? (from == nil && to == nil ? .sound : .exact)' "${LISTEN_WINDOW}" || true)" -ne 1 ] \
   || ! grep -q 'checkListenSoundEdges(in: directory)' checks/MCP/ListenRangeChecks.swift \
   || [ "$(grep -c 'await waveform(of:' "${LISTEN_FILE}" || true)" -ne 0 ] \
   || [ "$(grep -c 'waveform(of: clip.sourceURL' "${LISTEN_TOOL}" || true)" -ne 0 ] \
   || [ "$(grep -c 'static func loudest(' Sources/SrtFlow/AIAudioLevels.swift || true)" -ne 0 ] \
   || [ "$(grep -c 'peaks: AIListenPeaks' Sources/SrtFlow/AIAudioLevels.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'reader.timeRange = CMTimeRange' "${LISTEN_WINDOW}" || true)" -ne 1 ] \
   || [ "$(grep -c 'WaveformStore' "${LISTEN_WINDOW}" "${LISTEN_CONTROL}" | grep -cv ':0$' || true)" -ne 0 ] \
   || [ "$(grep -c 'withTaskCancellationHandler' "${LISTEN_WINDOW}" || true)" -ne 1 ] \
   || [ "$(grep -c 'MediaReadQueue.analysis.addOperation(operation)' "${LISTEN_CONTROL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'fileDuration > AIBeats.maxSeconds' "${LISTEN_FILE}" || true)" -ne 1 ]; then
  echo "✗ 片段 / 文件的 listen 没有完整接到有界原生读取/取消路径（真峰值和最响的那一帧要从这一遍采样里来，不从共享波形、不报曲线格子的中点），或长文件未在节拍解码前受限" >&2
  exit 1
fi
echo "   ✓ 片段和文件都是一遍有界读取（真峰值、最响的那一帧）；片段的窗和整个文件按声音在哪儿量（音轨比画面短不拒绝），点名的区间照旧要盖满；原生 timeRange、生产取消/截止时间、长文件节拍限制已接上"

echo "==> clip listen applies the engine envelope before statistics"
python3 - <<'PYTHON'
from pathlib import Path
code = lambda path: "\n".join(line.split("//", 1)[0] for line in Path(path).read_text().splitlines())
tool = code("Sources/SrtFlow/AIListenTool.swift")
window = code("Sources/SrtFlow/AIListenAudioWindow.swift")
gain = code("Sources/SrtFlow/AIListenSampleGain.swift")
assert "gain: frames.sampleGain" in tool, "clip read must receive its sample envelope"
assert "AIAudioLevels.onTimeline(reading.windows, clip: clip)" in tool, "already gained levels must only map time"
assert "AIAudioLevels.heard(reading.windows" not in tool, "clip listen must not apply gain twice"
assert "gain.applying(to: samples, from: start, rate: rate, channels: channels)" in window, "gain must apply after PTS trimming"
assert "heard.withUnsafeBufferPointer { accumulate(" in window, "every statistic must consume the gained samples"
assert "AudioGainRamps.addVolumeRamps" in gain and "table.sampler()" in gain, "listen must reuse the engine gain table"
assert "clip.timelineTime(atSource:" in gain and "envelope.gain(at: time) * trackGain" in gain, "gain must follow each sample's timeline time and track fader"
assert "gains:" not in code("Sources/SrtFlow/AIListenSampleFrames.swift"), "metered frame maxima must never receive post-measurement gains"
PYTHON
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

echo "==> listen mix=true：用引擎按层离线渲（和成片同一份配置、同一套限幅和响度量法），是排队的 AI 任务、不碰预览的引擎"
# 2026-11-16（MCP-3 / MCP-10；docs/architecture/export-audio-mixdown.md「五、按层量」、ai-control-mcp.md 第四节第 13、59 条）。
# 量法本身在 scripts/check-mix-layers.sh 真跑（oracle、和导出逐位对账）；这里只扫「真的接上了、接的是那一份」。
python3 - <<'PY'
import pathlib, re
def code(path):
    return "\n".join(line.split("//", 1)[0] for line in pathlib.Path(path).read_text().splitlines())
tool, mix = code("Sources/SrtFlow/AIListenTool.swift"), code("Sources/SrtFlow/AIListenMix.swift")
plan = code("Sources/SrtFlow/AIListenMixPlan.swift")
measure = code("Sources/SrtFlow/AudioEngine/MixMeasurement.swift")
stems = code("Sources/SrtFlow/AudioEngine/AudioStemRender.swift")
bus = code("Sources/SrtFlow/AudioEngine/MixBusMeter.swift")
band = code("Sources/SrtFlow/AudioEngine/MixBandMeter.swift")
assert tool.count('args.bool("mix")') == 1 and tool.count("AIListenMix.listen(") == 1, "✗ listen 要读 mix 并交给 AIListenMix"
# 长任务的规矩（第 59 条）：AIJobs.start / finish 成对；一次一个（AIWorkQueue 的 mix 道）；排着时取消只从队里拿掉。
assert mix.count("AIJobs.shared.start(.listen") == 1, "✗ listen mix 要是 AIJobs 的任务（App Nap 不降速、get_job 拿得到结果）"
assert mix.count("AIWorkQueue.shared.submit(.mix, jobID: job.id)") == 1, "✗ listen mix 要排在 AIWorkQueue 的 mix 道上（一次一个）"
assert mix.count("work.cancel(") == 1, "✗ listen mix 的取消要经 AIQueuedWork.cancel（排着的从队里拿掉）"
assert mix.count("AIJobs.shared.finish(job, .done") == 1 and mix.count("AIJobs.shared.finish(job, .failed") == 1 \
    and mix.count("AIJobs.shared.finish(job, .cancelled") == 1, "✗ listen mix 每种结局都要 finish（还掉不降速的那一份）"
# 阻塞的离线渲在 MediaReadQueue.export 上（和导出的混音一条宽度 1 的队列），配置和成片同一份（带场景的响度补偿）。
assert mix.count("MediaReadQueue.run(on: MediaReadQueue.export)") == 1, "✗ listen mix 的离线渲要在 MediaReadQueue.export 上（不进 Swift 并发池、不和导出的混音同时跑）"
assert mix.count("AudioEngineConfig.make(from: state)") == 1, "✗ 量的那一份配置要和成片同一个算法（AudioEngineConfig.make(from:)，带场景的响度补偿）"
assert mix.count("MixMeasurement.measure(") == 1 and mix.count("AIListenMixReport.json(") == 1, "✗ listen mix 要经 MixMeasurement 量、AIListenMixReport 写"
assert "MixFrameGrid(fps: state.frameRate.fps)" in plan and not re.search(r"MixFrameGrid\(fps: *[0-9]", plan + mix), "✗ 帧率只从工程来（不许写死）"
# 按层渲只用离线引擎：不碰预览那个实时引擎、不起 / 停图（空闲的图照旧停着，docs/architecture/audio-engine.md 第二节第 11 条）。
assert measure.count("AudioStemRender.render(") == 1, "✗ MixMeasurement 要经 AudioStemRender 渲"
assert stems.count("mode: .offline") == 2 and ".realtime" not in stems, "✗ 按层渲只建离线引擎（混音一个、每层一个）"
for name, text in [("AudioStemRender", stems), ("MixMeasurement", measure), ("AIListenMix", mix)]:
    for banned in ["suspend(", "wake(", "recoverIfNeeded(", "AudioEngineIdleKeeper", "audioEngineHost"]:
        assert banned not in text, f"✗ {name} 不许碰预览引擎的起停（{banned}）"
# 量法复用成片那一份：限幅器同样的参数、整体响度 ExportLoudnessMeter、K 加权 AudioKWeighting；不许另写一套系数。
assert "ExportPeakLimiter(channels: 2, sampleRate: grid.sampleRate)" in bus and "limiter.recordsGains = true" in bus, "✗ MixBusMeter 要用成片同样参数的限幅器"
assert "ExportLoudnessMeter(channels: 2)" in bus and "ExportLoudnessMeter(channels: 2)" in band, "✗ 整体响度要用 ExportLoudnessMeter（成片同一个门限算法）"
assert "AudioKWeighting()" in bus, "✗ 瞬时 / 短时响度的 K 加权要用 AudioKWeighting"
for path in pathlib.Path("Sources/SrtFlow").rglob("*.swift"):
    if path.name != "AudioKWeighting.swift" and "1.53512485958697" in path.read_text():
        raise AssertionError(f"✗ {path} 另写了一份 K 加权的系数（只许在 AudioKWeighting）")
PY
echo "   ✓ mix=true 交给 AIListenMix：AIJobs 任务、mix 道排队、MediaReadQueue.export 上离线渲、成片同一份配置和量法、不碰预览引擎"

echo "==> listen voice=…: each narration line against the mix (MCP-39), the same job shape as mix=true, the lines only in VoiceClarity"
# 2026-11-17 (docs/architecture/listening-engine.md section 2 item 3a, ai-control-mcp.md section 4 item 13). The real path runs in
# scripts/check-mix-layers.sh group 3, the verdict table in scripts/check-listening.sh; this only scans that it is wired to them.
python3 - <<'PY'
import pathlib
def code(path):
    return "\n".join(line.split("//", 1)[0] for line in pathlib.Path(path).read_text().splitlines())
tool, check = code("Sources/SrtFlow/AIListenTool.swift"), code("Sources/SrtFlow/AIListenVoiceCheck.swift")
measure, report = code("Sources/SrtFlow/AIListenVoiceMeasure.swift"), code("Sources/SrtFlow/AIListenVoiceReport.swift")
plan = code("Sources/SrtFlow/AIListenVoicePlan.swift")
assert tool.count('args.string("voice")') == 1 and tool.count("AIListenVoiceCheck.listen(") == 1, "✗ listen must read voice and call AIListenVoiceCheck"
assert check.count("AIListenMix.queued(") == 1, "✗ voice must share mix=true's AIJobs, mix lane and MediaReadQueue.export through AIListenMix.queued"
assert check.count("AIListenVoicePlan.make(") == 1 and check.count("AIListenVoiceMeasure.measure(") == 1 \
    and check.count("AIListenVoiceReport.json(") == 1, "✗ voice must use AIListenVoicePlan, AIListenVoiceMeasure and AIListenVoiceReport"
assert measure.count("AudioStemRender.render(") == 1 and measure.count("MaskerAttribution.rank(") == 1 \
    and measure.count("VoiceLines.split(") == 1, "✗ voice must render stems, split at pauses and measure each line with MaskerAttribution"
for name, text in [("AIListenVoiceCheck", check), ("AIListenVoiceMeasure", measure)]:
    for banned in ["suspend(", "wake(", "recoverIfNeeded(", "AudioEngineIdleKeeper", "audioEngineHost", ".realtime"]:
        assert banned not in text, f"✗ {name} must not touch the preview engine ({banned})"
assert report.count("VoiceClarity.verdict(") == 1, "✗ each line's verdict must come only from VoiceClarity"
assert report.count("VoiceClarity.hint(") == 1 and '.isAddedSound(' in report, "✗ the grey hint must use VoiceClarity and the main layer's provenance"
for path in pathlib.Path("Sources/SrtFlow").rglob("*.swift"):
    if path.name != "VoiceClarity.swift":
        text = code(str(path))
        for name in ["unintelligibleBelow", "hardBelow", "musicBelow", "hintBelow", "hintRemovalGain"]:
            assert f"let {name}" not in text, f"✗ {path} duplicates a voice threshold ({name} belongs only in VoiceClarity)"
assert 'hasPrefix("V")' in plan and "own sound" in plan, "✗ video-track voices must be refused with the reason: no clean voice stem"
PY
echo "   ✓ voice uses AIListenVoiceCheck: shared jobs, stem rendering, pause splitting, MaskerAttribution and VoiceClarity"

echo "==> listen describe=true: a clip's own sound in words (MCP-42 / MCP-44): a listen job, one bounded read, installed speech models only"
# 2026-11-17 (docs/architecture/listening-engine.md section 2 item 4a). The report and the classifier run in
# scripts/check-mix-layers.sh group 4; this scans the wiring.
python3 - <<'PY'
import pathlib
def code(path):
    return "\n".join(line.split("//", 1)[0] for line in pathlib.Path(path).read_text().splitlines())
tool, sound = code("Sources/SrtFlow/AIListenTool.swift"), code("Sources/SrtFlow/AIListenSourceSound.swift")
words, labels = code("Sources/SrtFlow/AIListenSourceWords.swift"), code("Sources/SrtFlow/SoundLabelScores.swift")
assert tool.count('args.bool("describe")') == 1 and tool.count("AIListenSourceSound.listen(") == 1, "✗ listen must dispatch describe to AIListenSourceSound"
assert sound.count("AIJobs.shared.start(.listen") == 1 and sound.count("AIWorkQueue.shared.submit(.mix, jobID: job.id)") == 1, \
    "✗ describe must use AIJobs and the mix lane"
assert sound.count("AIJobs.shared.finish(job, .done") == 1 and sound.count("AIJobs.shared.finish(job, .failed") == 1 \
    and sound.count("AIJobs.shared.finish(job, .cancelled") == 1, "✗ every describe outcome must finish its job"
assert sound.count("AIListenAudioWindow.read(") == 1 and "keepsSamples: true" in sound, "✗ describe must retain samples from one bounded read"
assert "edges: target.edges, keepsSamples: true" in sound and "to: window.to, edges: .sound" in sound, \
    "✗ clip description must keep sound edges when retaining samples"
assert "sourceIn == nil && sourceOut == nil ? .sound : .exact" in sound, "✗ only a named file range requires exact audio coverage"
assert "readStart: reading.sourceStart" in sound, "✗ description windows must start at the first sample's real source time"
assert sound.count("MediaReadQueue.run(on: MediaReadQueue.analysis)") == 1, "✗ traits and classification must run on MediaReadQueue.analysis"
assert "SourceSoundDescription.describe(" in sound and "SoundLabelScores.classify(" in sound and "AIListenSourceWords.words(" in sound, \
    "✗ describe must report traits, label scores and words"
assert "AIListenVoiceCheck.provenance()" in sound, "✗ known provenance must be checked before describing sound"
assert all(name not in sound for name in ["AudioEngineIdleKeeper", "audioEngineHost", "TimelineAudioEngine", "wake(", "suspend("]), \
    "✗ source description must not touch the preview audio graph"
assert 'args.stringArray("layers") == nil' in sound and 'args.bool("frames")' in sound, "✗ describe must refuse mix-only fields"
assert "screeningLocale()" in words and "reserveInstalledModel(locale: locale)" in words and "ensureModel(" not in words, \
    "✗ describe must reserve an installed speech model without an installation fallback"
assert all(name not in words for name in ["assetInstallationRequest", "matchedLocale", "supportedLocales"]), \
    "✗ description must not request a speech model download"
service = code("Sources/SrtFlow/SubtitleGen/SpeechTranscriptionService.swift")
installed = service.split("func reserveInstalledModel(", 1)[1].split("func releaseModel(", 1)[0]
assert "SpeechModelLeases.shared.acquire(locale)" in installed and "status == .installed" in installed \
    and "SpeechModelLeases.shared.release(locale)" in installed, "✗ installed-only reservation must check availability and release on failure"
assert all(name not in installed for name in ["assetInstallationRequest", "downloadAndInstall", "ensureModel("]), \
    "✗ installed-only reservation must never install a model"
words_end = sound.split("let words = await AIListenSourceWords.words(", 1)[1].split("var object = target.head", 1)[0]
assert "if stop.stopped { throw CancellationError() }" in words_end, "✗ cancellation during word recognition must not publish a successful description"
assert "SNClassifySoundRequest(classifierIdentifier: .version1)" in labels and "overlapFactor = 0" in labels, \
    "✗ classification must use the native classifier without overlapping windows"
PY
echo "   ✓ describe uses listen jobs, one bounded sample read, source provenance, analysis queues and installed-only speech models"

echo "==> music accents: one read with the beats; add_clips lands hits with AIClipHit; a generated music job carries listen's answer"
# MCP-43 (2026-11-18, docs/architecture/listening-engine.md section 9): the shape comes from the same read as the beats (no second
# decode of the song), every add_clips source lands its hit through the one placement rule, and get_job of a generated music file
# carries exactly `listen file beats=true` (AIGeneratedMusicReport). The behaviour is checked in MusicShapeChecks and
# checks/ParameterLimits/MusicPlacementChecks.swift; this pins the wiring those checks cannot reach (the paid generation run).
python3 - <<'PY'
from pathlib import Path
code = lambda path: "\n".join(line.split("//", 1)[0] for line in Path(path).read_text().splitlines())
beats = code("Sources/SrtFlow/AIBeats.swift")
assert beats.count("MusicShape.analyze(pcm.samples, sampleRate: rate)") == 1 and beats.count("readMono(asset:") == 1, \
    "✗ the music shape must be measured on the beats' one read"
timeline = code("Sources/SrtFlow/AITimelineTools.swift")
assert timeline.count("try await land(&request, known:") == 3 and "AISoundEffectRequest.placement" not in timeline, \
    "✗ add_clips must land the hit of every source (library, sound effect, file) through AIClipHit"
assert "AIClipHit.report(&entry, landing: landing, clip: clip)" in timeline, "✗ the reply must read hit_at back from the placed clip"
effects = code("Sources/SrtFlow/AISoundEffectRequest.swift")
assert "AIClipHit.placement(hitAt: requested, hit: renderedHit, sourceIn: 0)" in effects, "✗ the placement rule must have one copy"
run = code("Sources/SrtFlow/SkyStudio/SkyStudioGenerationRun.swift")
assert run.count("generation.kind == .music ? await AIGeneratedMusicReport.measure(editable, project: project) : nil") == 1 \
    and 'if let music { detail["music"] = music }' in run, "✗ a generated music job's get_job must carry the listen measurement"
report = code("Sources/SrtFlow/AIGeneratedMusicReport.swift")
assert "AIListenFileAudio.listen(" in report and "beats: true" in report, "✗ get_job's music must be listen's own answer"
PY
echo "   ✓ the shape rides on the beats' read, add_clips lands every hit through AIClipHit, generated music carries listen's answer"
