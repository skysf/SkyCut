#!/usr/bin/env bash
# SkyCut 打包脚本（仅依赖 Command Line Tools，无需完整 Xcode）
#
# 用法：
#   VERSION=1.0.0 scripts/build-app.sh   # 正式发版：显式指定版本号
#   scripts/build-app.sh                 # 开发版：版本号取最近的 git tag
#
# 产物：
#   dist/SkyCut.app
#   dist/SkyCut-<VERSION>-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

# 产品名 SkyCut（.app、可执行文件、DMG 都叫它）；SwiftPM 的产品和资源包沿用代码名 SrtFlow
# （docs/architecture/product-name.md）。
APP_NAME=SkyCut
PRODUCT=SrtFlow
DIST=dist

# 版本号不写死默认值：以前是 VERSION="${VERSION:-0.3.0}"，发到 0.4.1 了那行还留在
# 0.3.0，不传 VERSION 就会打出贴着旧版本号的包（dist/ 里真出现过这种产物）。
# 改成兜底取最近的 tag —— 它跟着发布自动走，不会腐烂；HEAD 领先 tag 时明确警告。
#
# 注意下面凡是紧跟中文的变量都写成 ${VAR} 而不是裸 $VAR：bash 展开裸变量名时会把
# 多字节字符的首字节也算进名字里（"v$VERSION，" 去找的是 VERSION\xef），配上
# set -u 就是 unbound variable 当场挂掉。与 bash 版本、locale 都无关，5.3 照样中。
# 本仓库的 .sh 全是中文提示，加变量时先想一下这条。详见
# docs/bugfixes/2026-08-06-build-version-and-shell-traps.md
if [ -z "${VERSION:-}" ]; then
  # pipefail 下 git 失败会让整条赋值以 128 退出、走不到下面的报错，所以兜 || true
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  if [ -z "${VERSION}" ]; then
    echo "✗ 未传 VERSION，也取不到 git tag（不在 git 仓库？）。" >&2
    echo "  请显式指定：VERSION=x.y.z $0" >&2
    exit 1
  fi
  AHEAD="$(git rev-list --count "v${VERSION}..HEAD" 2>/dev/null || echo 0)"
  if [ "${AHEAD}" -gt 0 ]; then
    echo "⚠️  未传 VERSION，回退到最近的 tag v${VERSION}，但 HEAD 已领先 ${AHEAD} 个提交。"
    echo "    这是开发版产物；正式发版请显式指定：VERSION=x.y.z $0"
  fi
fi

echo "==> swift build -c release (arm64, -O)"
swift build -c release --arch arm64
BUILD_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="$DIST/$APP_NAME.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 二进制：strip 掉符号，保持体积最小
cp "$BUILD_DIR/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"
strip -xS "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# SwiftPM 资源包（en / zh-Hans 本地化）
RES_BUNDLE="$BUILD_DIR/SrtFlow_SrtFlow.bundle"
if [ -d "$RES_BUNDLE/Contents/Resources" ]; then
    ditto "$RES_BUNDLE/Contents/Resources" "$APP/Contents/Resources"
elif [ -d "$RES_BUNDLE" ]; then
    ditto "$RES_BUNDLE" "$APP/Contents/Resources"
fi
# 资源包里可能带一个它自己的 Info.plist，避免与 App 的冲突
rm -f "$APP/Contents/Resources/Info.plist"

cp packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# 随包的 ffmpeg：视频压缩与烧制字幕都靠它。放 Contents/Helpers（Apple 约定的
# 附属可执行文件位置），App 以独立进程调用。
echo "==> 内置 ffmpeg"
if [ ! -x vendor/ffmpeg ]; then
    echo "   vendor/ffmpeg 不存在，先获取"
    scripts/vendor-ffmpeg.sh
fi
mkdir -p "$APP/Contents/Helpers"
cp vendor/ffmpeg "$APP/Contents/Helpers/ffmpeg"
chmod +x "$APP/Contents/Helpers/ffmpeg"
# GPL 合规：许可说明随包，方便使用者查到 ffmpeg 的授权与源码途径。
# 每次打包都重新生成再拷：vendor/ 不入库，这份文案原本只在重新获取 ffmpeg 时
# 写一次，仓库换了授权它不会跟着变 —— 0.5.0 打包实测撞过（LICENSE 已经是
# AGPL-3.0，包里这份仍写着 MIT）。这是给用户看的授权声明，不能拷陈的。
scripts/vendor-ffmpeg.sh --readme-only
cp vendor/README.md "$APP/Contents/Resources/ffmpeg-LICENSE.md"

# AI 客户端（Claude、Codex……）启动的 MCP 小程序，和 ffmpeg 一样放 Helpers。
# 客户端配置里写的就是这个路径；它从自己的位置往上找到所在的 App
# （docs/architecture/ai-control-mcp.md）。上面那条 swift build 已经把它一起编了。
echo "==> 内置 skycut-mcp"
cp "$BUILD_DIR/skycut-mcp" "$APP/Contents/Helpers/skycut-mcp"
strip -xS "$APP/Contents/Helpers/skycut-mcp" 2>/dev/null || true
chmod +x "$APP/Contents/Helpers/skycut-mcp"

# 图标：脚本生成 iconset → iconutil 合成 icns（仓库中不放二进制图标文件）
echo "==> 生成图标"
ICONSET="$(mktemp -d)/SkyCut.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/SkyCut.icns"
rm -rf "$(dirname "$ICONSET")"

# 签名只经 sign-app.sh 一处（嵌套的先签、外层最后签）：有发布用的签名身份就用它，系统里给过的录屏、麦克风、
# 下载文件夹、钥匙串权限跨版本有效；没有就退回 ad-hoc 并警告（docs/architecture/code-signing-and-permissions.md）。
echo "==> codesign"
scripts/signing/sign-app.sh "$APP"

# DMG：真实 App / Applications 图标 + 双语引导背景 + 固定 Finder 布局（不控制 Finder）。
echo "==> 生成 DMG"
DMG="$DIST/$APP_NAME-$VERSION-arm64.dmg"
/bin/bash scripts/build-dmg.sh "$APP" "$DMG"

echo
echo "完成："
du -sh "$APP" "$DMG"
