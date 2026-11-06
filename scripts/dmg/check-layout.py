#!/usr/bin/env python3
"""只读校验仓库的单叶 Finder 模板；只用标准库，不被正式打包调用。

解码真实的 Buddy 分配表 / DSDB 叶记录，避免只搜到残留字符串就误判布局有效。
它刻意只支持本模板的六条记录，不是通用 .DS_Store 编辑器。
"""
import plistlib
import struct
import sys
from pathlib import Path


def check(path):
    data = Path(path).read_bytes()

    def uint(offset):
        return struct.unpack_from(">I", data, offset)[0]

    assert data[:8] == b"\0\0\0\1Bud1", "invalid DS_Store header"
    assert uint(8) == uint(16), "inconsistent allocator offsets"
    root = uint(8) + 4
    count = uint(root)
    addresses = [uint(root + 8 + 4 * n) for n in range(count)]
    pos = root + 8 + 4 * ((count + 255) & ~255)
    entries = uint(pos)
    pos += 4
    toc = {}
    for _ in range(entries):
        length = data[pos]
        name = data[pos + 1:pos + 1 + length]
        pos += 1 + length
        toc[name] = uint(pos)
        pos += 4

    def block(number):
        return (addresses[number] & ~31) + 4

    superblock = block(toc[b"DSDB"])
    assert uint(superblock + 12) == 1, "template must be a single leaf"
    pos = block(uint(superblock))
    assert uint(pos) == 0, "unexpected internal node"
    records = uint(pos + 4)
    assert records == uint(superblock + 8) == 6, "expected exactly six layout records"
    pos += 8
    decoded = {}
    for _ in range(records):
        length = uint(pos)
        pos += 4
        name = data[pos:pos + length * 2].decode("utf-16be")
        pos += length * 2
        code, kind = data[pos:pos + 4], data[pos + 4:pos + 8]
        pos += 8
        if kind == b"blob":
            length = uint(pos)
            pos += 4
        else:
            assert kind in (b"long", b"type"), f"unsupported record {kind!r}"
            length = 4
        decoded[name, code] = data[pos:pos + length]
        pos += length

    window = plistlib.loads(decoded[".", b"bwsp"])
    assert window["WindowBounds"] == "{{120, 120}, {760, 648}}", "window bounds drifted"
    for key in ("ShowSidebar", "ShowToolbar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
        assert window[key] is False, f"{key} must stay hidden"
    icons = plistlib.loads(decoded[".", b"icvp"])
    assert decoded[".", b"icvl"] == b"icnv", "must open in icon view"
    assert icons["arrangeBy"] == "none" and icons["iconSize"] == 128, "icon layout drifted"
    assert icons["labelOnBottom"] is True and icons["backgroundType"] == 2
    alias = icons["backgroundImageAlias"]
    assert b".background/background.tiff" in alias, "background must use a volume-relative alias"
    assert b"/Users/" not in alias and b"/Volumes/" not in alias, "developer path leaked into alias"
    for name, point in (("SkyCut.app", (200, 164)), ("Applications", (560, 164))):
        assert struct.unpack(">II", decoded[name, b"Iloc"][:8]) == point, f"{name} moved"
    print("✓ Finder template: fixed window, icons and volume-relative background")


if __name__ == "__main__":
    try:
        check(sys.argv[1])
    except (AssertionError, IndexError, KeyError, ValueError, OSError, struct.error) as error:
        sys.exit(f"✗ DMG layout: {error}")
