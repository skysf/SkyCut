#!/usr/bin/env bash
# 云端媒体仍在共用的每日账、额度判断与阶段 / 字节进度自检；HTTP 由 check-sky-studio 验证。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowMCPKit"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowMCPKit 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/cloudmediacheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# 清单是手抄的（scripts/check-project-file.sh 开头讲了为什么），由 checks/check-script-source-lists.sh 守着。
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/CloudMedia/DailySpend.swift \
  Sources/SrtFlow/USDollarText.swift \
  Sources/SrtFlow/CloudMedia/CloudJobPhase.swift \
  Sources/SrtFlow/CloudMedia/CloudTaskSummary.swift \
  checks/CloudMedia/main.swift \
  checks/CloudMedia/Harness.swift \
  checks/CloudMedia/SpendChecks.swift \
  checks/CloudMedia/PhaseChecks.swift \
  checks/CloudMedia/TaskSummaryChecks.swift \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o

echo "==> 跑自检"
"$OUT"
