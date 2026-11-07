#!/usr/bin/env bash
# 公开制作计划的真实模型自检：存盘/图与 CAS/审查失效/声音/原生帧证据/目录换 Key 并发。
# 不启动 App、不解码媒体、不碰网络或钥匙串；URLSession 全部注入本地协议。
# MainActor 工具/权限/撤销/生命周期由完整 App 编译和独立后台 MCP 冒烟验收。
# 不使用 TimelineState/Snapshot 替身。源清单由 checks/check-script-source-lists.sh 守着。
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowMCPKit 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "${OUT_DIR}"' EXIT

echo "==> 编译公开制作状态自检（真实模型）"
xcrun swiftc \
  -target "${TRIPLE}" \
  -wmo \
  -I "${BUILD_DIR}/Modules" \
  -o "${OUT_DIR}/productioncheck" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/EditLane.swift \
  Sources/SrtFlow/VideoEditCanvasRatio.swift \
  Sources/SrtFlow/StillAlphaNaming.swift \
  Sources/SrtFlow/VideoEditTrackSlot.swift \
  Sources/SrtFlow/VideoEditExportSelection.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditShapeAnimation.swift \
  Sources/SrtFlow/VideoEditShapeOutline.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditFilterLUT.swift \
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
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditKeyframeEasing.swift \
  Sources/SrtFlow/VideoEditKeyframeSlices.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditMarkerTargets.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/TimelineClipSplit.swift \
  Sources/SrtFlow/VideoEditClipUpscale.swift \
  Sources/SrtFlow/VideoEditClipUpscaleRecord.swift \
  Sources/SrtFlow/VideoEditMediaReferences.swift \
  Sources/SrtFlow/FreezeSliver.swift \
  Sources/SrtFlow/VideoEditTimelineRowSelection.swift \
  Sources/SrtFlow/VideoEditClipVisibility.swift \
  Sources/SrtFlow/VideoEditTransitionHandles.swift \
  Sources/SrtFlow/VideoEditTimelineLinkage.swift \
  Sources/SrtFlow/VideoEditTimelineCaptionSource.swift \
  Sources/SrtFlow/VideoEditTimelineCueFollow.swift \
  Sources/SrtFlow/VideoEditTimelineLinkageLanding.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditTimelineRowHeights.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/VideoEditProjectFile.swift \
  Sources/SrtFlow/VideoEditMediaBookmarkCache.swift \
  Sources/SrtFlow/AudioLibraryCache.swift \
  Sources/SrtFlow/AudioLibraryManifest.swift \
  Sources/SrtFlow/SoundEffects/SoundEffectClipGain.swift \
  Sources/SrtFlow/VideoEditSelection.swift \
  Sources/SrtFlow/SubtitleGen/SubtitleAudibleClips.swift \
  Sources/SrtFlow/SubtitleGen/AudioWindowReader.swift \
  Sources/SrtFlow/SubtitleGen/TranscriptSidecarStore.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/StillImageClipFactory.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/AppTheme.swift \
  Sources/SrtFlow/AppThemePalette.swift \
  Sources/SrtFlow/AppThemeAppearance.swift \
  Sources/SrtFlow/AIToolIO.swift \
  Sources/SrtFlow/AIShortIDs.swift \
  Sources/SrtFlow/KeychainSecret.swift \
  Sources/SrtFlow/NativeSourceFrameSampler.swift \
  Sources/SrtFlow/SourceFrameEvidence.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioKey.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJobAccess.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioMachine.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioMe.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJob.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacter.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterAssets.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterAPI.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioFilm.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioFilmReader.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioFilmInputs.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioOfficialQuote.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioBilling.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJobFailure.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioModels.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioApproval.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioPublicRenderValidation.swift \
  Sources/SrtFlow/CloudMedia/CloudTransfer.swift \
  Sources/SrtFlow/TimelineRenderSize.swift \
  Sources/SrtFlow/VideoEditAudioMeter.swift \
  Sources/SrtFlow/VideoEditSoundSceneDSP.swift \
  Sources/SrtFlow/VideoEditSoundSceneRecipe.swift \
  Sources/SrtFlow/AudioEngine/AudioEngineConfig.swift \
  Sources/SrtFlow/AudioEngine/AudioGainTable.swift \
  Sources/SrtFlow/AudioEngine/MeterSlot.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionSamples.swift \
  Sources/SrtFlow/FilmProduction/SourceFrameReader.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionGraph.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionRecords.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionJSON.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionReader.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionReviewReader.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionReadiness.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionSnapshot.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionAnchorReader.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionReferences.swift \
  Sources/SrtFlow/FilmProduction/AIFilmProductionSummary.swift \
  checks/FilmProduction/Harness.swift \
  checks/FilmProduction/ProductionRecordChecks.swift \
  checks/FilmProduction/ProductionReaderChecks.swift \
  checks/FilmProduction/ProductionSnapshotChecks.swift \
  checks/FilmProduction/ProductionGeometryChecks.swift \
  checks/FilmProduction/ProductionTransitionSnapshotChecks.swift \
  checks/FilmProduction/ProductionCanvasChecks.swift \
  checks/FilmProduction/ProductionSamplingChecks.swift \
  checks/FilmProduction/ProductionReferenceChecks.swift \
  checks/FilmProduction/SourceFrameChecks.swift \
  checks/FilmProduction/SourceFrameReaderChecks.swift \
  checks/FilmProduction/AnchorReaderChecks.swift \
  checks/FilmProduction/PersistenceChecks.swift \
  checks/FilmProduction/CatalogCacheStub.swift \
  checks/FilmProduction/CatalogCacheChecks.swift \
  checks/FilmProduction/main.swift \
  "${BUILD_DIR}"/SrtFlowCore.build/*.o \
  "${BUILD_DIR}"/SrtFlowMCPKit.build/*.o

echo "==> 运行公开制作状态自检"
"${OUT_DIR}/productioncheck"
