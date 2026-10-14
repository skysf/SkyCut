#!/usr/bin/env bash
# scripts/check-mcp.sh 的一节（由它 source 进来，不单独跑）：几个工具结果里的话有没有接到生产路径上 —— 纯值在编出来的自检里测，
# 这里只扫「工具真的调了它」。都是扫描，秒级。
# 由来：docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md；约束见 docs/architecture/ai-control-mcp.md 第四节。

echo "==> 工具结果：转场报每条缝、复制认新轨、读不出画面说为什么、字体认别名、配音字幕整句、Kokoro 语速、cut_speech 的切口"
TIMELINE_TOOLS="Sources/SrtFlow/AITimelineTools.swift"
# set_transition 按收尾之后的状态报每条缝（以前只回 {"cuts": 1}）。
if [ "$(grep -c 'return .ok(AITransitionReport.json(' "${TIMELINE_TOOLS}" || true)" -ne 1 ]; then
  echo "✗ ${TIMELINE_TOOLS} 的 set_transition 不经 AITransitionReport 报每条缝：AI 又只拿到一个计数" >&2
  exit 1
fi
# duplicate_items 按 add_clips 那套名字认轨（正好多一条就新开），不借 set_track 的解析（它的报错叫人去用 set_track）。
if [ "$(grep -c 'AIDuplicate.apply(selection, to: &next, at: try args.double("start"), track: try args.string("track"))' "${TIMELINE_TOOLS}" || true)" -ne 1 ]; then
  echo "✗ ${TIMELINE_TOOLS} 的 duplicate_items 没把 track 的名字交给 AIDuplicate.apply（新开一条轨的写法认不出）" >&2
  exit 1
fi
if [ "$(grep -c 'AITrackName.target(track, in: state)' Sources/SrtFlow/AIDuplicate.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/AIDuplicate.swift 不按 AITrackName 认轨道名：和 add_clips 的叫法分家了" >&2
  exit 1
fi
# look 读不出画面时说为什么：看文件、扫字、分镜头、一次看几个文件都经 AIUnreadableVideo。
for file in AILookTool AILookText AILookFiles AILookShots; do
  if [ "$(grep -c 'AIUnreadableVideo\.' "Sources/SrtFlow/${file}.swift" || true)" -lt 1 ]; then
    echo "✗ Sources/SrtFlow/${file}.swift 读不出画面时不经 AIUnreadableVideo 说为什么（hev1、解不开、文件不在了）" >&2
    exit 1
  fi
done
if grep -q 'could not read a picture from it"' Sources/SrtFlow/AILookFiles.swift; then
  echo "✗ Sources/SrtFlow/AILookFiles.swift 又写回了不说原因的那句话" >&2
  exit 1
fi
# 字幕字体清单读 name 表里的别名（用户装的苹方族名是「蘋方-簡」，AI 说 PingFang SC）。
if [ "$(grep -c 'FontFamilyNames.names(of: font)' Sources/SrtFlow/FontCatalog.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/FontCatalog.swift 扫字体时不读 name 表里的别名：PingFang SC 认不出" >&2
  exit 1
fi
# 几帧合起来去黑边用每边的读数（说不准的帧不参加），不用单帧的 bars（说不准当 0，一帧夜景就认不出遮幅）。
if [ "$(grep -c 'AIBlackBars.luma(of: frame.image).flatMap(AIBlackBars.reading(in:))' Sources/SrtFlow/AIPictureProbe.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/AIPictureProbe.swift 去黑边没按每边的读数合起来" >&2
  exit 1
fi
# 配音的字幕只从 AIVoiceoverSubtitles.config 拿参数（不按逗号拆小句），不直接用生成字幕那一套
#（docs/bugfixes/2026-10-14-voiceover-subtitles-split-at-commas.md）。
if [ "$(grep -c 'let config = AIVoiceoverSubtitles.config(' Sources/SrtFlow/AIVoiceoverTool.swift || true)" -ne 1 ] \
   || grep -q 'SubtitleSegmentationConfig.generation' Sources/SrtFlow/AIVoiceoverTool.swift; then
  echo "✗ Sources/SrtFlow/AIVoiceoverTool.swift 的配音字幕不经 AIVoiceoverSubtitles.config：会在逗号处切成半句一闪的短条" >&2
  exit 1
fi
# Kokoro 的语速按时长对准：先按 1 倍读一遍、再按 KokoroSpeedCalibration 调给模型的 speed（模型的 speed 按格取整、只慢一点点，
# docs/bugfixes/2026-10-14-kokoro-speed-barely-changes.md）。
if [ "$(grep -c 'KokoroSpeedCalibration.next(target: target, tried: tried)' Sources/SrtFlow/KokoroVoiceSpeech.swift || true)" -ne 1 ] \
   || [ "$(grep -c 'let normal = try renderOnce(text, language: language, voice: voice, speed: 1, engine: engine)' Sources/SrtFlow/KokoroVoiceSpeech.swift || true)" -ne 1 ]; then
  echo "✗ Sources/SrtFlow/KokoroVoiceSpeech.swift 不按时长对准语速：要的 speed 原样给模型，读出来常常只慢一点点" >&2
  exit 1
fi
# cut_speech 的切口先看量出来的停顿：读了这段声音、交给 AISpeechCutPoints（按给的时间剪、口头禅、重复词都经它），
# 挪了多少报给 AI（docs/bugfixes/2026-10-14-cut-speech-trusts-word-times.md）。只测纯值的话，工具照样可以只按转写切。
SPEECH_TOOL="Sources/SrtFlow/AISpeechCutTool.swift"
if [ "$(grep -c 'let levels = readsSound ? try await Self.levels(of: speech) : nil' "${SPEECH_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -c 'words: words ?? \[\], levels: levels,' "${SPEECH_TOOL}" || true)" -ne 1 ] \
   || [ "$(grep -cE 'AISpeechCuts\.(requested|outside|fillerWords|repeats)\([^)]*points: points\)' "${SPEECH_TOOL}" || true)" -ne 4 ] \
   || [ "$(grep -c 'result\["moved"\]' "${SPEECH_TOOL}" || true)" -ne 1 ]; then
  echo "✗ ${SPEECH_TOOL} 的切口不经量出来的停顿（AISpeechCutPoints 拿到 levels），或结果里不报挪了多少：又会只信转写、把切口挪进词里" >&2
  exit 1
fi
echo "   ✓ 转场报每条缝；复制按 add_clips 的名字认轨；读不出画面说为什么；字体读别名；去黑边按读数合起来；配音字幕不按逗号拆；Kokoro 语速按时长对准；cut_speech 的切口先看停顿"
