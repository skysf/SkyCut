#!/usr/bin/env bash
# Sky Studio 账号（收费方案第 5 刀第一步）的自检：
#   1. 粘进来的 Key 怎么整理（`sk-` 开头、URL 安全的字符；去掉 Bearer、引号、首尾空白），钥匙串那一条叫什么；
#   2. 发给 Sky Studio 的机器号：SHA-256(硬件 UUID + 盐) 钉死一组值（盐改了就红），这台 Mac 读得到、发出去的不是原样的 UUID；
#   3. /me 的回答：合同里的样例逐字段读、日期带毫秒也认、认不出的字段不管、少了必须的就不算回答、网址只认 https（和本机）、存下来读回来一样；
#   4. SkyStudioAPI：假 URLSession 协议上看发出去的地址 / 方法 / 四个头，401 / 426 / 429 原样留着 code 和附加字段，
#      502 的网页 / 2xx 读不成 / 断网各是哪一种，环境变量只能把地址指到本机；
#   5. 此刻的授权（SkyCutLicense）：没有 Key / 没问到过 / 过了 valid_until 都按免费版，服务器的钟换成本机的，钟往回拨不作数，
#      开关只听服务器的；什么时候再问（SkyStudioRefresh）。
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
  Sources/SrtFlow/KeychainSecret.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioKey.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioMachine.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioMe.swift \
  Sources/SrtFlow/SkyStudio/SkyStudioAPI.swift \
  Sources/SrtFlow/SkyStudio/SkyCutLicense.swift \
  checks/SkyStudio/main.swift \
  checks/SkyStudio/Harness.swift \
  checks/SkyStudio/Stub.swift \
  checks/SkyStudio/KeyChecks.swift \
  checks/SkyStudio/MeChecks.swift \
  checks/SkyStudio/APIChecks.swift \
  checks/SkyStudio/LicenseChecks.swift \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o

echo "==> 跑自检"
"$OUT"
