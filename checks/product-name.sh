#!/usr/bin/env bash
# 产品名与代码名（docs/architecture/product-name.md）：给用户和 AI 看的名字是 SkyCut，身份类的名字沿用 SrtFlow。
#
# 为什么：2026-10-18 改名 SkyCut 时定的。身份类的名字一改，macOS 就当成另一个 App —— 录屏、麦克风、下载文件夹、
# 钥匙串的授权全部重给，UserDefaults 换了域、记住的设置清零；数据文件夹换名等于把用户存的剪辑风格、下载的配音模型、
# 录屏的恢复账本丢在旧文件夹里；小程序和 App 之间的内部名字一改，老会话里的小程序就连不上新 App。
# 这些名字用户看不见，「顺手把改名做彻底」正是最容易犯的错，所以钉住。
#
# 钉着：
#   1. 身份：bundle id、测试版的 bundle id、UTType 标识、钥匙串 service、签名证书和它的目录；
#   2. 数据：Application Support / Caches / Logs 下的 SrtFlow 文件夹、fal 的两个 UserDefaults 键；
#   3. 通道：小程序 ↔ App 的内部工具名和 /tmp 兜底的 socket 前缀；
#   4. 看得见的：App 名、可执行文件、打包脚本的 APP_NAME、小程序的产品名、两处 MCP 服务器名都是 SkyCut / skycut。
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}
# 文件里有没有这一段字面量（-F：不当正则）。
has() { [ "$({ grep -cF -- "$2" "$1" || true; })" -gt 0 ]; }
require() {
  local file="$1" text="$2" why="$3"
  if ! has "${file}" "${text}"; then
    fail "${file} 里找不到 ${text}：${why}"
  fi
}
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

PLIST="packaging/Info.plist"
KEEP="身份类的名字沿用 SrtFlow，改了用户的授权、设置或数据就丢了"

echo "==> 1. 身份"
if [ "$(plist_value "${PLIST}" CFBundleIdentifier)" != "com.srtflow.SrtFlow" ]; then
  fail "${PLIST} 的 CFBundleIdentifier 不是 com.srtflow.SrtFlow：${KEEP}"
fi
require scripts/build-beta-app.sh 'Set :CFBundleIdentifier com.srtflow.SrtFlow.beta' "测试版的 bundle id，${KEEP}"
for type in project srt ass ssa transition filter timeline-items audio-library-item; do
  require "${PLIST}" "<string>com.srtflow.${type}</string>" "老工程、老字幕、拖放载荷都按这个标识认"
done
require Sources/SrtFlow/Fal/FalKeyStore.swift '(Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow") + ".fal"' "钥匙串里 fal Key 的 service"
require scripts/signing/common.sh 'SIGNING_IDENTITY_NAME="SrtFlow Signing"' "签名证书永不重建（AGENTS.md「打包与签名」）"
require scripts/signing/common.sh '.config/srtflow/signing' "签名身份所在的目录"

echo "==> 2. 数据文件夹与设置的键"
require Sources/SrtFlow/AIRecipeStore.swift '"SrtFlow/Recipes"' "用户存的剪辑风格"
require Sources/SrtFlow/AudioLibraryCache.swift '"SrtFlow/AudioLibrary"' "音频库缓存"
require Sources/SrtFlow/KokoroVoicePack.swift '"SrtFlow/Voices/Kokoro-82M-CoreML"' "下载的配音模型（333 MB）"
require Sources/SrtFlow/ScreenRecordingCoordinator.swift '.appendingPathComponent("SrtFlow", isDirectory: true)' "录屏的恢复账本"
require Sources/SrtFlow/OptimizedMedia/OptimizedMediaStore.swift '"SrtFlow/OptimizedMedia"' "优化媒体缓存"
require Sources/SrtFlow/SubtitleGen/TranscriptSidecarStore.swift '"SrtFlow/Transcripts"' "转写缓存"
require Sources/SrtFlow/StillImageClipFactory.swift '"SrtFlow/StillClips"' "静帧缓存"
require Sources/SrtFlow/MainThreadWatchdog.swift '"Logs/SrtFlow"' "卡顿日志的位置（docs/testing/main-thread-stalls.md）"
require Sources/SrtFlow/Fal/FalSettingsStore.swift '"SrtFlow.fal.settings.v1"' "fal 的设置"
require Sources/SrtFlow/Fal/FalSettingsStore.swift '"SrtFlow.fal.spend.v1"' "fal 按天记的账"

echo "==> 3. 小程序 ↔ App 的通道"
BRIDGE="Sources/SrtFlowMCPKit/MCPBridge.swift"
require "${BRIDGE}" '"_srtflow_probe"' "老会话里的小程序用它探 App，改了就连不上新 App"
require "${BRIDGE}" '"_srtflow_catalog"' "老会话里的小程序用它换清单"
require "${BRIDGE}" '"/tmp/srtflow-mcp-' "socket 路径太长时的兜底，两边要算出同一个"

echo "==> 4. 看得见的名字是 SkyCut"
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
  if [ "$(plist_value "${PLIST}" "${key}")" != "SkyCut" ]; then
    fail "${PLIST} 的 ${key} 不是 SkyCut"
  fi
done
require scripts/build-app.sh 'APP_NAME=SkyCut' "打包出来的 .app、可执行文件、DMG 都叫 SkyCut"
require Package.swift '.executable(name: "skycut-mcp", targets: ["SrtFlowMCP"])' "小程序叫 skycut-mcp"
require Sources/SrtFlowMCPKit/MCPServerCore.swift 'public static let serverName = "skycut"' "MCP 服务器名（工具在客户端里叫 mcp__skycut__…）"
require Sources/SrtFlow/AIClientConfigFiles.swift 'static let serverName = "skycut"' "「连接 AI」写进客户端配置的名字要和小程序报的一样"

if [ "${FAILED}" -ne 0 ]; then
  echo "规范：docs/architecture/product-name.md —— 给用户和 AI 看的写 SkyCut，身份类的名字永远不改。" >&2
  exit 1
fi
echo "✓ product-name：身份沿用 SrtFlow、看得见的是 SkyCut"
