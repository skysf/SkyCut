#!/bin/bash
# 只组装安装映像：生成 Retina 背景、复制固定 Finder 模板；不编译、不签名、不控制 Finder。
# 用法：/bin/bash scripts/build-dmg.sh <SkyCut.app> <output.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 2 ] || [ ! -d "$1" ] || [ "$(basename "$1")" != SkyCut.app ]; then
    echo "用法：scripts/build-dmg.sh <SkyCut.app> <output.dmg>" >&2
    exit 2
fi
# The drag hint shows SkyCut's icon, made from this file, so a missing, unreadable or cut-off source stops the build:
# make-icon.swift quietly draws a code-drawn fallback when NSImage can't open it, and ImageIO draws a cut-off PNG's
# missing rows black. sips reads the file through ImageIO like NSImage; a whole PNG ends with its IEND chunk.
ICON_SOURCE=packaging/icon-source-1024.png
icon_source_whole() {
    case "$(sips -g pixelWidth "${ICON_SOURCE}" 2>&1)" in *"pixelWidth: "[0-9]*) ;; *) return 1 ;; esac
    [ "$(tail -c 8 "${ICON_SOURCE}" | od -An -tx1 | tr -d ' \n')" = 49454e44ae426082 ]
}
if ! icon_source_whole; then
    echo "✗ ${ICON_SOURCE} is missing, unreadable or cut off: the install window shows SkyCut's icon made from it," \
        "and make-icon.swift would quietly draw another. Restore it: git checkout -- ${ICON_SOURCE}" >&2
    exit 1
fi
APP="$1"
DMG="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ROOT="${WORK}/root"
mkdir -p "${ROOT}/.background" "${WORK}/art"
cp -R "${APP}" "${ROOT}/SkyCut.app"
ln -s /Applications "${ROOT}/Applications"
# The art's drag hint shows SkyCut's icon: made by the app icon's own generator, from the source checked above.
swift -module-cache-path .build/dmg-module-cache scripts/make-icon.swift "${WORK}/icon.iconset" >/dev/null
swift -module-cache-path .build/dmg-module-cache scripts/dmg/make-background.swift "${WORK}/art" \
    "${WORK}/icon.iconset/icon_512x512@2x.png"
tiffutil -cathidpicheck "${WORK}/art/background.png" "${WORK}/art/background@2x.png" \
    -out "${ROOT}/.background/background.tiff"
cp packaging/dmg/DS_Store "${ROOT}/.DS_Store"
# 明确 HFS+，模板里的背景 alias 用卷内路径；创建映像不触发 Apple Events / TCC 授权。
hdiutil create -volname SkyCut -fs HFS+ -srcfolder "${ROOT}" -ov -format UDZO "${DMG}"
