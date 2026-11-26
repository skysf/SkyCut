#!/bin/bash
# 真走生产的 DMG 组装 / 挂载路径，不编 App、不签名、不要图形会话 / Finder 自动化。
# 不带参数：CI 用小型夹具生成 DMG；带路径：验收 build-app 打出来的完整安装包。
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/test-app-cleanup.sh
if [ "$#" -gt 1 ]; then
    echo "用法：scripts/check-dmg.sh [SkyCut-version-arm64.dmg]" >&2
    exit 2
fi
WORK="$(mktemp -d)"
MOUNT="${WORK}/mount"
FIXTURE_APP="${WORK}/fixture/SkyCut.app"
MOUNTED=0
cleanup() {
    remove_test_app "${FIXTURE_APP}"
    if [ "${MOUNTED}" -eq 1 ]; then
        unregister_test_app "${MOUNT}/SkyCut.app"
        hdiutil detach "${MOUNT}" >/dev/null
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT
test_app_exit_signals
mkdir -p "${MOUNT}"
if [ "$#" -eq 0 ]; then
    mkdir -p "${FIXTURE_APP}/Contents"
    echo 'DMG packaging fixture' > "${FIXTURE_APP}/Contents/fixture"
    DMG="${WORK}/fixture.dmg"
    /bin/bash scripts/build-dmg.sh "${FIXTURE_APP}" "${DMG}"
    # Without a whole icon source the builder stops instead of drawing another icon (make-icon.swift's fallback, or
    # a cut-off PNG's black rows): a copy of it with everything else in place, given no source, a file that isn't an
    # image, then the real source cut to half its own size (a fixed length would copy a small icon whole).
    STRAY="${WORK}/no-icon-source"
    mkdir -p "${STRAY}/scripts/dmg" "${STRAY}/packaging/dmg"
    cp scripts/build-dmg.sh scripts/make-icon.swift "${STRAY}/scripts/"
    cp scripts/dmg/make-background.swift "${STRAY}/scripts/dmg/"
    cp packaging/dmg/DS_Store "${STRAY}/packaging/dmg/"
    for source in missing unreadable cut-off; do
        case "${source}" in
            unreadable) echo 'version https://git-lfs.github.com/spec/v1' > "${STRAY}/packaging/icon-source-1024.png" ;;
            cut-off)
                SIZE="$(wc -c < packaging/icon-source-1024.png)"
                head -c "$((SIZE / 2))" packaging/icon-source-1024.png > "${STRAY}/packaging/icon-source-1024.png"
                ;;
        esac
        if /bin/bash "${STRAY}/scripts/build-dmg.sh" "${FIXTURE_APP}" "${WORK}/stray.dmg" 2>"${WORK}/stray.log"; then
            echo "✗ build-dmg.sh built a DMG with a ${source} icon source" >&2
            exit 1
        fi
        if ! grep -q 'icon-source-1024.png is missing, unreadable or cut off' "${WORK}/stray.log"; then
            cat "${WORK}/stray.log" >&2
            echo "✗ build-dmg.sh failed without naming the ${source} icon source" >&2
            exit 1
        fi
    done
    echo '✓ A missing, unreadable or cut-off icon source stops the DMG builder'
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
