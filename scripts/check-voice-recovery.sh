#!/usr/bin/env bash
# 真实 App 对象的旁白失败恢复回归；假 HTTP / 转写，不访问生产 Key，不生成付费媒体，不启动用户 App。
# 复用完整 App 的目标文件，避免另编一份业务流程；独立 bundle 隔离设置和积分账。
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
# 每次运行一个自己的 bundle id，也就各用一份 UserDefaults：本机几个会话同时跑这一项时，别人开头 / 结尾那一下
# removePersistentDomain 不会抹掉这边还在读的账和记录（2026-11-11 撞上过：重启那一组要从盘上读回来）。
# 检查结尾清空了自己那一份，系统还会在进程退出后十秒左右写下一个空 plist（这时脚本早结束了）：每次开头清掉
# 五分钟以前留下的（正在跑的那一份一直在被写，碰不到）。
BUNDLE_ID="com.srtflow.SrtFlow.voicerecoverycheck.run$$"
find "${HOME}/Library/Preferences" -maxdepth 1 -name 'com.srtflow.SrtFlow.voicerecoverycheck.run*.plist' -mmin +5 -delete 2>/dev/null || true
APP="${ROOT}/VoiceRecoveryCheck.app"
# The run's own Application Support folder (the official recovery's receipt, the provider marker the paid tool checks write when they
# mark a key on the account) goes with the bundle, also when a check fails.
SUPPORT="${HOME}/Library/Application Support/${BUNDLE_ID}"
cleanup() {
  remove_test_app "${APP}"
  rm -rf -- "${ROOT}" "${SUPPORT}"
}
trap cleanup EXIT
test_app_exit_signals
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleExecutable</key><string>VoiceRecoveryCheck</string>
<key>CFBundleName</key><string>VoiceRecoveryCheck</string>
</dict></plist>
PLIST
# Bundle.module 的两条相对定位都能命中，纯对象测试不运行 SrtFlowApp.main。
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  -I "${BUILD_DIR}/Modules" \
  checks/Shared/ScratchDefaults.swift \
  checks/VoiceRecovery/Fixture.swift checks/VoiceRecovery/StartChecks.swift checks/VoiceRecovery/TimingChecks.swift \
  checks/VoiceRecovery/ConcurrencyChecks.swift \
  checks/VoiceRecovery/Main.swift checks/VoiceRecovery/LibraryFixture.swift checks/VoiceRecovery/LibraryChecks.swift \
  checks/VoiceRecovery/LibraryLanguageChecks.swift \
  checks/VoiceRecovery/FallbackFeeChecks.swift checks/VoiceRecovery/PaidAudioChecks.swift \
  checks/VoiceRecovery/StopChecks.swift checks/VoiceRecovery/KeepAwakeChecks.swift \
  checks/VoiceRecovery/StandingChecks.swift \
  checks/VoiceRecovery/LibraryUIChecks.swift checks/VoiceRecovery/LibraryOrderChecks.swift \
  checks/VoiceRecovery/LibraryRestartChecks.swift \
  checks/VoiceRecovery/VoiceChangeFixture.swift checks/VoiceRecovery/VoiceChangeChecks.swift \
  checks/VoiceRecovery/VoiceChangeDirectChecks.swift checks/VoiceRecovery/VoiceChangeDownloadChecks.swift \
  checks/VoiceRecovery/VoiceChangeOwnFilesChecks.swift \
  checks/VoiceRecovery/GenerationDownloadChecks.swift checks/VoiceRecovery/VoiceoverDownloadChecks.swift \
  checks/VoiceRecovery/UpscaleJobDownloadChecks.swift checks/VoiceRecovery/OfficialRecoveryDownloadChecks.swift \
  checks/VoiceRecovery/OfficialFilmRunChecks.swift \
  checks/VoiceRecovery/PaidToolEntryChecks.swift \
  checks/VoiceRecovery/RepeatRequestChecks.swift checks/VoiceRecovery/RepeatPanelChecks.swift \
  checks/VoiceRecovery/VoiceChangeBalanceChecks.swift checks/VoiceRecovery/VoiceChangeSettleChecks.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" \
  -o "${APP}/Contents/MacOS/VoiceRecoveryCheck"
# 外层看门狗不能放在 Swift 协作线程池里；脚本超时明确红。480 s (2026-11-26; was 300, before that 180): PR #554's paid-download checks
# and PR #557's identical-request checks took the CI step from 213 to 240 s, the binary itself about 163 s on a local M1, and CI
# runners differ by 34 s or more. The wrapper prints the binary's own seconds (also when it fails or times out), so each log shows
# the margin; a hang still ends red, three minutes later. When it grows again, split the binary's run in two (FBR1 on PR #557).
SRTFLOW_VOICE_RECOVERY_CHECK_DIR="${ROOT}/work" \
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/VoiceRecoveryCheck" <<'PYTHON'
import subprocess
import sys
import time
WATCHDOG = 480
start = time.monotonic()
try:
    subprocess.run([sys.argv[1]], timeout=WATCHDOG, check=True)
finally:
    print(f"voice-recovery binary: {time.monotonic() - start:.0f} s of the {WATCHDOG} s watchdog", flush=True)
PYTHON
