#!/bin/bash
# 真走生产的 DMG 组装 / 挂载路径，不编 App、不签名、不要图形会话 / Finder 自动化。
# 不带参数：CI 用小型夹具生成 DMG；带路径：验收 build-app 打出来的完整安装包。
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ]; then
    echo "用法：scripts/check-dmg.sh [SkyCut-version-arm64.dmg]" >&2
    exit 2
fi
WORK="$(mktemp -d)"
MOUNT="${WORK}/mount"
MOUNTED=0
cleanup() {
    if [ "${MOUNTED}" -eq 1 ]; then hdiutil detach "${MOUNT}" >/dev/null; fi
    rm -rf "${WORK}"
}
trap cleanup EXIT
mkdir -p "${MOUNT}"
if [ "$#" -eq 0 ]; then
    mkdir -p "${WORK}/fixture/SkyCut.app/Contents"
    echo 'DMG packaging fixture' > "${WORK}/fixture/SkyCut.app/Contents/fixture"
    DMG="${WORK}/fixture.dmg"
    /bin/bash scripts/build-dmg.sh "${WORK}/fixture/SkyCut.app" "${DMG}"
else
    DMG="$1"
fi
hdiutil verify "${DMG}"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "${MOUNT}" "${DMG}"
MOUNTED=1
python3 - "${MOUNT}" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
assert (root / 'SkyCut.app/Contents').is_dir(), 'missing SkyCut.app'
assert (root / 'Applications').is_symlink(), 'missing Applications shortcut'
assert (root / 'Applications').readlink() == Path('/Applications'), 'wrong Applications target'
assert (root / '.background/background.tiff').is_file(), 'missing background'
assert (root / '.DS_Store').is_file(), 'missing Finder layout'
assert not list(root.glob('*.txt')), 'old text readme must not ship'
assert {p.name for p in root.iterdir() if not p.name.startswith('.')} == {'SkyCut.app', 'Applications'}, 'unexpected visible DMG content'
print('✓ Mounted DMG: App, Applications shortcut, hidden background / layout, no txt')
PY
cmp packaging/dmg/DS_Store "${MOUNT}/.DS_Store"
python3 scripts/dmg/check-layout.py "${MOUNT}/.DS_Store"
swift -module-cache-path .build/dmg-module-cache scripts/dmg/check-background.swift \
    "${MOUNT}/.background/background.tiff"
echo "✓ DMG artifact checks passed"
