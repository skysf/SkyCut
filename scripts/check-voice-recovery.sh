#!/usr/bin/env bash
# 真实 App 对象的旁白失败恢复回归；假 HTTP / 转写，不访问生产 Key，不生成付费媒体，不启动用户 App。
# 复用完整 App 的目标文件，避免另编一份业务流程；独立 bundle 隔离设置和积分账。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/VoiceRecoveryCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.voicerecoverycheck</string>
<key>CFBundleExecutable</key><string>VoiceRecoveryCheck</string>
<key>CFBundleName</key><string>VoiceRecoveryCheck</string>
</dict></plist>
PLIST
# Bundle.module 的两条相对定位都能命中，纯对象测试不运行 SrtFlowApp.main。
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 \
  -I "${BUILD_DIR}/Modules" \
  checks/VoiceRecovery/Fixture.swift checks/VoiceRecovery/StartChecks.swift checks/VoiceRecovery/TimingChecks.swift \
  checks/VoiceRecovery/ConcurrencyChecks.swift \
  checks/VoiceRecovery/Main.swift checks/VoiceRecovery/LibraryFixture.swift checks/VoiceRecovery/LibraryChecks.swift \
  checks/VoiceRecovery/FallbackFeeChecks.swift checks/VoiceRecovery/PaidAudioChecks.swift \
  checks/VoiceRecovery/StopChecks.swift checks/VoiceRecovery/KeepAwakeChecks.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" \
  -o "${APP}/Contents/MacOS/VoiceRecoveryCheck"
# 外层看门狗不能放在 Swift 协作线程池里；脚本超时明确红。
SRTFLOW_VOICE_RECOVERY_CHECK_DIR="${ROOT}/work" \
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/VoiceRecoveryCheck" <<'PYTHON'
import subprocess
import sys
subprocess.run([sys.argv[1]], timeout=180, check=True)
PYTHON
