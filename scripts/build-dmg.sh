#!/bin/bash
# 只组装安装映像：生成 Retina 背景、复制固定 Finder 模板；不编译、不签名、不控制 Finder。
# 用法：/bin/bash scripts/build-dmg.sh <SkyCut.app> <output.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 2 ] || [ ! -d "$1" ] || [ "$(basename "$1")" != SkyCut.app ]; then
    echo "用法：scripts/build-dmg.sh <SkyCut.app> <output.dmg>" >&2
    exit 2
fi
APP="$1"
DMG="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ROOT="${WORK}/root"
mkdir -p "${ROOT}/.background" "${WORK}/art"
cp -R "${APP}" "${ROOT}/SkyCut.app"
ln -s /Applications "${ROOT}/Applications"
swift -module-cache-path .build/dmg-module-cache scripts/dmg/make-background.swift "${WORK}/art"
tiffutil -cathidpicheck "${WORK}/art/background.png" "${WORK}/art/background@2x.png" \
    -out "${ROOT}/.background/background.tiff"
cp packaging/dmg/DS_Store "${ROOT}/.DS_Store"
# 明确 HFS+，模板里的背景 alias 用卷内路径；创建映像不触发 Apple Events / TCC 授权。
hdiutil create -volname SkyCut -fs HFS+ -srcfolder "${ROOT}" -ov -format UDZO "${DMG}"
