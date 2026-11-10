#!/usr/bin/env bash
# Sky Studio 账号与照授权拦（收费方案第 5 刀）的自检：
#   1. 粘进来的 Key 怎么整理（`sk-` 开头、URL 安全的字符；去掉 Bearer、引号、首尾空白），钥匙串那一条叫什么；
#   2. 发给 Sky Studio 的机器号：SHA-256(硬件 UUID + 盐) 钉死一组值（盐改了就红），这台 Mac 读得到、发出去的不是原样的 UUID；
#   3. /me 的回答：合同里的样例逐字段读、日期带毫秒也认、认不出的字段不管、少了必须的就不算回答、网址只认 https（和本机）、存下来读回来一样；
#   4. SkyStudioAPI：假 URLSession 协议上看发出去的地址 / 方法 / 四个头，401 / 426 / 429 原样留着 code 和附加字段，
#      502 的网页 / 2xx 读不成 / 断网各是哪一种，环境变量只能把地址指到本机；
#   5. 此刻的授权（SkyCutLicense）：没有 Key / 没问到过 / 过了 valid_until 都按免费版，服务器的钟换成本机的，钟往回拨不作数，
#      开关只听服务器的；什么时候再问（SkyStudioRefresh）：前台非正式版 1 分钟 / 正式版 30 分钟、后台 6 小时、失败退避 5 分钟；
#      自助购买合同 v1 的可选字段（含 pro_source）/ 旧回答 / 合同 fixture / 缓存往返，购买地址进入设置、导出和 AI 共用的此刻授权；
#   6. 照授权拦（SkyCutGates，第 5 刀第二步）：2026-10-28 起默认打开、测试开关关不掉它；AI 的工具只听 mcp、get_status 和 skycut_guide 永远让；导出的水印听服务器的；
#      被挡住时回给 AI 的话（没做、为什么、请用户做什么）、get_status 里的 skycut_plan、导出带了水印时那一句；
#   7. 第 6 刀的任务（生成、upscale、克隆走 Sky Studio）：/models 怎么读、/quote 和 /jobs 发什么、状态和成品怎么读、取消的两种结果、
#      /uploads 之后 PUT（只带服务器给的头、不带 Key）、下载成品；SkyStudioJobRun 满了等着再交（同一个 idempotency_key）、照 poll_after_seconds
#      问、断网几次不算失败、停的时候排着队的退钱 / 开始了的取消不了、没做成 / 回的不像话 / 等太久各是哪一种；
#   8. 积分的每日上限和按天的账（SkyStudioSpendStore）：默认 1,000、额度内不问 / 超了问、记账退回按那一天、上限夹住取整、存下来读回来一样。
#   9. generate_media 送 Sky Studio 的那一份（SkyStudioGeneration，第 6 刀 6b）：词表和类型对账、每种的默认值（画幅跟画布 / 首帧、视频 5 秒 768p、
#      音效 5 秒 wav、音乐纯音乐不给时长）、用不上的参数说一句不送、请求体、确认码的记号、离谁最近的画幅、成品的扩展名；
#      图生视频的首帧（真写几张图：宽高比、EXIF 转了 90 度的对调、PNG 原样传、TIFF 转成 JPEG 传完删掉、不是图的说清楚）。
#  10. 声音的接口合同（SkyCut 声音方案第十节 PR 1，还没接任何入口）：/models 的预设声音 / 角色 / 授权文案对着目录快照
#      （checks/SkyStudio/Fixtures/models-voice-*.json）读；/voices 和长期授权的请求；读稿整段报价（params.batches）读回 voice_plan /
#      每批的价 / 一次性费用、每批 /jobs 带同一个 params.plan、拉丁字母的非英文稿才带 params.language；建 MiniMax 版 / 设计 / 变声的
#      请求和结果；429 的 pool、/me 的 max_running_audio_jobs、两个新上传用途。
#      声音 PR 3：add_voiceover 的 voice 在 Sky Studio 上是谁（SkyStudioVoicePick：认声音的顺序、默认 gemini:Charon、角色只认 voice_roles、
#      英式男声读非英文、本机退档按性别）；报价之前怎么分批、报价之后每批照报价交（SkyStudioVoicePlan）；恢复记录 version 2。
#      声音 PR 5：报价之前怎么读（SkyStudioVoiceReading：合不合批、整段换 eleven-v4、按字数估）、一句超长先在句末分、
#      原文切成词 / 对到原文上 / 按字数估（SpeechWordTokens / SpeechWordAlignment / SpeechWordEstimate）、Eleven 的字符时间切句。
#
# 不碰真的网络、不碰真的钥匙串（钥匙串的读写和 fal 共用 KeychainSecret，真钥匙串在 scripts/check-fal-keychain.sh，本机手动）。
# 合同在 Sky Studio 仓库的 docs/agents/skycut-api.md；规矩见 docs/architecture/sky-studio-account.md。
#
# 用法：
#   scripts/check-sky-studio.sh
#
# 编法同 check-fal.sh：被测代码在 SrtFlow app target 里，SwiftPM 不允许两个 target 共用源文件，所以挑纯值文件单独编成自检二进制。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowMCPKit"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowMCPKit 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/skystudiocheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# 清单是手抄的（scripts/check-project-file.sh 开头讲了为什么），由 checks/check-script-source-lists.sh 守着。
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/KeychainSecretExecutor.swift \
  Sources/SrtFlow/KeychainSecret.swift \
  Sources/SrtFlow/KeychainSecretCache.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioKey.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioKeychainNoticePolicy.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJobAccess.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioMachine.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioMe.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift \
  Sources/SrtFlow/SkyStudio/SkyCutLicense.swift \
  Sources/SrtFlow/SkyStudio/SkyCutProNotice.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioProblem.swift \
  Sources/SrtFlow/SkyStudio/SkyCutGates.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJob.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacter.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterSummary.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterCapabilities.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterNativeRequest.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioReceiptFile.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterPlan.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterWorkflow.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterReceipt.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterJobReport.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioReferenceImage.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterAssets.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterAccess.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterGeneration.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioCharacterAPI.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioFilm.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioFilmReader.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioFilmInputs.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioOfficialQuote.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioOfficialPrepared.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioOfficialReceipt.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioOfficialReceiptStore.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioBilling.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJobFailure.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioModels.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioModelPolicy.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioReferencePolicy.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJobRun.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioGeneration.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioGenerationName.swift \
  Sources/SrtFlow/AIVoiceoverPlacement.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioGenerationControls.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioImageOperation.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioImageResult.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioGenerationRequests.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioGenerationFrame.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioSpend.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioApproval.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioJobGate.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioHeldCredits.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceBatch.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoicePlan.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceReading.swift \
  Sources/SrtFlow/AIVoiceoverTiming.swift \
  Sources/SrtFlow/SpeechWordTokens.swift \
  Sources/SrtFlow/SpeechWordAlignment.swift \
  Sources/SrtFlow/SpeechWordEstimate.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceBudget.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceSplit.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceCheckpoint.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceCatalog.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceLibrary.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceQuote.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceResults.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceRequests.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoiceAPI.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioVoicePick.swift \
  Sources/SrtFlow/AIVoiceRole.swift \
  Sources/SrtFlow/AIVoiceChoice.swift \
  Sources/SrtFlow/AITextLanguage.swift \
  Sources/SrtFlow/SpeechWordTimes.swift \
  Sources/SrtFlow/AIVoiceWords.swift \
  Sources/SrtFlow/AIToolIO.swift \
  Sources/SrtFlow/AIConfirmations.swift \
  Sources/SrtFlow/AIAccessPolicy.swift \
  Sources/SrtFlow/AIDraftPolicy.swift \
  Sources/SrtFlow/AISettingsApproval.swift \
  Sources/SrtFlow/AIAccessStore.swift \
  Sources/SrtFlow/CloudMedia/DailySpend.swift \
  Sources/SrtFlow/CloudMedia/CloudTransfer.swift \
  checks/SkyStudio/main.swift \
  checks/SkyStudio/Harness.swift \
  checks/SkyStudio/Stub.swift \
  checks/SkyStudio/KeyChecks.swift \
  checks/SkyStudio/KeychainCacheChecks.swift \
  checks/SkyStudio/MeChecks.swift \
  checks/SkyStudio/APIChecks.swift \
  checks/SkyStudio/LicenseChecks.swift \
  checks/SkyStudio/RefreshChecks.swift \
  checks/SkyStudio/ProPurchaseChecks.swift \
  checks/SkyStudio/ProNoticeChecks.swift \
  checks/SkyStudio/GateChecks.swift \
  checks/SkyStudio/JobChecks.swift \
  checks/SkyStudio/FilmChecks.swift \
  checks/SkyStudio/OfficialQuoteChecks.swift \
  checks/SkyStudio/OfficialReceiptChecks.swift \
  checks/SkyStudio/OfficialPreparedChecks.swift \
  checks/SkyStudio/OfficialApprovalChecks.swift \
  checks/SkyStudio/AdmissionChecks.swift \
  checks/SkyStudio/JobRunChecks.swift \
  checks/SkyStudio/SpendChecks.swift \
  checks/SkyStudio/ApprovalChecks.swift \
  checks/SkyStudio/AccessChecks.swift \
  checks/SkyStudio/VoiceChecks.swift \
  checks/SkyStudio/VoiceTimingChecks.swift \
  checks/SkyStudio/VoiceRecoveryChecks.swift \
  checks/SkyStudio/VoiceCatalogChecks.swift \
  checks/SkyStudio/VoiceLibraryChecks.swift \
  checks/SkyStudio/VoicePlanChecks.swift \
  checks/SkyStudio/VoiceJobChecks.swift \
  checks/SkyStudio/VoicePickChecks.swift \
  checks/SkyStudio/GenerationChecks.swift \
  checks/SkyStudio/ModelPolicyChecks.swift \
  checks/SkyStudio/ModelExpansionChecks.swift \
  checks/SkyStudio/ImageOperationChecks.swift \
  checks/SkyStudio/ImageApprovalChecks.swift \
  checks/SkyStudio/ImageResultChecks.swift \
  checks/SkyStudio/ToolResultChecks.swift \
  checks/SkyStudio/CharacterChecks.swift \
  checks/SkyStudio/CharacterApprovalChecks.swift \
  checks/SkyStudio/CharacterFixtures.swift \
  checks/SkyStudio/CharacterNativeChecks.swift \
  checks/SkyStudio/CharacterRecoveryChecks.swift \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 跑自检"
"$OUT"
