#!/usr/bin/env bash
# **按层量混在一起之后的声音**（listen mix=true 的地基：AudioStemRender / MixMeasurement / MixBandMeter / MixBusMeter，
# 和 AIListenMixPlan / AIListenMixReport）。信号都是现造的 WAV（不拿真素材）：
#   - oracle：已知频率和电平的正弦（频段电平）、已知时刻的脉冲（到采样 / 到帧）、0.56 秒的音效（最响处到帧）、
#     EBU Tech 3341 的 1 kHz 正弦（瞬时 / 短时 / 整体响度）；
#   - 和导出对账：整条时间线的峰值、过线、压得最深、整体响度 = ExportAudioMixdown 报的（逐位）；每层加起来 = 混音；
#     只量中间一段 = 整段量的那几帧；单声道人声的电平 = 真导出（ffmpeg）成片里的电平；
#   - listen 的参数和结果：层怎么分、越界给合法建议、逐帧的数放得下才给。
#
# 用法：
#   scripts/check-mix-layers.sh
#
# 编法同 scripts/check-audio-engine.sh（源文件清单从它复制，再加按层量的几个文件和 listen 那几个纯值文件）：被测代码在
# SrtFlow app target 里，SwiftPM 不允许两个 target 共用源文件，所以单独编成自检二进制来跑。需要 ffmpeg（真跑导出的那一组）。
# 长期约束：docs/architecture/export-audio-mixdown.md「五、按层量」。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore / SrtFlowMCPKit"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowMCPKit 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/mixlayers"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# -O (2026-11-17): listen voice=… runs ESTOI and long FFTs per line (group 3); the debug build took minutes for a few seconds of
# sound, the optimized one seconds (same as scripts/check-listening.sh).
xcrun swiftc \
  -target "$TRIPLE" \
  -O \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditWebMotionRecord.swift \
  Sources/SrtFlow/VideoEditClipPlacement.swift \
  Sources/SrtFlow/EditLane.swift \
  Sources/SrtFlow/VideoEditCanvasRatio.swift \
  Sources/SrtFlow/StillAlphaNaming.swift \
  Sources/SrtFlow/VideoEditMediaReferences.swift \
  Sources/SrtFlow/VideoEditClipUpscale.swift \
  Sources/SrtFlow/VideoEditClipUpscaleRecord.swift \
  Sources/SrtFlow/VideoEditTrackSlot.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditShapeAnimation.swift \
  Sources/SrtFlow/VideoEditSoundSceneRecipe.swift \
  Sources/SrtFlow/VideoEditSoundSceneDSP.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditFilterLUT.swift \
  Sources/SrtFlow/VideoEditClipVisibility.swift \
  Sources/SrtFlow/VideoEditTransitionHandles.swift \
  Sources/SrtFlow/VideoEditFadeWindow.swift \
  Sources/SrtFlow/VideoEditAudioFade.swift \
  Sources/SrtFlow/VideoEditVideoFade.swift \
  Sources/SrtFlow/VideoEditClipAnimation.swift \
  Sources/SrtFlow/VideoEditClipAnimator.swift \
  Sources/SrtFlow/VideoEditTrackPalette.swift \
  Sources/SrtFlow/VideoEditTextStyle.swift \
  Sources/SrtFlow/VideoEditTextEasing.swift \
  Sources/SrtFlow/VideoEditTextAnimation.swift \
  Sources/SrtFlow/VideoEditTextAnimator.swift \
  Sources/SrtFlow/VideoEditTextNumber.swift \
  Sources/SrtFlow/VideoEditTextOdometer.swift \
  Sources/SrtFlow/VideoEditTextNumberRenderer.swift \
  Sources/SrtFlow/VideoEditTextModels.swift \
  Sources/SrtFlow/VideoEditTextRows.swift \
  Sources/SrtFlow/VideoEditTextLayout.swift \
  Sources/SrtFlow/VideoEditTextLayoutFonts.swift \
  Sources/SrtFlow/VideoEditTextRenderer.swift \
  Sources/SrtFlow/VideoEditTextDrawing.swift \
  Sources/SrtFlow/VideoEditTextExport.swift \
  Sources/SrtFlow/VideoEditOverlayExportFile.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditKeyframeEasing.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/TimelineClipSplit.swift \
  Sources/SrtFlow/FreezeSliver.swift \
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditTimelineLinkage.swift \
  Sources/SrtFlow/VideoEditTimelineCaptionSource.swift \
  Sources/SrtFlow/VideoEditTimelineCueFollow.swift \
  Sources/SrtFlow/VideoEditTimelineLinkageLanding.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  Sources/SrtFlow/CompositionSource.swift \
  Sources/SrtFlow/Watermark/WatermarkExport.swift \
  Sources/SrtFlow/Watermark/WatermarkImage.swift \
  Sources/SrtFlow/Watermark/WatermarkPlacement.swift \
  Sources/SrtFlow/SeededRandom.swift \
  Sources/SrtFlow/AppResources.swift \
  Sources/SrtFlow/VideoEditShapeOverlayExport.swift \
  Sources/SrtFlow/VideoEditExportTransform.swift \
  Sources/SrtFlow/VideoEditExportPlan.swift \
  Sources/SrtFlow/VideoEditGradeExport.swift \
  Sources/SrtFlow/VideoEditCoverExport.swift \
  Sources/SrtFlow/VideoEditShapePNGRenderer.swift \
  Sources/SrtFlow/VideoEditShapeOutline.swift \
  Sources/SrtFlow/VideoEditExportFilterScript.swift \
  Sources/SrtFlow/VideoEditExportMixdown.swift \
  Sources/SrtFlow/ExportPeakLimiter.swift \
  Sources/SrtFlow/TruePeak.swift \
  Sources/SrtFlow/ExportLoudnessMeter.swift \
  Sources/SrtFlow/AudioKWeighting.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/TimelineRenderSize.swift \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift \
  Sources/SrtFlow/CompositionFade.swift \
  Sources/SrtFlow/CompositionClipInsert.swift \
  Sources/SrtFlow/OptimizedMedia/OptimizedMediaLookup.swift \
  Sources/SrtFlow/OptimizedMedia/OptimizedMediaPolicy.swift \
  Sources/SrtFlow/VideoEditKeyframeSlices.swift \
  Sources/SrtFlow/CompositionTime.swift \
  Sources/SrtFlow/CompositionSlices.swift \
  Sources/SrtFlow/CompositionHold.swift \
  Sources/SrtFlow/VideoEditMediaAssetCache.swift \
  Sources/SrtFlow/VideoEditBlackBaseVideo.swift \
  Sources/SrtFlow/VideoEditAudioMeter.swift \
  Sources/SrtFlow/AudioEngine/AudioGainTable.swift \
  Sources/SrtFlow/VideoEditTimelineRowHeights.swift \
  Sources/SrtFlow/VideoEditPrerender.swift \
  Sources/SrtFlow/AlphaSourceCopies.swift \
  Sources/SrtFlow/BurnInWorkspace.swift \
  Sources/SrtFlow/SubtitleFontScale.swift \
  Sources/SrtFlow/SubtitleLineWrap.swift \
  Sources/SrtFlow/SubtitleCJKRows.swift \
  Sources/SrtFlow/SubtitleFallbackFont.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/AppTheme.swift \
  Sources/SrtFlow/AppThemePalette.swift \
  Sources/SrtFlow/AppThemeAppearance.swift \
  Sources/SrtFlow/AudioEngine/AudioEngineConfig.swift \
  Sources/SrtFlow/AudioEngine/AudioRing.swift \
  Sources/SrtFlow/AudioEngine/AudioPublished.swift \
  Sources/SrtFlow/AudioEngine/MeterSlot.swift \
  Sources/SrtFlow/AudioEngine/AudioSegmentReader.swift \
  Sources/SrtFlow/AudioEngine/AudioTimeStretchReader.swift \
  Sources/SrtFlow/AudioEngine/AudioTrackFeeder.swift \
  Sources/SrtFlow/AudioEngine/AudioTrackRenderer.swift \
  Sources/SrtFlow/AudioEngine/TimelineAudioEngine.swift \
  Sources/SrtFlow/AudioEngine/PlaybackAnchor.swift \
  Sources/SrtFlow/AudioEngine/AudioGraphRun.swift \
  Sources/SrtFlow/AudioEngine/AudioRenderClock.swift \
  Sources/SrtFlow/AudioEngine/PlaybackAudioSource.swift \
  Sources/SrtFlow/AudioEngine/AudioEngineIdlePolicy.swift \
  Sources/SrtFlow/AudioEngine/AudioEngineIdleKeeper.swift \
  Sources/SrtFlow/AppUserPresence.swift \
  Sources/SrtFlow/AudioEngine/AudioStemRender.swift \
  Sources/SrtFlow/AudioEngine/MixFrameGrid.swift \
  Sources/SrtFlow/AudioEngine/MixBandMeter.swift \
  Sources/SrtFlow/AudioEngine/MixBusMeter.swift \
  Sources/SrtFlow/AudioEngine/MixMeasurement.swift \
  Sources/SrtFlow/AIListenMixPlan.swift \
  Sources/SrtFlow/AIListenMixReport.swift \
  Sources/SrtFlow/AIListenVoicePlan.swift \
  Sources/SrtFlow/AIListenVoiceMeasure.swift \
  Sources/SrtFlow/AIListenVoiceReport.swift \
  Sources/SrtFlow/Listening/VoiceClarity.swift \
  Sources/SrtFlow/Listening/VoiceLines.swift \
  Sources/SrtFlow/Listening/MaskerAttribution.swift \
  Sources/SrtFlow/Listening/ESTOI.swift \
  Sources/SrtFlow/Listening/ESTOIAnalysis.swift \
  Sources/SrtFlow/Listening/ListeningDFT.swift \
  Sources/SrtFlow/Listening/ListeningMath.swift \
  Sources/SrtFlow/Listening/ListeningResample.swift \
  Sources/SrtFlow/AIAudioLevels.swift \
  Sources/SrtFlow/AIListenSampleFrames.swift \
  Sources/SrtFlow/ExportAudioReport.swift \
  Sources/SrtFlow/AIToolIO.swift \
  Sources/SrtFlow/AIShortIDs.swift \
  Sources/SrtFlow/VideoEditWaveformData.swift \
  Sources/SrtFlow/VideoEditWaveformPower.swift \
  Sources/SrtFlow/MediaReadAudit.swift \
  checks/MixLayers/main.swift \
  checks/MixLayers/Signals.swift \
  checks/MixLayers/Oracle.swift \
  checks/MixLayers/Parity.swift \
  checks/MixLayers/Plan.swift \
  checks/MixLayers/Voice.swift \
  checks/MixLayers/VoiceHints.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
