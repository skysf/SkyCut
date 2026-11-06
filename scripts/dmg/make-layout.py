#!/usr/bin/env python3
"""只在主动改布局时重建模板，不被打包或 CI 调用，不控制 Finder。

一次性工具：python3 -m pip install --target /private/tmp/skycut-dmg-template-tools
    ds-store==1.3.3 mac-alias==2.2.3
PYTHONPATH=/private/tmp/skycut-dmg-template-tools python3 scripts/dmg/make-layout.py
正式打包只复制输出的 DS_Store；图稿另由 make-background.swift 生成。
"""
from datetime import datetime, timezone
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias, TargetInfo, VolumeInfo

# 人工构造卷内相对路径，不携带开发机路径、卷 UUID / 文件 inode。
# 每次打包都会重新创建卷；Finder 按 SkyCut 卷上的相对路径找到背景。
stamp = datetime(2000, 1, 1, tzinfo=timezone.utc)
background = Alias(
    volume=VolumeInfo("SkyCut", stamp, b"H+", 5, 0, b"\0\0"),
    target=TargetInfo(0, "background.tiff", 0, 0, stamp, b"\0" * 4, b"\0" * 4,
                      folder_name=".background", carbon_path="SkyCut:.background:background.tiff",
                      posix_path=".background/background.tiff"),
)
path = Path(__file__).resolve().parents[2] / "packaging/dmg/DS_Store"
with DSStore.open(str(path), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "ShowSidebar": False, "ContainerShowSidebar": False, "ShowToolbar": False,
        "ShowStatusBar": False, "ShowPathbar": False, "ShowTabView": False,
        "WindowBounds": "{{120, 120}, {760, 648}}", "PreviewPaneVisibility": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundImageAlias": background.to_bytes(),
        "backgroundColorRed": 0.953, "backgroundColorGreen": 0.941,
        "backgroundColorBlue": 0.910, "iconSize": 128.0, "textSize": 14.0,
        "gridSpacing": 100.0, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "arrangeBy": "none", "labelOnBottom": True, "showIconPreview": True,
        "showItemInfo": False, "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    store["SkyCut.app"]["Iloc"] = (200, 164)
    store["Applications"]["Iloc"] = (560, 164)
print(f"wrote {path}")
