#!/bin/bash
# DMG 接线守卫：正常打包只用系统绘图 / 磁盘映像工具，不自动控制 Finder、不带旧 txt。
# 真正的背景 / 布局 / 软链验收在 scripts/check-dmg.sh，模板语义用标准库解码。
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path

app = Path('scripts/build-app.sh').read_text()
build = Path('scripts/build-dmg.sh').read_text()
assert '/bin/bash scripts/build-dmg.sh "$APP" "$DMG"' in app, 'build-app must use the tested DMG builder'
assert 'APP_NAME=SkyCut' in app and '$APP_NAME-$VERSION-arm64.dmg' in app, 'product / DMG naming changed'
for source in (app, build):
    code = '\n'.join(line for line in source.splitlines() if not line.lstrip().startswith('#'))
    for forbidden in ('osascript', 'AppleScript', 'System Events', 'pip install', 'Read Me First', '首次打开必读', 'READMEEOF'):
        assert forbidden not in code, f'packaging must not use {forbidden}'
for required in (
    'scripts/dmg/make-background.swift', 'tiffutil -cathidpicheck',
    'cp packaging/dmg/DS_Store "${ROOT}/.DS_Store"',
    '"${ROOT}/.background/background.tiff"', 'ln -s /Applications',
    'hdiutil create -volname SkyCut -fs HFS+',
):
    assert required in build, f'DMG builder missing: {required}'
print('✓ DMG packaging: shared builder, Retina background, fixed template and no Finder automation / old readme')
PY
python3 scripts/dmg/check-layout.py packaging/dmg/DS_Store
